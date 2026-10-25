> **Historical:** describes the unmerged branch `feature/map-accuracy` at `87b2f6c`, not `main`. Its phone-to-phone UWB distances were ported to `main` as wire v5 (`feature/uwb-v5`); `MeshLocator`, `LayoutSolver`, hand-held UWB bearings and the map UI described here are not on `main`. See [docs/AUDIT.md](../../AUDIT.md).

# Judge verdict: `feature/map-accuracy` (87b2f6c)

I read all six reviews (1, 2, 3, 4, 5, 6). Every MEDIUM-or-higher finding below was checked against `git archive origin/feature/map-accuracy` (extracted to `scratchpad/judge/`). Line numbers refer to 87b2f6c.

## 1. Verification of findings (MEDIUM+)

| # | Finding (reviewer) | Verdict | Evidence |
|---|---|---|---|
| A | Token resend refreshes `progressAt`, so the 20 s timeout never fires (R1-2, R2-3, **merged**) | CONFIRMED | `UWBRanging.swift:155` sets `progressAt = now` unconditionally, and `:134-136` resends every 5 s while there is no reading. |
| B | Non-UWB peers get a slot again every 80 s and displace working sessions (R2-1) | CONFIRMED (only with more than 4 neighbours) | `rangingCandidates` (`MeshModel.swift:536-557`) has no capability filter. The hold protects a session only for less than 20 s (`UWBSessionPolicy.swift:49-58`). |
| C | Selection is not mutual, so sessions churn (R2-2) | CONFIRMED (only with more than 4 neighbours) | `MeshModel.swift:610` drops tokens from unselected peers, and each end ranks its own top-k. **Merged with B.** |
| D | Hand-held bearings assume map +z is true north (R3-1) | CONFIRMED | `MeshModel.swift:583-585` uses the `.xTrueNorthZVertical` attitude with no frame check, while anchors use the frame-relative `anchorHeading`. **Worse after a merge:** main's `GeoFrame.Origin.bearingDegrees` lets even geo frames rotate +z. |
| E | Rotation-matrix convention is unverified (R3-2) | PARTLY (a risk, not a proven bug) | `Ranging.swift:174-201` documents the assumption. Only a phone can settle it. |
| F | Compass error comes from the coarse `magneticField.accuracy` (R3-3) | PARTLY | `OrientationSource.swift:95-102` confirms the mapping. Whether it really stays `.uncalibrated` for long is unverified. |
| G | No cross-check between the two ends of a link (R3-7) | CONFIRMED | `BluetoothEstimator.swift:610` keeps the smaller-error bearing and never compares it with the reverse bearing. |
| H | Larger reports reduce mesh capacity (R1-1) | PARTLY | The growth is real (`Models.swift:61-71`, long keys). The impact is unmeasured, and the bottleneck is the existing `.withResponse` write (`BluetoothMesh.swift:524`). Downgraded to Low for a demo of 5 or fewer phones. |
| I | Temporal prior double-counts, so rings turn into dots (R5-1) | CONFIRMED (mechanism) | `MeshLocator.swift:227-232` feeds back the previous *marginal* σ² + (1.4 m/s·dt)² as an independent per-phone prior. The covariance (`LayoutSolver.swift:188`) includes it. The fixed point is σ ≈ walk step ≈ 1.4 m, which is below `unresolvedSigma` 3 (`:322`). The particle filter's `ambiguous` flag (`:324`) may rescue some cases, so test it on phones. |
| J | σ/r95 are 2–6× overconfident (R5-2) | CONFIRMED | Same lines. The anchor prior `:225` is re-added every tick as new evidence. **Merged with I.** |
| K | Covariance ignores residual inconsistency (R5-3) | CONFIRMED | `LayoutSolver.swift:188-196` inverts H with no cost/dof scaling. |
| L | Convergence is truncated at 30 iterations (R5-4) | CONFIRMED (code). The impact rests on R5's simulation only. | `LayoutSolver.swift:149, 181`. |
| M | Lost ring phone is drawn as a dot on its neighbour (R6-1) | CONFIRMED | `BluetoothTracker.swift:147` stores `ring.center`, and `:153-155` draws `.lastSeen` at that point. |
| N | Manual pin is drawn in the GPS colour (R6-2) | CONFIRMED | `PhoneMapView.swift:392`: `case .reported: return gpsColor` covers `.manual`. |
| O | Track tab shows directions while this phone is on a ring (R6-3) | CONFIRMED | `TrackView.swift:92` uses `tracker.me?.point` with no check of `me.directionUnresolved`. |
| P | RSSI links turn amber (R6-4) | PARTLY | `PhoneMapView.swift:341` applies the test to `measuredDistance`, RSSI included. How noisy this is has not been seen on phones. |
| Q | Map redraws on every packet (R6-5) | PARTLY | It is plausible from `@EnvironmentObject`. The cost is unmeasured. |
| R | R4-1/2/3: two calibrators, calibration from imprecise "known" distances, per-second refit of n | **Applies to main, not the feature** | The feature has a single `RadioCalibrator`: p0 only, n fixed, median of the last 120 UWB-truth samples, clamped −75…−45 (`RadioCalibrator.swift`). It feeds both the map and TrackView (`MeshLocator.swift:115-116`, `BluetoothTracker.swift:78`). R4-4 does not apply either: `LayoutSolver` applies Huber to RSSI. R4-5 (stale advertisement RSSI, `BluetoothMesh.swift:579`) and R4-6 (connection and advertisement RSSI mixed) apply to **both** branches. |

Rejected: none outright. H, P and Q are downgraded.

## 2. Ranked confirmed issues

| Rank | Severity | Where | Fix | Effort |
|---|---|---|---|---|
| 1 | **High** | `MeshLocator.swift:227-232, 285-289` (I+J) | Compute σ, r95 and `unresolved` from normal equations *without* the temporal priors; keep the priors for the warm start only. Floor gpsRefined σ at 0.5·accuracy. Test: 1 GPS phone plus a rigid UWB triangle is still a ring after 60 ticks. | M |
| 2 | **High** | `MeshModel.swift:583-585` (D) | Send hand-held bearings only when `GeoFrame.origins[frameID]` exists. After a merge, also require (or rotate by) `bearingDegrees`. | S |
| 3 | Medium | `UWBRanging.swift:155` (A) | Refresh `progressAt` only when `changed \|\| isNewSession`, or require a measurement within 20 s of the swap. | S |
| 4 | Medium | `BluetoothEstimator.swift:606-610` (G, guards E) | If A→B and (B→A)+180 disagree by more than 3σ, drop both and count it. Log `m11…m33` once in diagnostics. | S |
| 5 | Medium | `PhoneMapView.swift:392` (N) | Give `.reported(.manual)` its own colour and legend row. This is an honesty rule in CLAUDE.md. | S |
| 6 | Medium | `BluetoothTracker.swift:147, 153-155` (M) | Flag a ring in `lastSpot` and draw `.lastSeen` as a growing dashed ring with no dot. | S |
| 7 | Medium | `MeshModel.swift:536-557`, `UWBSessionPolicy.swift:53-58` (B+C) | Accept an unselected token when a slot is free. Add a decline frame or a UWB flag in the Hello, backoff on `silentCooldown`, and 6 dB hysteresis. | M |
| 8 | Medium | `LayoutSolver.swift:188-196` (K) | Scale the covariance by max(1, 2·cost/dof). | S |
| 9 | Low-Med | `TrackView.swift:65-67, 92` (O) | When this phone is on a ring, show distances only and centre the radar on `ring.center`. | S |
| 10 | Low-Med | `LayoutSolver.swift:149, 181` (L) | Stop on ‖g‖∞ < 1e-3 or a relative cost change < 1e-6. Allow 100 iterations on a cold start. | S |
| 11 | Low | `OrientationSource.swift:95-102` (F) | Show "compass uncalibrated, no bearings" in diagnostics. Raise the error floor to about 20°. | S |
| 12 | Low | `PhoneMapView.swift:341` (P) | Apply the inconsistency test to UWB links only, or use a ×2 band for RSSI. | S |
| 13 | Low | `UWBRanging.swift:52, 263, 89-98` | Reset `sessionBudget` and `permissionDenied` in `stop()`. Let the budget recover slowly. | S |
| 14 | Low | `BluetoothMesh.swift:579` (R4-5, both branches) | Set the RSSI to nil when the sample is older than 5 s, or report `ageMs = max(link, sample)`. | S |
| 15 | Low | `Models.swift:61-71` (H) | Short CodingKeys, and omit the default error value. | S |
| 16 | Low | `PhoneMapView.swift:12, 51` (Q) | Move `Map` into a child view that observes only the tracker, if profiling shows stutter. | M |

## 3. Grades

| Area | Reviewer | Judge | Reason |
|---|---|---|---|
| BLE transport / wire v4 | B | **B** | Accepted. The bump is correct and well tested. Costs are only for capacity. |
| UWB ranging | B− | **B−** | Accepted. A and B+C are real but invisible at 5 or fewer phones. |
| Direction / bearings | B+ | **B** | Lowered. D is a certain bug in any frame that is not north-up, and it gets worse on main's rotated frames. E is unverified, and G (the cheap guard against it) is missing. |
| RSSI | B− (main) | **B** for the feature | R4 reviewed main. On the feature, `RadioCalibrator` already avoids R4's main-branch problems 1–3. R4-5/6 remain. Main's stack keeps R4's B−. |
| Solver / locator | C+ | **C+** | Accepted. The code confirms the mechanism of issue 1, and it breaks the ring-not-dot rule that is the feature's headline. |
| Map UI / honesty | B | **B** | Accepted. Two honesty slips (M, N) are each S fixes. |

## 4. Overall verdict: do not merge the branch as is. Port the UWB layer onto main.

**Readiness on its own.** After fixes 1–6 (about 1 day), the branch would be demo-ready for 3–5 phones.

**Merging it into today's `main` is the real problem.**
- `git merge-tree` reports 7 conflicts:
  - modify/delete on `BluetoothEstimator.swift` and its tests. Main deleted the particle filter, while the feature's `MeshLocator` depends on its estimates and ambiguity flag.
  - content conflicts in `BluetoothTracker`, `ContentView`, `MeshModel`, `PhoneMapView` and `TrackView`.
- Main also adds `PositionSource.fused` and rotated `GeoFrame` origins. These hit the feature's switches and bearing math.
- The two branches carry rival positioning stacks:
  - main: `SignalMap` (mirrored in TS on the dashboard), `FusionEngine` EKF, PDR and `RangeSolver`
  - feature: `MeshLocator`, `LayoutSolver` and the particle filter
- Keeping both would mean two placements on one screen, which is the exact conflict `POSITIONING_REVIEW.md` closed.

**What the feature adds that main lacks:** phone-to-phone UWB ranging. Main's positioning has no UWB peer-ranging term at all.

**Recommended merge plan (L, about 1.5–2 days).**
1. Take onto main:
   - `UWBRanging` and `UWBSessionPolicy` (with fixes 3 and 7)
   - `OrientationSource`, `PeerBearing` and `AnchorGeometry` (with fixes 2 and 4)
   - wire v4 `NeighborObservation` UWB fields and their tests, plus a `contract.ts` comment
2. Feed UWB distances and bearings into `SignalMap` and `RangeSolver` as tight-σ terms (and into the TS mirror).
3. Replace main's dual calibrators with the feature's UWB-truth p0 calibrator idea. This fixes R4-1/2/3.
4. Port `MapPresentation` (camera, link styles, rings) and UI fixes 5, 6, 9 and 12 onto main's views.
5. Drop `MeshLocator`, `LayoutSolver` and the `BluetoothEstimator` changes. Issue 1 then disappears with them, unless the locator is kept.
6. Bump to protocol v4 and ship to every phone together.

## 5. Must test on phones (by risk)

1. **Rotation-matrix convention.** Phone flat, top pointing north, peer due north: expect 0°. 180° means transposed; 90° or 270° means ENU. Then upright, back facing north, peer 45° right: expect 45°.
2. **Ring stays a ring.** 1 GPS phone plus 2 UWB phones in a fixed triangle, idle 60 s: no dots (issue 1).
3. **Slot release.** Pocket one phone of a UWB pair, or move it out of UWB range with BLE still up, for more than 30 s. The slot must be released after about 20 s (issue 3).
4. **Reciprocity.** A→B bearing equals (B→A)+180 within ±30°. Also check whether `magneticField.accuracy` ever leaves `.uncalibrated` indoors.
5. **Mixed builds.** A v3 and a v4 phone refuse each other with a clear error, then recover once both run the same build. Gateway upload returns 200 with UWB fields present.
6. **Many phones.** 5–6 UWB phones plus one non-UWB phone: watch for `activeSessionsLimitExceeded`, `uwbSessionBudget`, and teardowns about every 80 s.
7. **Tape measure.** Two UWB phones 4.0 m apart: the map label and the scale bar both show 4 m ± 0.3.
8. **Ring phone leaves.** Walk the ring phone out of reach: no labelled dot on its neighbour. A manual pin is not drawn in GPS purple.
9. **Report age and lag.** With 6+ phones, measure 2–3-hop report age with UWB on vs off. Log `maximumWriteValueLength`.
10. **Map behaviour.** Smooth pan with 6+ phones, no camera moves when untouched, and pinch zoom holds.
