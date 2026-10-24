# Plan: more accurate direction for phones on the map

Combines the external research (`direction-research.md`) and the code-grounded plan (`direction-plan-code.md`, simulated in `direction_sim.py`). Numbers marked *sim* come from a Python simulation, not from phones. Code references are to `origin/feature/map-accuracy`; each step notes how it maps onto `main`'s positioning stack (`FusionEngine`, `PositionFilter`, `RangeSolver`, `PedestrianDeadReckoning`, `SignalMap`).

## Why direction is the weak part

UWB gives distance to ±10–30 cm, but direction only on iPhone 11–13 and only inside the antenna's field of view. Even then, a map bearing is the sum of two errors:

1. **The angle in the phone's own frame.** About 15° from UWB angle of arrival.
2. **The rotation from the phone's frame to north.** This comes from the compass, at 10–35°, and is worse indoors, near laptops and near steel.

The second term dominates. So the biggest wins come from **fixing rotation without the compass** (geometry, surveyed mounts, motion), not from better angle measurement. A phone with one ranged neighbour has no direction at all (a ring). With two, it has a mirror ambiguity.

## Phase 1: quick wins (software only, no wire change, about a week)

| # | Change | Gain | Where | Effort |
|---|---|---|---|---|
| 1 | **Stationary-aware temporal prior.** The solver assumes every phone walks at 1.4 m/s, so a bearing-placed phone falls back to a ring about 4 s after the bearing drops out. If all its UWB ranges stay within 0.3 m for 5 s, use 0.2 m/s; cap at 10 s without a fresh bearing. | *sim:* placed on 97–99.7 % of ticks instead of 68–78 % | `MeshLocator.solve` (`walkingSpeed`); on `main`, `PedestrianDeadReckoning.isWalking` for the phone itself | S |
| 2 | **Use both ends of a link plus a consistency gate.** Keep A→B and B→A (today one is discarded). If they disagree by more than 3σ, drop the worse one and flag that phone's compass as disturbed. | *sim:* median 12.1° → 9.3° | `BluetoothEstimator.input`, `LinkMeasurement.reverseBearing`, two `LayoutSolver` bearing terms | S |
| 3 | **Honest bearing errors and compass hygiene.** Raise the angle error off-axis (none beyond 75° from the back axis); divide it by the horizontal component for near-vertical rays. Detect magnetic disturbance from the field magnitude (30 s median; more than 20 % off means ≥ 45°, more than 40 % off means none). Average UWB direction samples over 1 s. Use `CLHeading.headingAccuracy`, raise the compass floor to about 20° indoors, and show iOS's calibration prompt. | Fewer gross outliers indoors; p95 roughly halved near interference (estimate) | `PeerBearing.bearing`, `OrientationSource.apply` (new `CompassHealth` in MeshCore), `UWBRanging` | S |
| 4 | **Keep both mirror solutions until evidence settles it.** For a phone ranged to exactly two placed phones, solve both reflections and accumulate the cost difference over ticks. Resolve at about 2.5σ; until then show "two spots" rather than one guess. | Stops markers flipping between ticks | `MeshLocator.solve`, `PhoneFix.alternative`, `PhoneMapView`; on `main`, `SignalMap` pinned mode | S–M |
| 5 | **Survey the heading of mounted anchors.** Sight a landmark or a second known point instead of trusting the compass. | Removes the 10–35° compass term; about 15° remains | Anchor settings UI, `AnchorGeometry` | XS |
| 6 | **Geometry before compass.** Mark a group "world-aligned" only when it has 3 or more well-spread, non-collinear placed phones. Add a tape-measured "survey point" source (σ 0.2 m). Warn when placed phones are within 15° of collinear. | Rotation error ≈ position error ÷ baseline, for example about 4° for 3 m over 40 m; works on iPhone 14+ too | `MeshLocator`, `LayoutSolver` priors, placement UI | S |

## Phase 2: medium (after merging `main` into the feature, about 1–2 weeks)

| # | Change | Gain | Where | Effort |
|---|---|---|---|---|
| 7 | **"Find direction" walk (synthetic aperture).** The user walks a short L-shaped path; the phone combines its own step-and-heading track (PDR) with its own ~10 Hz UWB ranges to a stationary placed neighbour, and solves for the neighbour's bearing. Publish only after a turn of ≥ 45° and a span of ≥ 3 m (a straight walk is mirror-ambiguous 86 % of the time). Fills the existing v4 `uwbBearingDeg`/`uwbBearingErrorDeg` fields, so **no wire change**. | *sim:* 7.9° median / 21° p95 bearing; 1.45 m median position. **Works on iPhone 14+**, which have no UWB direction | New MeshCore `ApertureSolver`, `MotionTracker` + `PedestrianDeadReckoning` from `main`, `MeshModel.withUWB`; on `main`, a range update in `PositionFilter` with a two-filter mirror bank in `FusionEngine` | L |
| 8 | **Per-phone compass bias as a solver unknown.** Where the geometry is redundant, solve each reporter's constant compass offset. | 10–20° → about 5–8° residual | `LayoutSolver.Problem.bearingBiasPrior`, persisted in `MeshLocator` | M |
| 9 | **Rank direction-capable peers first in the session budget.** A rigidity-aware policy alone barely helps (*sim:* 2.3 % → 3.3 % of lost phones pinned), so this is a cheap ordering tweak only. | Small | `UWBSessionPolicy`, `RangingToken.uwbDirection` (sent today but never read) | S |
| 10 | **Anchor placement hints.** Use the solver's uncertainty to suggest where one more fixed phone would best resolve the unresolved ones. | Better geometry at the demo site | `MapPresentation.placementHints`, `PhoneMapView` | M |

## Phase 3: hardware and research (only if time and budget allow)

| # | Option | Expected bearing error | Notes |
|---|---|---|---|
| 11 | **Mounted UWB angle anchors**: used iPhone 11–13 with surveyed heading (easy), or Qorvo QM33120W 2-antenna kits | about 5–15° in the field (vendor: under 5°) | Best absolute bearing. The anchor measures the phone, so it also covers iPhone 14+. The DWM3001CDK has one antenna and cannot measure angle |
| 12 | **Camera-assisted direction on iPhone 14+** (`isCameraAssistanceEnabled`, `setARSession`) | unknown; reports of nil direction | Foreground, camera on, needs about 10 s of panning; not for mounted anchors; use `.gravity` alignment and take rotation from geometry |
| 13 | **Bluetooth 5.1 direction finding** (u-blox XPLR-AOA, nRF52833/nRF5340) | about 5° (vendor) | iPhones cannot transmit the required tone (no iOS API found), so each phone needs a clip-on tag plus fixed locators |
| 14 | **Sliding-window solver with motion between poses** | — | Makes 1 and 7 proper solver terms; needs neighbour motion shared (wire v5) |
| 15 | RSSI tricks (body-shadow sweep, gradients) | 30–90° | Front/back hint at most. Last priority |

## Verify on phones before trusting any bearing

1. **Axis convention.** Lay the phone flat with its top pointing north and the peer ahead, then repeat with the phone upright facing east. A transposed matrix shows about 180° error in the first case; wrong reference axes about 90°. The "stand north, then east" check in `features.md` cannot catch a transposed matrix.
2. **Frame alignment.** Use bearings only in frames whose +z is true north (geo frames), or add a per-frame north offset. Today, hand-held bearings are rotated wrongly in a manual frame.
3. **Compass indoors and near laptops.** Log `headingAccuracy` and field magnitude at the demo site.
4. **Two-ended consistency.** A→B should equal B→A + 180° within the stated error.
