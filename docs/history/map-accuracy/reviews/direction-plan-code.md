> **Historical:** part of the review of the unmerged branch `feature/map-accuracy` at `87b2f6c`, not `main` (see [../REVIEW_VERDICT.md](../REVIEW_VERDICT.md) and [docs/AUDIT.md](../../../AUDIT.md)).

# Direction accuracy plan (code-grounded)

Scope: `origin/feature/map-accuracy` (read via `git show`; the checkout is `main`). Numbers come from `direction_sim.py` in this scratchpad folder (pure Python, 300 trials per case). Swift paths below are relative to `ios/`.

## Where direction comes from today

- **Bearings.** Only U1 phones (iPhone 11–13) produce them: `UWBRanging.session(_:didUpdate:)` → `MeshModel.bearing(for:)` → `PeerBearing.bearing`. The error is a fixed √(15² + compass²), where the compass term is 10/20/35°. A bearing is held for 1 s and sent once per second in `neighbors`.
- **One bearing per link.** `BluetoothEstimator.input` keeps only the lower-error end of a→b and b→a. The other end is thrown away.
- **Per-tick solving.** `MeshLocator.solve` runs a fresh Levenberg–Marquardt solve (`LayoutSolver.solve`) every tick. Its only memory is an isotropic prior on the previous solution, with σ² = var + (1.4 m/s · Δt)². The 1.4 m/s walking speed is assumed for every phone.
- **Ring decision.** `relativeSigma > max(3 m, r/2)`, or the particle filter reports ambiguous with no bearing → ring. Two spots (two ranged neighbours) are not modelled in the solver. LM simply keeps whichever mirror it was warm-started in.
- **No motion data.** The branch has no PDR. `main` gained `PedestrianDeadReckoning`, `MotionTracker` and `PositionFilter` (an EKF over x, z, receiver offset and heading offset) after the branch point. They arrive when `main` is merged in.

## Phase 1: quick wins (no wire change)

### Q1. Motion-aware temporal prior (S) — biggest cheap gain
- **What it fixes.** A stationary phone loses a bearing-based fix within about 4 s of the bearing disappearing, because the prior grows 1.4 m every second. Bearings are intermittent (field of view, 1 s hold).
- **Sim B.**
  - Stationary phone at 5 m, bearing present 30 % of ticks: resolved **78 % → 99.7 %** of ticks.
  - At 10 m with bearings 15 % of ticks: **68 % → 97 %**.
- **Change.**
  - `MeshLocator`: add `private var rangeHistory: [LinkKey: [(t: Double, d: Double)]]` and `func speedBound(_ id: String) -> Double`.
  - `speedBound` returns 0.2 m/s when every UWB range of the phone changed < 0.3 m over 5 s and its report position (if any) is steady. Otherwise it returns `walkingSpeed`.
  - Use it in place of `walkingSpeed` for `walked` in `solve`.
  - On `main`, the phone itself can also use `PedestrianDeadReckoning.isWalking(at:)` for its own entry.
- **Tests (`MeshLocatorTests`).**
  - Bearing on ticks 1 and 5 only, constant range: not ambiguous on ticks 2–4.
  - Range changing 1 m/s: falls back to 1.4 m/s.
- **Risk.** A phone walking around its neighbour at constant radius looks stationary. Cap the low-noise prior at 10 s without a fresh bearing.

### Q2. Two-ended bearing fusion and a consistency gate (S)
- **Sim D.** 18° per end, plus a 10 % chance of a 40–90° magnetic blunder on one end. Median **12.1° → 9.3°**, p95 **35° → 31°**.
- **Change.**
  - `LinkMeasurement` gains `reverseBearing: LinkBearing?`. This is in Models/BluetoothEstimator.
  - `BluetoothEstimator.input` keeps both ends instead of the lower-error one.
  - `MeshLocator.solve` adds two `LayoutSolver.Bearing` terms, because the compass errors are independent.
  - If |b₁ − (b₂ + 180°)| > 3·√(e₁² + e₂²), drop the end with the larger error and set a per-reporter "disturbed" flag. Q3 consumes the flag.
- **Tests.**
  - Two consistent ends: σ shrinks by about √2.
  - A 90° conflict: the outlier is dropped.

### Q3. Better bearing error model (S)
Three changes, all in the bearing path:
- **Field-of-view inflation.** In `PeerBearing.bearing(direction:attitude:compassErrorDegrees:)`, let θ = the angle between the direction and the device −z axis. Use error_aoa = 15° · (1 + (θ/60°)²) and return nil when θ > 75°. Also divide the AoA term by the horizontal norm h (already ≥ 0.3), so near-vertical rays get honest errors.
- **Magnetic disturbance.**
  - `OrientationSource.apply`: read `sample.magneticField.field` (μT). Keep a 30 s median of |B|.
  - If |B| is more than 20 % from the median, or outside 25–65 μT, set `compassErrorDegrees` to max(current, 45°). Use nil when it is more than 40 % off.
  - New `static func disturbance(fieldMagnitude: Double, median: Double) -> Double?`, so it can be unit-tested in MeshCore as `CompassHealth`.
- **In-window averaging.** In `UWBRanging.session(_:didUpdate:)`, use the circular mean of the AoA samples from the last 1 s. Error = √(15²/n_eff + c²) with n_eff = min(n, 3), because hand motion correlates the samples. At high calibration: 18° → 13.2°.
- **Expected effect.** Mostly fewer gross outliers indoors. The p95 gain is unknown until tried on phones; my guess is a ~2× smaller p95 near laptops and steel.
- **Tests.** `PeerBearing`: off-axis inflation and the vertical-ray case. `CompassHealth` thresholds.

### Q4. Mirror (two-spot) hypotheses (S–M)
- **What it fixes.** A phone ranged to exactly two placed neighbours has two solutions. Today the solver silently keeps the warm-start one and can flip between ticks (the design-doc risk "markers jump").
- **Change.**
  - In `MeshLocator.solve`, for each lost id with exactly 2 ranged placed neighbours, reflect its start across their line and re-solve. This is one extra `LayoutSolver.solve` with one point changed.
  - Δ = cost_alt − cost_best.
  - Keep `mirrorEvidence[id] = 0.8·old + Δ`, so weak cues accumulate: bearings, RSSI to third phones, and Q1 continuity.
  - Resolved when |evidence| > 6 (χ² with 1 dof is about 2.5σ). Otherwise mark it ambiguous.
  - New `PhoneFix.alternative: FloorPoint?`, so `PhoneMapView` draws "two spots" instead of a ring.
- **Mapping to `main`.** The same reflect-and-compare applies to `SignalMap`'s "pinned" mode.
- **Tests.**
  - Symmetric case: `alternative` is set.
  - An added third RSSI link breaks the tie after N ticks.
  - No flip across ticks.

## Phase 2: medium

### M1. Synthetic aperture from own motion (L) — biggest coverage gain
- **What it fixes.** It gives a bearing on every UWB phone, including U2 phones (iPhone 14+) that have no AoA, from the phone's own walk plus its own 10 Hz UWB ranges to a placed neighbour.
- **Sim A.** Walk 10 s at 1.3 m/s, compass bias σ 10°, stride error 5 %, 10 % NLOS ranges, neighbour 4–15 m away.

  | Walk | Bearing median / p95 | Position median / p95 | Mirror unresolved |
  |---|---|---|---|
  | L-turn | **7.9° / 21°** | **1.45 m / 5.0 m** | 0 % |
  | Meander | 7.6° / 25° | 1.3 m / 7.0 m | 3 % |
  | Straight | 14.6° / 105° | 3.4 m / 23 m | **86 %** (16 % wrong flips) |

  Accuracy is bounded by the compass, because a rotation about the neighbour is unobservable. It does not depend on AoA.
- **Change.**
  - New MeshCore `ApertureSolver`:
    `struct ApertureSample { t: Double; dx: Double; dz: Double; range: Double }`
    `static func solve(_ s: [ApertureSample], headingSigmaDeg: Double) -> ApertureResult?`
    `struct ApertureResult { bearing: LinkBearing; mirrorGap: Double; span: Double }`
  - The solver does a 72-start grid plus a Gauss-Newton refine over the start offset, with Huber residuals.
  - Publish only if mirrorGap ≥ 4, the path turned ≥ 45° and its span is ≥ 3 m.
  - The neighbour must be stationary: source manual or uwb, or anchor role. GPS neighbours come in v2 with a `moving` flag (wire v5).
  - Inputs: PDR steps from `main`'s `PedestrianDeadReckoning` via `MotionTracker`, aligned to true north with `OrientationSource.heading`. Ranges come from `UWBRanging.onMeasurement`.
  - Output: put it into `MeshModel.withUWB` as `uwbBearingDeg` / `uwbBearingErrorDeg` when no AoA bearing exists. This needs **no wire change**, because the v4 fields already exist.
  - Alternative on `main`: add `PositionFilter.updateRange(toX:z:distance:sigma:)` and run two filters (a mirror bank) in `FusionEngine`. The heading-offset state is already there.
- **Tests.** Synthetic L-walk recovers the bearing within 3° when there is no noise. A straight walk returns nil. NLOS outliers are tolerated.
- **Risks.**
  - PDR stride and heading on hand-held phones.
  - The user must actually walk.
  - The neighbour must really be stationary.
  - UI honesty: label the result "bearing from motion".

### M2. Rigidity- and bearing-aware session budget (S–M)
- **Sim C.** 12 phones, 3 GPS, budget 4, 25 m UWB range. A greedy rigidity policy barely changes the share of lost phones placed by trilateration: **2.3 % → 3.3 %**. It also turns rings into two-spots (two-spot 18 % → 33 %). Link choice alone cannot create direction when the budget is 4.
- **What to do.** Make the cheap change and do not expect miracles:
  - `UWBPeerCandidate` gains `peerHasDirection` (from `RangingToken.uwbDirection`) and `placedRangedCount`.
  - Within class 1, rank a bearing-capable peer first, then a placed neighbour this lost phone is not yet ranged to. Both ends rank from the same shared reports, so they still agree.
- **Tests.** `UWBPolicyTests`: ordering, and the 20 s hold is unchanged.

### M3. Per-reporter bearing bias (M)
- **Change.**
  - `LayoutSolver.Problem` gains `bearingBiasPrior: [String: Double]` (degrees σ per reporter). The solver adds one unknown per reporter that has ≥ 2 bearings or reciprocal pairs.
  - The residual becomes angle − measured − β_reporter.
  - Persist β across ticks in `MeshLocator`, with a slow decay.
- **Expected effect.** It removes the constant compass offset per phone, which is the dominant term after averaging: 10–20° → about 5–8° where the geometry is redundant.
- **Test.** A 20° injected bias is recovered within 5° with 3 placed phones.
- **Risk.** It needs redundancy. Without it the bias is unobservable, so keep the prior tight.

### M4. Anchor placement guidance (M)
- **Change.**
  - Use `LayoutSolver.Solution` covariance. For each unresolved phone, grid-search candidate spots 3–15 m away for the one where one added fixed phone's range term most reduces the cross-range σ (Fisher information on the axis perpendicular to the existing link).
  - New `MapPresentation.placementHints(solution:) -> [FloorPoint]` and a dashed marker in `PhoneMapView`.
  - Warn when the placed phones are within 15° of collinear.
- **Test.** Two anchors on a line: the hint lies off the line.

## Phase 3: research

- **R1. Sliding-window factor graph** (L): time-indexed poses (5–10 s) with PDR between-factors in `LayoutSolver`, so M1 and Q1 become solver terms. Needs neighbour motion shared (wire v5: per-second displacement and `moving`).
- **R2. Camera-assisted NI direction on U2 phones** (`NINearbyPeerConfiguration.isCameraAssistanceEnabled` + ARKit) (L).
- **R3. Body-shadow RSSI bearing**: correlate RSSI with heading while the user turns in place. My estimate is 30–45° at best and noisy. Last priority.

## Order and expected result

1. **Q1 → Q2 → Q3 → Q4**: about a week, MeshCore-heavy and unit-testable on Windows-less CI. Stationary phones that see a bearing even 15–30 % of the time stay resolved about 97–100 % of ticks, and flips stop.
2. **M1** (after merging `main` for PDR) extends bearings to U2 phones at roughly compass accuracy, about 8° median, but only after a turning walk.
3. **M2–M4** are polish. **R1–R3** are research.
