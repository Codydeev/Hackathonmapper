> **Historical:** part of the review of the unmerged branch `feature/map-accuracy` at `87b2f6c`, not `main` (see [../REVIEW_VERDICT.md](../REVIEW_VERDICT.md) and [docs/AUDIT.md](../../../AUDIT.md)).

# Review 3: signal direction and bearings (origin/feature/map-accuracy)

Reviewed with `git show origin/feature/map-accuracy:<path>`. The local checkout is `main`. Math check: `scratchpad/bearing_check.py`, 0 failures.

## Verdict: B+

The bearing math is correct end to end. `PeerBearing.mapVector` (Rᵀ·d, then (N,W,U) → (E,U,N)) gives the true bearing in all 30 cases I checked: upright facing N and E, flat with the top N and E, pitched 40°, rolled 30°, with the peer in front, beside, behind and above. `AnchorGeometry.mapDirection`, `headingDegrees`, the `reversed` handling in `BluetoothEstimator.input`, `Link`, `ringSample` and the particle likelihood, and the `LayoutSolver` residual and Jacobian (∂atan2/∂x = dz/q, ∂/∂z = −dx/q) are all consistent with "bearing a→b, 0 = +z, 90 = +x".

The rotation-matrix convention (v_device = R·v_ref, with ref x = north and y = west) matches Apple's own pARk sample. pARk builds its camera transform from `rotationMatrix` used as-is, and puts its places of interest at (n, −e, 0) in `.xTrueNorthZVertical`. I worked through its projection and it puts a north POI at screen center only under this convention. Apple forum thread 773168 conflicts with this: there, yaw = 0 occurs with the top edge pointing north, and Apple DTS was itself unsure. So the convention still needs one test on a phone.

What keeps the grade from A: hand-held bearings are true-north bearings, but nothing checks that the frame's +z is north. The compass error also comes from a weak signal.

## Findings

1. **Hand-held bearings assume map +z = true north in every frame.** `MeshModel.swift:576-585` and `Ranging.swift:220-239`.
   - **Problem:** `frameID` can be edited, and manual positions work in frames without a `GeoFrame` origin, where +z is just "forward". Anchor bearings, by contrast, use the frame-relative `anchorHeading`.
   - **Failure:** in an indoor frame whose +z points 70° east of north, every hand-held bearing is rotated 70°. The solver pulls phones onto the wrong side, and the bearings disagree with the anchor bearings.
   - **Fix:** send hand-held bearings only when `GeoFrame.origins[frameID] != nil`, or add a per-frame north offset.
   - **Confidence:** high (the code path is certain; impact depends on which frame is used).

2. **Matrix convention is unverified on hardware, and the obvious test cannot catch an error.** `Ranging.swift:171-201`.
   - My script shows that a transposed matrix gives the correct bearing for an upright phone with its back facing east (all five peers). So the features.md test ("stand north, then east") can pass while the matrix is wrong. With the top pointing north and the phone flat, a transpose gives a 180° error. With the back facing north, it gives 90°.
   - If Apple's reference were effectively ENU (as the forum post claims for yaw), every bearing would be off by +90°.
   - **Fix:** add the on-phone checks below, and log `m11…m33` once on the diagnostics screen.
   - **Confidence:** medium that the code is right (pARk supports it), high that the check is needed.

3. **The compass error comes from `CMCalibratedMagneticField.accuracy`.** `OrientationSource.swift:82-103`.
   - That value is a coarse 4-level enum about magnetometer bias calibration. It says nothing about local disturbance, which is the dominant error indoors and near laptops. It can also stay `.uncalibrated` for a long time, which turns off every bearing without telling the user.
   - The 10° value for "high" is optimistic indoors (features.md itself says 30°+).
   - **Fix:** use `CLLocationManager` `CLHeading.headingAccuracy` (degrees) where available. Raise the floor to about 20°. Show "compass uncalibrated → no bearings" in diagnostics.
   - **Confidence:** medium.

4. **Azimuth error does not grow with elevation.** `Ranging.swift:227-238`.
   - `minHorizontal = 0.3` accepts directions up to 72° from horizontal. Near vertical, a fixed angular error becomes an azimuth error of about err/cos(elevation), up to 3.3×. Example: a peer on the floor below, or one held high.
   - **Fix:** use `errorDegrees / horizontal`, capped at 180, or raise `minHorizontal` to about 0.5.
   - **Confidence:** high, but it matters only in edge cases.

5. **The attitude can be up to 100 ms older than the NI sample.** `OrientationSource.swift:10`, `UWBRanging.swift:212`.
   - While the user turns at 90°/s, that is up to 9° of error, all in one direction.
   - **Fix:** run at 30–50 Hz, or read `motion.deviceMotion` when the NI update arrives. Optionally drop bearings while |rotationRate| > ~1 rad/s.
   - **Confidence:** medium, low impact.

6. **The errors are treated as 1σ, but the numbers are rough bounds.**
   - `LayoutSolver` (Huber k = 1.345) and the particle filter use them as Gaussian σ. On the anchor side the same 15° appears as a 95% bound in `AnchorGeometry.accuracy`.
   - Huber makes this tolerable. But a single consistently wrong compass (mirrored, or offset 90°) is not an outlier, so Huber cannot reject it, and it will rotate the whole group.
   - **Fix:** a cross-check, finding 7.
   - **Confidence:** medium.

7. **No consistency check between the two ends of a link.** `BluetoothEstimator.swift:606-610`.
   - When both ends report a bearing, the code keeps the one with the smaller error and drops the other. A→B and (B→A)+180 should agree within the combined error. If they don't, a compass or convention bug is present.
   - **Fix:** if they disagree by more than about 3σ, drop both and count it in diagnostics. This catches findings 1–3 in the field.
   - **Confidence:** high value, cheap.

**Gating is realistic.** Field-of-view gating comes for free, because NI returns no `direction` outside the cone. The 1 s hold is safe because the bearing is held in the map frame, not the device frame. A flat phone is gated by the result vector, not by the attitude, which is correct: a flat phone with the peer in its x-y plane is simply outside the field of view. Gating on iPhone 11–13 follows from `direction` being nil on U2 phones.

## Done well

- The math is clean and general: landscape, roll and pitch all work, and the handedness is right even though the map frame (E, U, N) is left-handed. The mapping is a relabeling, not a cross product.
- `reversed` is applied exactly once in each consumer, and the comments state the direction explicitly.
- The tests encode the documented convention and say how to flip it.
- No bearings are sent without a calibrated compass. Anchors use gravity plus the entered heading and need no magnetometer.

## Phone verification steps

1. **Convention:** lay phone A flat, screen up, top pointing at a known north, with peer B 3 m away due north. The bearing should be ~0°. If it reads ~180°, the matrix is transposed (use `R`, not `Rᵀ`). If it reads ~90° or ~270°, the reference axes are ENU.
2. Hold A upright with its back facing north and B straight ahead: expect ~0°. Move B 45° to the right: expect ~45°, not ~315°.
3. Repeat step 2 with A rolled to landscape: the bearings should be unchanged.
4. **Reciprocity:** A and B each point at the other. `uwbBearingDeg` on A should equal B's value + 180 within ±30°.
5. Compare the heading-up map with Apple's Compass app at three orientations, indoors and outdoors. Log `magneticField.accuracy` for 5 minutes after launch.
6. In a non-Hervanta frame, confirm that no hand-held bearings are sent (after the fix for finding 1).
