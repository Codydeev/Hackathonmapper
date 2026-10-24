# Distance and position estimation: overview, conflicts and plan

Review of every way MeshMapper estimates a distance or a position, on the phone (`ios/`) and on the dashboard (`website/`). It was written on 2026-10-24 and checked against `main` at 113dbc1 (after PRs #6 and #7). This is a code-reading review: nothing was run on a phone. Line numbers will drift.

## Status (2026-10-24, branch `feature/positioning-plan`)

| Phase | Status |
|---|---|
| 0. Build blockers | Done: the duplicate `Vector3` is removed (PDR uses the one in `Ranging.swift`), and the missing `invalidRanging` error text is added. **Not compiled yet: run `swift test` and build on a Mac.** |
| 1. One radio model | Done: `RadioModel.standard` / `RADIO_MODEL` (−59 dBm, n 2.5, σ 5) everywhere, including fusion (`PathLossModel.default`). The simulated radio is named and used only in simulated mode. Live calibration from phones pinned within 3 m. The tape-measure session (1.2) needs real phones; the procedure is in app.md. |
| 2. Keep measured ranges | Done: the Track list gives measured ranges first; ambiguous phones get a ring, never a dot at its centre; links on both maps are labelled with their measured distance. |
| 3. One cooperative estimator | Done as the **signal map** (`SignalMap.swift` / `shared/signalmap.ts`). It replaces both particle filters. Every phone is a node, reported positions are priors, and links between fused phones and anchor phones are skipped. |
| 4. One implementation, one accuracy | Done: Swift and TypeScript ports are checked by shared golden cases (`signalmap-golden.json`); one link age (6 s); `accuracyMeters` is a 95 % radius everywhere. |
| 5. One frame | Done: x east and z north in GPS frames, with an optional bearing for `+z`; x right and z forward in room frames. The UI names the axes and the alignment direction from the frame. |

Verified here: website typecheck, `npm run signalmap:check` (8 cases), and a server smoke test in simulated and live mode. In simulated mode, calibration recovered the simulator's radio (p0 −45.1, n 2.00 vs −45, 2). In the live scenario from this review, distances on the map went from 13.4 / 0.02 / 13.4 m to 2.14 / 3.02 / 3.63 m, against 2 / 3 / 3.6 m measured.

**The observation that prompted it:** the *Bluetooth distance (no GPS needed)* list on the Track tab is right to about a meter, while distances read off the map are far worse. That is expected from how the code works today, and it is fixable.

## Why one is good and the other is bad

| | Track tab, "Bluetooth distance" | Map (phone `PhoneMapView`, Track radar, dashboard) |
|---|---|---|
| What it is | One link's smoothed RSSI turned into meters (`TrackView.directDistance`) | Two **absolute** positions in the frame, and the distance between them |
| Error sources | RSSI noise only | GPS error of the anchor phone (up to **30 m** accepted, `LocationSource.maxAccuracyMeters`), plus that error passed through every hop, plus the particle filter's spread, plus ring ambiguity, plus the movement-model cloud |
| Needs a frame | No | Yes |

Two concrete mechanisms make the map worse than the radio:

1. **A relative measurement is turned into an absolute one, then back into a relative one.** Two phones 1 m apart, one placed by GPS at ±15 m, end up drawn with the other's ±15 m error on top of the 1 m range. Any distance read off the map inherits the frame error, even though the radio measured the range directly.
2. **One anchor gives a ring, and the ring's centre is the anchor.** With a single placed neighbour, `BluetoothEstimator` spreads particles on a ring around it. The estimate is the weighted mean, which sits on the anchor itself. The ring is flagged `ambiguous` only when `r95 > 15 m` (`BluetoothEstimator.summarize`), so a phone 3 m from the anchor is drawn **on top of it**, and `TrackView.relation` reports roughly 0 m.

The "about a meter" also holds only at short range. With σ ≈ 5 dB and n = 2.5, one σ of RSSI scales distance by about 1.6×. At 2 m that's 1.3 to 3.2 m; at 20 m it's 13 to 32 m.

## Inventory: eight estimators

| # | Method | Where | Model and constants | Output | Typical error |
|---|---|---|---|---|---|
| A | Direct RSSI range | `TrackView.directDistance` | `RadioModel.outdoors` (−59 dBm at 1 m, n 2.5, σ 5) | Distance to a linked phone | ~1 m at 1–3 m, grows with range |
| B | Particle filter, phone | `MeshCore/BluetoothEstimator.swift` via `BluetoothTracker` | `RadioModel.outdoors`; anchor σ = max(2, accuracy ?? 5); link max age **6 s** | Position of `positionSource: none` phones | r95, often 5–30 m |
| C | Particle filter, dashboard | `website/server/estimator.ts` via `store.ts` | `RADIO` (= outdoors) live, `SIMULATED_RADIO` (−45, n 2, σ 3) simulated; link max age **4 s** | Same as B, separately computed | Same, but can differ from B |
| D | Motion + BLE anchor EKF | `MeshCore/FusionEngine.swift` | `PathLossModel.default` (−59, **n 2.2, σ 6**), self-calibrated from anchor links | Own position, `source: fused` | ~1–2 m in simulation, unverified on devices |
| E | UWB fix | `MeshCore/Ranging.swift` (`AnchorGeometry`) | 0.3 m + distance · sin(15°) | Target position, `source: uwb` | ~0.5 m at 3 m |
| F | GPS | `LocationSource` + `GeoFrame.position` | Accepted up to 30 m horizontal accuracy | Own position, `source: gps` | 5–30 m, worse indoors |
| G | Manual / "pin here" | `MeshModel.pinHere` | Accuracy set to 5 m | Own position, `source: manual` | Whatever the tap was |
| H | Movement model | `MovementPredictor` (ML, `ml/`) | Trained on GPS walks, ±15 m history | Cloud after a phone is lost | Tens of meters, by design |

The simulated field map (`website/server/field.ts`) uses a ninth radio model (−45 − 20 log d), but only for drawing.

## Conflicts

| # | Conflict | Effect | Severity |
|---|---|---|---|
| 1 | **MeshCore does not compile.** `Vector3` is defined twice: `PedestrianDeadReckoning.swift` (`init(x:y:z:)`) and `Ranging.swift` (`init(_:_:_:)`). | Nothing on the iOS side builds or tests | Blocker |
| 2 | **Three radio models.** `RadioModel.outdoors` (A, B, C), `PathLossModel.default` plus calibration (D), and `SIMULATED_RADIO`/field (C sim). Same RSSI, different distances: −70 dBm is 2.8 m in A/B but 3.2 m in D. | The ranges, the map and the fused track disagree. D's calibration never reaches A/B/C. | High |
| 3 | **Anchor or lost is binary.** A phone either is an anchor (any source, including GPS at ±30 m) or is placed from them. A precise BLE range to a UWB-placed phone can't correct a poor GPS phone, and a GPS anchor's error passes unchanged into every phone placed from it. | Map error is dominated by the worst anchor, not the best measurement | High |
| 4 | **Ring centre drawn as a position** (see above). | Phones collapse onto their only anchor; map distances near 0 | High |
| 5 | **Two copies of the particle filter** (Swift B, TypeScript C) with different link ages (6 s vs 4 s) and separate random state. | Phone and dashboard can show the same phone in different places | Medium |
| 6 | **Frame axes are defined twice.** app.md/CLAUDE.md say *x right, z forward*; `GeoFrame`, `BluetoothTracker` and the map say *x east, z north*. The Position tab shows both: the GPS footer says east/north, the manual footer says right/forward. Dead reckoning (D) and the UWB heading (E) are aligned to "+z", which in `hervanta-v1` means **north**, but the UI says "face +z". Manual coordinates typed for a room land relative to the campus origin. | Fused tracks rotated by the user's guess of north; manual spots in the wrong place | Medium |
| 7 | **Accuracy means different things.** GPS `horizontalAccuracy` (~68 %), estimator `r95` (95 %), EKF 1σ radial (~63 %), UWB heuristic, manual fixed 5 m. All are drawn as the same circle. | Circles are not comparable; B/C weigh anchors on mixed scales | Medium |
| 8 | **Fused phones become anchors.** D publishes `source: fused`, which B/C treat as an anchor with σ ≥ 2 m. This is fine, but D also uses those same anchors' RSSI, so errors can loop when two fused phones see each other. | Possible double counting | Low (only with several fused phones) |

## Plan

Each phase is shippable on its own. Phases 0–2 address what you see now; 3–5 make it robust.

### Phase 0: unblock (hours)

1. Delete the `Vector3` in `PedestrianDeadReckoning.swift` and use the one in `Ranging.swift` (same module, so `dot` and `length` are visible). Update `MotionTracker.swift` and `PositioningTests.swift` to `Vector3(x, y, z)`.
2. Finish the merge, then run `swift test` in `ios/MeshCore` and build the app on a Mac. None of the Swift from either branch has been compiled together yet.

### Phase 1: one radio model, calibrated once (½ day)

1. Keep a single `RadioModel` in MeshCore (p0, n, σ, range, soft) and fold `PathLossModel` into it. Mirror it in `website/shared/contract.ts` so the TypeScript estimator imports the same constants. Keep the simulated radio as a named second instance, used only in simulated mode.
2. **Measure it.** With two phones and a tape measure, log RSSI at 1, 2, 3, 5, 8, 12 and 20 m: indoors and outdoors, in hand and in a pocket. Fit p0, n and σ, and record them in `RadioModel` with the date and phone models. The ~1 m you see suggests the defaults are close at short range; the fit shows how far that holds.
3. Feed the live calibration from anchor-to-anchor links (`PathLossCalibration`) into A, B and C as well as D, falling back to the measured defaults.

### Phase 2: stop converting good ranges into bad positions (1 day)

1. **Show measured ranges as measured.** In the Track list and radar, a phone with a direct link shows the BLE range ("2.1 m, Bluetooth") with its interval. A map-derived distance is labelled with its accuracy ("~14 m, GPS ±15 m"). On the map, draw a direct link's range as a ring around the neighbour, not only a dot.
2. **Never draw a ring's centre.** Mark an estimate `ambiguous` whenever particle weight near the centre is small, independent of `r95` (drop the `r95 > 15` condition). Ambiguous phones show only the ring or cloud, as the radar already does for `ambiguous`. Apply this in both B and C.
3. **Relative distance from the estimator, not from two dots.** For two phones in the same particle filter, compute the distance distribution from their particles (sample pairs). This keeps the shared anchor error out, so it's as good as the radio allows.

### Phase 3: one cooperative estimator (2–3 days)

1. Replace "anchor or lost" with **every phone is a node with a prior**: UWB, fused, GPS and manual positions become priors with their own σ. A phone with no source gets a flat prior. Every BLE link then constrains both ends. A precise anchor (UWB, manual, a good fused track) can tighten a GPS phone's ±25 m, instead of the GPS error flowing into everyone.
2. Weight priors by a single confidence scale (Phase 4). GPS above ~10 m stops dominating BLE ranges to better-placed phones.
3. Prevent the loop in conflict 8: a fused phone's prior must not be updated again by the same anchors' RSSI. Either the estimator excludes D's anchors for that phone, or D publishes and B/C use the result only as a prior.

### Phase 4: one implementation, one meaning of accuracy (1 day)

1. Keep the Swift estimator as the reference and test the TypeScript port against shared golden vectors (the pattern from `ml/runtime/test-golden*` and `website/scripts/estimator-check.ts`). Use the same link max age on both sides; 6 s is the safer value because of relay latency.
2. Define `accuracyMeters` in the contract as one quantity, recommended as the **95 % radius**. Convert at the source: GPS × ~1.7 (approximate 68 → 95 %), EKF 1σ radial × ~1.7, UWB as computed, estimator r95 unchanged. Update `WEBSITE_PLAN.md`, `DashboardContract` and the circle legends.

### Phase 5: one frame definition (½ day)

1. Choose **x east, z north** for geo frames (`hervanta-v1`) and state it in app.md, CLAUDE.md and the UI. Allow a local frame (an indoor room) as a `GeoFrame` origin **plus a bearing**, so "+z" can mean "towards the whiteboard" while GPS still converts correctly.
2. Make heading alignment explicit: "face north" in a geo frame, or "face +z (bearing X°)" in a local one. Optionally offer a one-tap compass alignment where the magnetometer can be trusted (outdoors).

### Verification

- **Bench:** three phones on a tape-measured line or triangle (A = GPS or manual, B and C = no source). Log, per method, the error of B–C's distance and B's position, before and after each phase.
- **Walk:** one fused phone walking a measured loop among three or four manual anchors, as in `PositioningTests`. Compare the fused track with dead reckoning only and RSSI only.
- **Regression:** golden vectors for the estimator (Phase 4), `swift test`, `npm run typecheck`, and `npm run sample` against a running server.

## Recommended order

Phase 0 now: nothing iOS-side builds without it. Then Phase 2.1–2.2 and Phase 1.1. Together these fix what you see (correct ranges stay correct on screen, and phones stop collapsing onto anchors) without changing the wire format. Phases 1.2 and 3 give the real accuracy gain. Phases 4–5 are consistency work that should land before anyone demos accuracy numbers.
