# Ghost Mode: where a phone probably is when nobody can hear it

When a phone drops out of Bluetooth range of every other phone (or loses GPS with no peers),
nothing new is known about it. Ghost Mode keeps two things on the map and never mixes them up:

- **Last observed**: the last trusted position, exactly as measured, with its time and source.
- **Predicted**: where the person has probably walked since, as an area that grows with time.

It is never shown as live tracking. When the phone is heard again the prediction is checked
against the new observation and dropped at once.

Everything runs on the phone, offline. Code: `ios/MeshCore/Sources/MeshCore/Ghost/` (pure Swift,
no UIKit/CoreLocation, so `swift test` covers it on the Mac).

## What it does

| Status | When | Shown |
|---|---|---|
| `live` | observed in the last 5 s | the observation |
| `ghost` | 5 s to 10 min since the last observation | last observed + predicted area (`basis` = `extrapolated`, or `deadReckoned` when this phone's own steps and compass carry it) |
| `lost` | longer than 10 min | last observed only ("Lost: last seen 14 min ago") |

**Prediction**: a Kalman filter over position and velocity. Velocity is mean-reverting
(Ornstein-Uhlenbeck, about 90 s): people keep going for a while, then turn or stop, so a long gap
grows like a random walk rather than like a straight line. A plain constant-velocity filter
overshoots and its area grows as h^1.5. The plain **constant-velocity baseline** is in the
same file (`GhostConstantVelocity`).

**Uncertainty**: the 95% circle (`r95`, the contract's field) is calibrated per horizon on
training walks so it holds the person about 95% of the time; between 5 s and 180 s the multiplier
is interpolated, and beyond 180 s the model's own growth carries on. A prediction is never
sharper than the observation it started from.

**Inertial**: on this phone only, `MotionObservation` (steps + heading displacement, or "at
rest") feeds the filter. Step-length and compass errors persist, so dead reckoning adds a drift
of 15% of the distance walked (per axis) instead of averaging the errors away. "At rest" pins the
velocity to zero, so a person standing still keeps a small area.

**Recovery**: when a ghost is observed again, the observation is scored against the prediction
(`GhostRecovery`: gap, miss distance, inside the 95% circle, level). If it is plausible it is
blended in; if it is far outside (99.9%) or the gap was longer than 10 min, the track restarts at
the observation, so a wrong prediction cannot drag a real fix. Recoveries feed an **online
calibration**: if the 90% area holds clearly less than 90% of recent recoveries, future areas are
widened (bounded at 4x variance), and narrowed back slowly when they hold more than 97%.

**Timestamps**: everything is on this phone's clock. A relayed estimate counts from
`receivedAt - freshness.ageAtHandoff`; two phones' clocks are never subtracted. Late or duplicate
relays (not newer than the last observation) are ignored; a peer clock running ahead never gives
negative ages.

**Honesty rules in code**: estimates of kind `.predicted` are never taken in (a prediction cannot
confirm itself), nor `.deadReckoning` estimates (Ghost dead-reckons from `MotionObservation`;
both would count the same steps twice). Predictions carry `simulated` / `gnssDependent` from
their inputs' provenance.

## API (for `GhostCorePipeline`)

```swift
let ghost = GhostPredictor(producerId: myId, frameId: GeoFrame.defaultFrameId)
ghost.observe(estimate, receivedAt: now)        // PositionEstimate -> GhostRecovery? when a ghost is heard again
ghost.observe(motion)                           // MotionObservation, this phone only
ghost.predict(subjectId: id, at: now)           // Prediction? (nil when live, lost or unknown)
ghost.estimate(subjectId: id, at: now)          // GhostEstimate: status, basis, lastObserved, age, r50/r90/r95, confidence, summary
ghost.tracker.recoveries / .calibration         // recovery checks, online coverage, inflation
```

`Prediction`: method `.kalman`, algorithm `kalman-ou@1`, `timestamp` = the predicted time,
`lastObservedAt` / `lastObservedPosition` = the last observation, `uncertainty.r95` + covariance,
a 64-point cloud (stable within one gap, so it grows instead of flickering), `freshness.maxAge`
10 s, provenance derived from the last four estimates used. `GhostEstimate.summary` reads e.g.
"Predicted: last seen 1 min 12 s ago (Bluetooth), 95% within 64 m".

`GhostReplay` runs scripted scenarios (observations, motion, true paths, checks) through the
tracker; the fixtures double as a demo script with no phones moving.

## Results (held-out simulation, not field accuracy)

**Data**: real walking tracks (OpenStreetMap public GPS traces, filtered to walking) from
`ml/data/windows` on branch `movement-model`. Everything is fitted on 4,000 windows from eight
areas (Nuuksio, Sipoonkorpi, Repovesi, Seitseminen, Helvetinjärvi, Kauppi, Pyynikki,
Keskuspuisto) and scored on **all 6,905 Hervanta windows, never used for fitting**. Each window
is 60 s of history then the truth 1-180 s later.

Two kinds of history, identical for every method:
- **mesh**: the walk plus correlated error like a Bluetooth estimate (15 m per axis, AR(1)
  rho 0.9 per 2 s, as in `ml/train.py`). This is Ghost Mode's main case.
- **gps**: the recorded GPS track itself. The truth is the same GPS track, so the absolute GPS
  error is not in these numbers.

Each cell is **r95 coverage** (want 0.95; the AC-8 band is 0.90-0.98) · median miss of the centre ·
**exact-90% area** (the area each method needs to catch exactly 90% of the walks, `ml/`'s metric;
smaller is sharper).

Mesh history:

| method | 10 s | 30 s | 60 s | 120 s |
|---|---|---|---|---|
| stand still | 0.95 · 20 m · 0.42 ha | 0.93 · 29 m · 1.05 ha | 0.92 · 47 m · 2.82 ha | 0.94 · 86 m · 8.33 ha |
| constant velocity (baseline) | 0.94 · 24 m · 0.61 ha | 0.91 · 40 m · 1.77 ha | 0.92 · 69 m · 5.20 ha | 0.93 · 127 m · 17.84 ha |
| Kalman, constant velocity | 0.88 · 21 m · 0.48 ha | 0.89 · 30 m · 1.11 ha | 0.93 · 47 m · 2.67 ha | 0.97 · 79 m · 8.02 ha |
| Kalman, mean-reverting | 0.88 · 21 m · 0.49 ha | 0.88 · 31 m · 1.10 ha | 0.91 · 45 m · 2.53 ha | 0.94 · 73 m · 6.85 ha |
| **Kalman, mean-reverting, calibrated (shipped)** | **0.94** · 21 m · 0.49 ha | **0.94** · 31 m · 1.10 ha | **0.94** · 45 m · 2.53 ha | **0.94** · 73 m · 6.85 ha |
| movement model v1 | 0.95 · 19 m · 0.41 ha | 0.93 · 28 m · 0.96 ha | 0.92 · 43 m · 2.35 ha | 0.93 · 72 m · 6.53 ha |
| movement model v2, no map | 0.95 · 19 m · 0.41 ha | 0.94 · 28 m · 0.95 ha | 0.93 · 43 m · 2.38 ha | 0.93 · 71 m · 6.58 ha |
| movement model v2 + map | 0.93 · 17 m · 0.31 ha | 0.90 · 24 m · 0.72 ha | 0.88 · 37 m · 1.81 ha | 0.88 · 64 m · 5.48 ha |
| shipped + steps/compass (**simulated sensors**) | 0.98 · 16 m · 0.26 ha | 0.95 · 17 m · 0.33 ha | 0.92 · 20 m · 0.46 ha | 0.89 · 26 m · 0.85 ha |

GPS history:

| method | 10 s | 30 s | 60 s | 120 s |
|---|---|---|---|---|
| stand still | 0.86 · 8 m · 0.11 ha | 0.87 · 24 m · 0.82 ha | 0.90 · 46 m · 2.67 ha | 0.95 · 86 m · 8.08 ha |
| constant velocity (baseline) | 0.86 · 4 m · 0.05 ha | 0.85 · 14 m · 0.46 ha | 0.84 · 31 m · 2.00 ha | 0.83 · 66 m · 8.02 ha |
| Kalman, constant velocity | 0.83 · 4 m · 0.05 ha | 0.72 · 13 m · 0.48 ha | 0.77 · 31 m · 2.12 ha | 0.86 · 69 m · 8.82 ha |
| Kalman, mean-reverting | 0.87 · 3 m · 0.04 ha | 0.82 · 12 m · 0.36 ha | 0.87 · 27 m · 1.48 ha | 0.92 · 58 m · 5.20 ha |
| **Kalman, mean-reverting, calibrated (shipped)** | **0.96** · 3 m · 0.04 ha | **0.95** · 12 m · 0.36 ha | **0.92** · 27 m · 1.48 ha | **0.91** · 58 m · 5.20 ha |
| movement model v1 | 0.95 · 3 m · 0.02 ha | 0.92 · 12 m · 0.25 ha | 0.91 · 26 m · 1.13 ha | 0.92 · 54 m · 4.47 ha |
| movement model v2, no map | 0.95 · 3 m · 0.02 ha | 0.91 · 12 m · 0.27 ha | 0.90 · 26 m · 1.21 ha | 0.91 · 53 m · 4.52 ha |
| movement model v2 + map | 0.92 · 3 m · 0.02 ha | 0.85 · 12 m · 0.25 ha | 0.81 · 26 m · 1.09 ha | 0.81 · 52 m · 4.38 ha |
| shipped + steps/compass (**simulated sensors**) | 0.98 · 2 m · 0.01 ha | 0.93 · 5 m · 0.05 ha | 0.91 · 10 m · 0.15 ha | 0.92 · 19 m · 0.47 ha |

All horizons (5-180 s), the 50/90/95% ellipse coverage, the calibration error over ten levels and
NLL are in [`results/heldout-metrics.json`](results/heldout-metrics.json) and
[`results/heldout-table.md`](results/heldout-table.md); fitted parameters in
[`results/params.json`](results/params.json).

**Choosing among the baselines** was done on training NLL only: the mean-reverting Kalman filter
was best for both kinds of history (gps 8.32, mesh 9.89 vs constant velocity 8.39 / 10.52).

**How the calibration was arrived at, in order (so the held-out numbers can be judged):**
1. NLL-fitted filter, no calibration: held-out r95 coverage 0.82-0.94.
2. Two-scale heavy-tail mixture fitted by NLL: lower training NLL, worse r95 coverage. Dropped.
3. Calibrated per horizon so the 95% circle held 95% of all training walks pooled: held-out
   0.89-0.92 with GPS history, just under the band. Hervanta's walks turn more than the training
   parks'.
4. **Shipped**: calibrated per horizon to the **hardest single training area** (a fixed rule
   for an unseen area: be right where it was hardest). Held-out 0.91-0.97 at 10-120 s. This rule
   was chosen after looking at step 3's held-out numbers once, so it has seen Hervanta once,
   indirectly.

## The learned model: kept, but not with the map

The rule was written before the first held-out run (`verdict` in `heldout/main.swift`): the
learned model replaces the Kalman area only if, at 10, 30, 60 and 120 s, it wins at 3 of 4
horizons on each of median miss, exact-90% area and calibration (|r95 coverage - 0.95| no worse
than the Kalman filter's + 0.02).

| learned model | mesh history | GPS history |
|---|---|---|
| v1 (history only) | **retain** | **retain** |
| v2 without the map | **retain** | **retain** |
| v2 with the map (what build 7 shows) | reject: r95 holds 0.88-0.93 | reject: r95 holds 0.81-0.92 |

The learned model is the existing on-device MLP (`ml/runtime/MovementModel.swift`, plain Swift,
about 1 ms per prediction), not Core ML; converting it would not change these numbers, so it was
not converted. Without the map it misses by 3-9% less than the calibrated Kalman filter and needs
4-25% less area at the same hit rate (half the area at 10 s with GPS history). The map makes v2 sharper still but overconfident in a forest it has not seen.

**What ships (integration lead's decision, from these numbers):** the learned model v2 without the
map draws the area when a phone has at least 60 s of history; the Kalman predictor does when it
has less or the model file is missing; Ghost Mode's tracker owns status, last observed and
recovery either way.

## Replay scenarios (synthetic)

`fixtures/*.json`, written by `fixtures/make_fixtures.py`; every check passes
([`results/replay-table.md`](results/replay-table.md)):

| scenario | what it shows |
|---|---|
| walk-out-of-range | the demo beat: B leaves Bluetooth range, last seen stays put, area grows, B is heard again, prediction dropped at once |
| turn-while-hidden, stop-while-hidden | the area still holds the person when they turn or stop unseen; recovery blends in |
| out-stop-back | contract scenario S5's path (east, stop, walk back unseen) with honest Bluetooth positions: held 100% of 138 s |
| teleport-reacquire | reappears 500 m away: no blending, track restarts, recovery marked outside r95 |
| stale-relay | late relayed copies are ignored |
| long-loss | after 10 min: `lost`, no prediction; recovery restarts |
| dead-reckoning-self, standing-still | own phone without GPS: steps/compass and "at rest" keep the area small and honest |
| three-phone-demo | A on GPS, C in range, B out of range 50-120 s and back |
| clock-skew | a peer clock 1.5 s ahead: no negative ages |

## In the pipeline (contract scenarios, synthetic)

`GhostPredictor` conforms to `GhostPredictionEngine`; `GhostPipelineTests` runs every
`contract/scenarios/*.json` with it plugged into `GhostCorePipeline`. All gating expectations
hold. On S5 (B leaves Bluetooth range):

| expectation | Ghost Mode | walking-circle baseline |
|---|---|---|
| S5-a prediction shown once B is out of range | pass, 3 s | pass, 3 s |
| S5-b dropped within 10 s of B being back | pass, 0 s | pass, 0 s |
| S5-c truth inside r95 >= 90% of seconds (not gating) | 62% (median r95 121 m) | 76% (median r95 159 m) |

S5-c is limited by its input, not the motion model: at the moment B is lost, the Bluetooth
estimator places B at x = 35 m while B is at x = 95 m (60 m off, beyond its stated r95 of 51 m),
and the track before it is compressed the same way, so the prediction starts in the wrong place
with a third of B's speed. With honest Bluetooth positions on the same path (`out-stop-back`) the
area holds B 100% of the time. The fix belongs in positioning (range compression near the edge of
radio reach, or a wider r95 there).

## Limits (say these in the pitch)

- **Held-out walks are not field accuracy.** They are public GPS walking tracks, not people who
  were lost, and the "mesh" error is simulated. Field numbers come from T5-T9 (ARCHITECTURE.md).
- **Dead reckoning numbers are from simulated sensors** (step length 10% off, compass 8° off per
  walk, 15° and 10% noise per reading). Phone pedestrian dead reckoning in a pocket can be worse;
  the 15% drift is an assumption, not a measurement.
- The calibration is for walking. Cyclists, cars and runners were filtered out of the data.
- Beyond 3 minutes there is no held-out truth (the windows end at 180 s); the area keeps growing
  by the model, and stops at 10 minutes.
- With GPS history the truth was the GPS track, so real r95 is a few metres short at the
  shortest gaps; the "never sharper than the last fix" floor covers most of that.

## Reproduce

Offline. Needs the `movement-model` worktree's `ml/` (with `data/windows/*.npz` from its
`prepare.py`) and a Python with numpy.

```sh
cd ios/MeshCore && swift test --filter Ghost                       # 30 tests: math, filter, tracker, contract adapter, replays, pipeline scenarios
sh ghost/replay/run.sh                                             # replays -> ghost/results/replay-table.md
ML_DIR=../movement-model/ml PY=~/Projects/.venvs/movement/bin/python sh ghost/heldout/run.sh
                                                                   # fit + held-out scoring (~3 min) -> ghost/results/
python3 -I ghost/fixtures/make_fixtures.py                         # regenerate the scenarios
```

`heldout/run.sh` exports the windows once to `heldout/data/` (git-ignored), fits on the training
areas, scores everything on Hervanta with the same Swift code the app runs (plus the movement
model's Swift runtime), prints the fitted defaults as Swift, and writes `results/`.
