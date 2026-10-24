# Review 4: Bluetooth RSSI positioning (27760d0..HEAD)

**Scope note.** The brief's targets `BluetoothEstimator.swift` (particle filter, tempering, ring seeding, silence penalty, UWB-replaces-RSSI) and `RadioCalibrator.swift` are **not in HEAD**. This diff deletes the particle filter (−473 lines, along with its tests and `website/server/estimator.ts`), and `RadioCalibrator` never existed. RSSI now goes through `SignalMap` (stress layout, used by the phone and the dashboard), `PathLossModel`/`PathLossCalibration`/`MotionAwareRSSI` + `RangeSolver` + `FusionEngine` (EKF), and the old `RSSIStatistics`. I reviewed those. Python checks are in `scratchpad/r4/sim.py`.

## Verdict: B−

The modelling is sound and honest. It uses the log-distance model with log-normal spread, range σ grows in proportion to distance, and both ends of a link are averaged. The fusion takes the right care with correlated shadowing: an 8 dB floor and re-feeding only after 2 m walked or after the still sample count doubles. A fused phone's anchor links are kept out of the signal map, so the same RSSI is not counted twice. The UI labels every RSSI-derived spot ("placed from Bluetooth", "moved to fit its Bluetooth links", rings when the direction is unknown). The parameters (−59 dBm at 1 m, n 2.5, σ 5 dB) sit within published phone-to-phone BLE ranges: p0 −55…−65, n 2.0 LOS to 3+ indoors/body, σ 4–8 dB. The weak point is **calibration**. There are two independent fitters with different input rules. One of them fits p0/n anew every second from as little as one link whose "known" distance can carry metres of error. Nothing guards against body or pocket loss, and every test uses noise-free RSSI.

## Findings

1. **Two calibrators, two radios for the same link.** `SignalMap.calibrate` (SignalMap.swift:183) feeds `BluetoothTracker.radio`, which drives the TrackView distance and the map. `PathLossCalibration.fit` (PathLossModel.swift:73, called at MeshModel.swift:470) feeds fusion. They have different priors (n σ 1.5 vs 0.6), different inputs (any phones with r95 ≤ 3 m vs anchor-role phones with no accuracy filter) and per-device offsets in only one of them. *Failure:* the same anchor link reads 3.1 m on the Track tab and 4.4 m on the fusion panel. This brings back conflict #2 from POSITIONING_REVIEW.md, which the docs say is "Done". *Fix:* use one fit (PathLossCalibration, offsets included) and pass its model into `SignalMap.solve`. Mirror it in TS. *Confidence: high.*

2. **Calibration from imprecise "known" distances.** SignalMap.swift:191 accepts any pair with r95 ≤ 3 m, including GPS (horizontalAccuracy ≤ 1.85 m × 1.62) and **fused** phones, whose positions are themselves derived from RSSI, so the calibration is circular. With two phones truly 2 m apart and r95 3 m each, the sim gives p0/n fits that move the range at −75 dBm from 4.4 m to anywhere between 3.1 and 8.8 m. A 2 m link with σ≈1.7 m position error carries about 9 dB of error, more than the prior. *Fix:* calibrate only from `manual`/`uwb` sources and weight each link by `(σ_dB² + (10n/ln10 · σ_d/d)²)⁻¹`. Require d ≥ 2·σ_d. *Confidence: high (code), medium (how often GPS reaches 1.85 m).*

3. **Per-second refit from a single link, loose n prior.** `BluetoothTracker.update` re-runs `calibrate: true` on that second's snapshot (BluetoothTracker.swift:117, store.ts:343), and n has a prior σ of 1.5. One 4 m link from a cased phone (true p0 −65, n 2.0) gives p0 −59.8, n 2.78, so a 10 m link reads 8.1 m. The radio jumps every second as links come and go, and the map breathes. *Fix:* require at least 3 links spanning a 2:1 distance ratio before fitting n. Otherwise fit p0 only (n σ ≈ 0.4), and smooth the fit over time. *Confidence: high.*

4. **No robustness to body/pocket loss in SignalMap.** The stress update (SignalMap.swift:312–350) is plain least squares, while `RangeSolver` has a Huber loss. Extra losses of 10/15/20 dB read a 3 m link as 7.5/11.9/18.9 m, against a modelled 1σ of 1.38 m. Proportional σ downweights the inflated link about 16×, which saves rigid groups. A GPS phone with a long r95 is still dragged, and the rendered point is "moved to fit". *Fix:* apply the Huber weight on the dB residual `rssi − expectedRSSI(layoutDist)` inside the sweep. *Confidence: medium.*

5. **Stale advertisement RSSI is reported as fresh.** `neighborObservations` (BluetoothMesh.swift:579) takes `smoothed` with no `lastSampleAt` check, and `ageMs` is the link's `lastHeard` (any frame), not the RSSI sample age. On an incoming-only link where the peer's adverts stop being heard, the frozen RSSI passes `linkMaxAge` indefinitely. Fusion checks this correctly (MeshModel.swift:483), but the signal map does not. *Fix:* nil the RSSI when the sample is older than 5 s, or report `ageMs = max(link age, sample age)`. *Confidence: medium (depends on iOS advert delivery while connected).*

6. **One link mixes two RSSI kinds.** Connection RSSI (data channels, 1 Hz) at one end and advertisement RSSI (channels 37–39) at the other are averaged as if they were the same quantity (BluetoothTracker.swift:108). Advertising-channel fading typically differs by 2–6 dB. *Fix:* prefer connection RSSI from whichever end is central, and add `kind` to the neighbor entry if needed. *Confidence: medium-low (magnitude unmeasured).*

7. **Outdated comments.** BluetoothMesh.swift:575 says "Link quality only, never a distance", and ContentView.swift:213 says "RSSI shows link quality…, not distance", but TrackView now shows "≈ distance". This is not a honesty violation, but the copy should match. *Confidence: high.*

8. **Minor.** The near-field clamps differ: 0.3 m (`SignalMap.minDistance`) vs 0.5 m (`expectedRSSI`, `PathLossModel.minDistance`). `PathLossCalibration` counts a→b and b→a as independent, which is overconfident by about √2. The `maxDistance` of 500 m corresponds to −126 dBm, below any phone's sensitivity (about −100), so 60–100 m is the realistic cap.

## Tests vs claims

The golden cases prove **TS↔Swift parity**, not accuracy. Every SignalMap and calibration test generates RSSI exactly from the model, with no noise, no offsets in SignalMap and no outliers. Nothing tests σ-coverage (does r95 contain the truth 95 % of the time under 5 dB noise?), body loss, a one-link calibration or a fused prior. The fusion claim of 1–2 m in app.md comes from simulated walks only, as app.md admits.

## Done well

- Range σ ∝ d and the 2.45 r95 factor are correct, and `.pinned` and `.relative` frames are flagged honestly.
- MotionAwareRSSI averages while still and gates outliers by the distance actually walked. That makes good use of the accelerometer.
- The fusion's 8 dB σ floor and shadowing-decorrelation feeding avoid overconfidence.
- RSSI is averaged in the dB domain, which matches the log-normal model.
- GPS's 68 % accuracy is converted to r95.
- The RSSI-only fix is never published.

## Phone verification

1. Tape-measure session (POSITIONING_REVIEW 1.2): two phones at 1/2/3/5/8/12/20 m, held in hand / pocketed / body between. Log connection and advertisement RSSI separately to measure the gap in finding 6 and the real σ.
2. Put two GPS phones 2 m apart outdoors and watch `tracker.radio` over 60 s. It should stay put.
3. Connect phone A as the peripheral only, then stop B's advertising (background it). Check that A's neighbor RSSI and `ageMs` go stale (finding 5).
4. Pocket one phone in a 4-phone group and see whether the map distorts or only that ring grows.
5. Compare the Track-tab distance with the fusion panel's distance for the same anchor (finding 1).
