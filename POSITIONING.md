# GhostCore positioning engine

Owner: positioning (see ARCHITECTURE.md for ownership). This document describes what the engine
does, what it refuses to claim, how it was tested, and how to test it on phones. Every accuracy
number below is from **synthetic** tracks unless it says otherwise. Nothing here has run on a phone yet.

Code:

| Where | What |
|---|---|
| `ios/MeshCore/Sources/MeshCore/Positioning/PositioningMath.swift` | Frame/heading/time conventions, `Vec2`, `Covariance2`, small matrix |
| `.../RSSIFilter.swift` | `RSSIMedianFilter` (Hampel + median windows), `PathLossModel` |
| `.../RSSICalibration.swift` | `CalibrationSession` (RSSI at marked distances) and the fit |
| `.../RangeGeometry.swift` | `Anchor`, `RangeGeometry.solve` (proximity / ambiguous / multilateration) |
| `.../MotionProcessing.swift` | Yaw rate about gravity, tilt-compensated compass, step and stillness detectors |
| `.../PositionEngine.swift` | `Positioning.Engine`: the Kalman filter and the rules below |
| `.../ContractMapping.swift` | Engine values ⇄ `PositionEstimate`, `MotionObservation`, anchors, `PeerObservation` |
| `.../PositioningReplay.swift` | JSON-lines log format, replay and accuracy summary |
| `ios/MeshMapper/MotionSource.swift` | Core Motion at 50 Hz + compass at 10 Hz |
| `ios/MeshMapper/PositioningService.swift` | One engine per phone; feeds it, publishes `PositionEstimate`, records walks |
| `ios/MeshMapper/PositioningCalibrationView.swift` | The T2 calibration screen |
| `ios/MeshCore/Tests/MeshCoreTests/Positioning/` | 54 tests incl. the synthetic accuracy suite |

## Conventions

- **Frame**: the floor plane of the `GeoFrame` (`hervanta-v1`): x east, z north, metres; height is not
  estimated (`positionMode: floor`, y = 0).
- **Heading**: radians clockwise from north (+z) toward east (+x); a step along heading h moves
  (sin h, cos h). The engine tracks the *device* heading and a *carry offset* (walking direction
  minus device heading).
- **Time**: the engine runs on this phone's monotonic clock (`systemUptime`, Core Motion's base).
  Core Location dates are converted once on entry. Other phones' clocks are never subtracted:
  a relayed record is timed as *receipt time minus its `freshness.ageAtHandoff`*, plus 0.5 s of
  relay-timing uncertainty. Contract records leave with Unix time from this phone's clock.

## What it will not claim

- **One Bluetooth range is a disc, not a point.** With one anchor the answer is `proximity`:
  "within r95 of that phone", `uncertainty.ambiguous = true`, centred on the anchor because that
  is the centre of the region, not because we are there. A neighbour's GNSS coordinate never
  becomes our coordinate.
- **Two ranges are two places.** `ambiguous` with both candidates, until motion or a third anchor
  separates them.
- **Three or more need geometry.** Multilateration only with HDOP ≤ 3 and no mirror solution of
  similar cost (collinear anchors are reported as ambiguous).
- **RSSI is an interval.** With the default model (5.6 dB total spread) the 95 % range interval is
  about ×/÷ 2.7 around the median distance. Near the receiver's floor only the upward fades are
  heard, so such readings only say "at least this far".
- **Untrusted GNSS is never used.** Own fixes need this phone's `IntegrityAssessment` to be
  `trusted`; another phone's fix anchors us only if its assessment says `mayAnchorOthers`.
  A phone that stops qualifying is withdrawn at once and its provenance entry says why.
- **No loops.** A relayed estimate whose `provenance.contributors` contains this phone is refused.
- **No silent staleness.** Anchor uncertainty grows at walking pace with age; anchors older than
  30 s, RSSI windows older than 8 s and measurements more than 2 s behind the filter clock are
  dropped. Without motion data the circle grows by the distance that could have been walked in any
  direction (not a random walk, which a straight walk away would escape).

## Pipeline

```
Core Motion 50 Hz ──► yaw rate about gravity ─┐
                    ► step detector (Weinberg)├─► EKF ◄── trusted own GNSS (position + course)
                    ► stillness → gyro bias  ─┘    ▲
compass 10 Hz (tilt-compensated, disturbance)─────►│
PeerObservation raw RSSI ─► median windows ─► tight prior: range update (iterated EKF, shadowing state)
relayed PositionEstimate + IntegrityAssessment ─► anchors ─► broad prior: RangeGeometry region, only if tighter
                                                       │
                              Estimate ─► ContractMapping ─► PositionEstimate (+ MotionObservation)
```

### RSSI

`RSSIMedianFilter` keeps a 4 s window per peer and channel, drops impossible values (iOS's 127),
removes Hampel outliers (> 3 robust sigmas) and reports the median; each sample is used in one
window only. Channels are kept apart because they read differently: `connection` (readRSSI, central
side, ~1 Hz), `advertisement`, `reciprocal` (the peer's raw readings of us from its
`PeerObservation`) and `relayedSmoothed` (an old-style EMA value, one sample per report).

`PathLossModel`: RSSI = p0 − 10 n log10(d), with `sigmaFast` (spread of window medians at one spot)
and `sigmaShadow` (spot-to-spot spread: shadowing, body, orientation, phone model). The default
(p0 −59 dBm, n 2.5, 2.5 + 5 dB) is a placeholder until T2.

`CalibrationSession` records RSSI from one peer at marked distances, splits each step into 4 s
windows (the engine's window), and fits p0 and n with Huber-weighted least squares. It refuses fewer
than 3 distances or a span under 4×, floors shadowing at 3 dB (one walk sees one spot per distance),
reports R², leave-one-distance-out RMS and range error, and warns about odd values.

### Filter

State: x, z, device heading, gyro bias, carry offset, stride scale, compass bias, GNSS error x/z,
pace change, and one shadowing bias per anchor in use.

| Input | Model | Robustness |
|---|---|---|
| Gyro (50 Hz) | heading += (rate − bias)·dt, rate = −ω·up | Gaps > 0.25 s add heading walk; bias learned from compass/course and when still |
| Stillness (1 s) | true rate = 0 → measures the bias | If the bias is far off, its variance is widened and it is re-learned |
| Compass | heading + compass bias + noise | Disturbance flag (field strength/dip) rejects; the bias state decorrelates over 15 m, so a steel railing bends the bias state, not the heading; 3σ gate |
| Steps | position += (scale + pace)·L·(sin, cos)(heading + carry) | Unknown heading (> 45°): circle grows by the distance; along/cross noise 10 %/6 % |
| Trusted GNSS | position + correlated error + white noise | Correlated part (70 %, τ 30 s) stops averaging from over-trusting fixes; 99.9 % gate; reset after 10 consistent rejections |
| GNSS course | heading + carry | Only above 1 m/s and with course accuracy < 30° |
| RSSI window, tight prior | p0 − 10 n log10(d) + shadowing + noise | Shadowing state per link decorrelates with movement (3 m) and time (5 min), so a static link cannot shrink the circle forever; censored near the floor; 3σ gate (blocked links) |
| RSSI windows, broad prior | `RangeGeometry` region as a position measurement | Applied only when tighter than the prior; restart from Bluetooth after 3 disagreements |

Late measurements are moved to "now" by the dead-reckoned displacement since their timestamp
(GNSS fixes and RSSI windows both lag by 1–3 s). Each update records its normalized innovation; if
range residuals run above what the filter predicts, process noise is widened and the estimate is
flagged `widenedByResiduals`. Replays are bit-for-bit repeatable.

### Output

| Engine method | `PositionEstimate` kind / method / source | Notes |
|---|---|---|
| gnss | measured / gnss / gnss | Trusted fix applied in the last 3 s; `gnssDependent` |
| deadReckoning | estimated / deadReckoning / inertial | Steps and heading since the last absolute evidence; `lastAbsoluteAt` says when |
| fused | estimated / fusion / fusion | Dead reckoning corrected by ranges to anchors |
| multilateration | estimated / multilateration / bluetooth | 3+ anchors, good geometry |
| proximity | estimated / proximity / bluetooth, ambiguous | Disc around one anchor; no candidates |
| ambiguous | estimated / multilateration / bluetooth, ambiguous | Candidates listed |
| declared | declared / manual / manual | Pinned or surveyed start |
| unavailable | unavailable / none, position nil | Also when r95 would exceed 500 m |

Provenance lists up to 16 inputs (GNSS, compass, each anchor) with age, used/rejected and the reason,
inherits contributors and `gnssDependent` from the anchors' own provenance, and uses
`ghostcore-positioning@0.1`. `MotionObservation` gives steps, displacement, heading and its sigma,
and stillness over the requested interval.

## Results (synthetic)

`cd ios/MeshCore && swift test --filter PositioningAccuracyTests` (6 seeds per scenario, scored over
the GNSS outage only, one estimate per second). The simulated world deliberately differs from the
engine's model: true p0 −58 / n 2.3 with ±2 dB per phone, 4.5 dB shadowing correlated over 5 m,
8 % deep fades, body blocking, a hearing-range cutoff, correlated GNSS error, 8° carry offset,
0.2°/s gyro bias, and an unflagged 35° magnetic disturbance on the route.

| Scenario | Variant | Median error | p95 error | Median r95 | Truth inside r95 |
|---|---|---|---|---|---|
| **S1/T5**: one trusted phone 10–20 m away, 3 min outage | hold last fix | 18.7 m | 28.5 m | 136 m | 100 % |
| | dead reckoning only | 3.5 m | 4.8 m | 9.7 m | 100 % |
| | **fusion** | **2.4 m** | **4.1 m** | **7.8 m** | **100 %**, placed after 1 s |
| S1 with harsh sensors (unseen ±15 % pace, 1°/s gyro bias, unflagged 40–60° compass disturbances, 5 m correlated GNSS, ±4 dB phones, 6 dB shadowing) | dead reckoning only | 6.3 m | 13.7 m | 10.4 m | 79 % |
| | **fusion** | **4.2 m** | **9.0 m** | **8.0 m** | **89 %** |
| Four anchors, 10 min outage | hold last fix | 58.0 m | 80.8 m | 430 m | 100 % |
| | dead reckoning only | 6.1 m | 10.7 m | 28.7 m | 100 % |
| | **fusion** | **5.2 m** | **10.2 m** | **14.0 m** | **100 %** |
| No anchors, 10 min outage | dead reckoning only | 5.1 m | 10.0 m | 28.8 m | 100 % |
| Cold start, no GNSS ever, four anchors | fusion | 8.6 m | 17.2 m | 18.8 m | 97 % (point estimate 90 % of the time; the rest proximity) |

How to read this:

- AC-4 asks for placement within 5 s and truth inside r95 in ≥ 90 % of samples. The synthetic S1
  meets it (100 %). With sensors deliberately worse than the model it drops to 89 %: r95 widens
  but not enough. An ablation showed unseen pace changes and under-reported GNSS error are the
  main causes; gyro bias, compass disturbance and radio offsets alone keep ≥ 97 %.
- With a single anchor the error *along* a loop around it is invisible to Bluetooth (a range only
  constrains the radial direction), so honesty there comes from conservative step-length noise,
  not from the radio.
- Synthetic phones walk with perfect step rhythm and a phone held flat. Real hands, pockets and
  swings will be worse. **Do not quote these numbers as field accuracy.**

## Field tests

### T2: RSSI calibration (2, 5, 10, 20 m)

1. Two phones at the same height, held the way they will be carried, nobody in between; outdoors
   where the demo runs.
2. On one phone open the calibration screen, pick the peer and `connection` RSSI, record ≥ 60 s at
   each distance (tape measure), then *Fit and use on this phone*.
3. Note p0, n, both spreads and the held-out range error. Repeat with the phones' roles swapped.
   The fit is valid for that pair of phone models and that kind of place.

### T5: GNSS outage walk

1. P1 lies still with trusted GNSS 10–20 m from the loop. P2 starts with GNSS trusted.
2. On P2: start recording (`PositioningService.startRecording()`), then *Simulate losing GPS*
   (`gnssHidden`). The engine stops receiving fixes; good fixes are still written to the recording
   as reference records.
3. Walk the marked 3-minute loop at a normal pace with the phone in hand. Stop recording.
4. On a Mac: `POSITIONING_LOG=<file>.jsonl swift test --filter PositioningAccuracyTests/testReplayRecordedWalk`
   prints the median/p95 error, r95 and containment over the outage.

Caveat: the reference in a T5 recording is GPS, which has its own few-metre correlated error.
Replaying a synthetic S1 walk scored against its own GPS reference gave 84 % and a 3.9 m median,
where scoring against the true track gave 100 % and 2.4 m. For AC-4, also note the time at each
marked corner, or put declared checkpoints on the loop.

## Integration (hub / pipeline)

```swift
let positioning = PositioningService(selfId: myId)          // one per app run
positioning.start()                                        // Core Motion
positioning.ingest(location: fix, trusted: myAssessment.status == .trusted)
positioning.ingest(observation: peerObservation)           // own and peers' snapshots
positioning.ingest(relayed: estimate, integrity: thatPhonesAssessment)
positioning.withdraw(anchor: "phone-c", reason: "GNSS rejected: positionJump")
let record = positioning.tick()                            // once a second → PositionEstimate
let motion = positioning.motionObservation(window: 1)      // → trust engine
positioning.gnssHidden = true                              // "Simulate losing GPS"
```

Pure MeshCore users (pipeline, scenarios) call `Positioning.Engine` and `Positioning.ContractMapping`
directly with the same inputs; all times are monotonic seconds.

## Known limitations

- Phone held in front, roughly level or upright. Pocket and swinging-hand carry change the carry
  offset and the step signal; not supported or tested.
- The default radio model is not calibrated; until T2 the RSSI spreads are guesses (deliberately wide).
- One phone places itself. Peers without a position are still placed by the pipeline's
  `BluetoothEstimator`, which has the reach-edge compression the prediction agent measured in S5.
- No height, no floors, no map matching.
- The step detector is tuned for walking; running and vehicles are not modelled.
- Synthetic results only. The first field number will come from T5.
