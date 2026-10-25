> **Historical:** part of the review of the unmerged branch `feature/map-accuracy` at `87b2f6c`, not `main` (see [../REVIEW_VERDICT.md](../REVIEW_VERDICT.md) and [docs/AUDIT.md](../../../AUDIT.md)).

# Review 6: iOS map UI and product honesty

**What I reviewed.** The local checkout is on `main` (7908db0), not on `feature/map-accuracy`. The branch exists only as `origin/feature/map-accuracy` at 87b2f6c. I extracted that commit with `git archive` into `scratchpad/r6src/` and reviewed it there. All line numbers below refer to 87b2f6c.

## Verdict: B

The map now draws distances faithfully. `GeoFrame.coordinate` (Models.swift:138-142) inverts the forward equirectangular projection exactly. Within the 10 km frame limit the scale error is under 0.3 %, and `MapCircle`/`MapPolyline` work in metres, so a 4 m UWB link solved 4 m apart is drawn 4 m apart. Rings are centred on the neighbour's *drawn* point (MeshLocator.swift:194, 313-319).

The camera follows the design: it centres on this phone, keeps a 25 m minimum span, refits only on a change above 30 %, a newly appeared phone, a recentre or a tap on the scope button, and it has a heading-up mode. `MapPresentation` holds the rules and they are unit tested.

Most labels are honest. "UWB-ranged" and "Bluetooth estimate" are used, the word "measured" never appears in a title (there is a test for this), and a ring has no dot.

The grade drops from A for four reasons:
- A ring phone that goes out of reach becomes a dot sitting on its neighbour, which is the exact false spot this work set out to remove.
- A pinned (manual) phone is drawn in the GPS colour.
- When this phone is on a ring, the Track tab still shows compass directions computed from an arbitrary point on that ring.
- RSSI links will turn amber most of the time.

None of these stops a demo. All four are small fixes.

## Findings

1. **A lost ring phone is drawn on top of its neighbour.** Medium-high confidence.
   - Where: BluetoothTracker.swift:147 and 153-155.
   - Problem: for a ring phone, `lastSpot` stores `ring.center`. Once fixes stop, the `.lastSeen` branch draws a dot at that centre under the lost phone's name. MovementPredictor.swift:54 never records a track for ring phones, so the predictor never takes over, and the dot stays for up to 600 s. TrackView's radar does the same.
   - Scenario: in the demo, the ring phone walks away and its labelled dot lands exactly on the neighbour.
   - Fix: store an `isRing` flag in `lastSpot` and keep `.lastSeen` drawn as a dashed ring of growing radius with no marker.

2. **A manual pin looks like GPS.** High confidence.
   - Where: PhoneMapView.swift:392 (`case .reported: return gpsColor` also covers `.manual`) and 197 (the "Pinned spot" status uses the GPS tint). The legend (500-504) has no entry for a pinned spot.
   - Problem: other phones see a pinned phone in GPS purple. app.md says manual positions must never be presented as measured.
   - Fix: give `.reported(.manual)` its own colour and legend row ("Pinned spot (typed)").

3. **The Track tab shows fake directions when this phone is on a ring.** Medium confidence.
   - Where: TrackView.swift:92 and 65-67.
   - Problem: `relation` and the radar centre use `tracker.me?.point`. For a ring, that is a point placed on the ring toward the solver's guess, so rows read "7 m NE" although the direction is unknown.
   - Fix: when `me.directionUnresolved`, show distances only, and centre the radar on `ring.center`.

4. **Bluetooth links turn amber most of the time.** Medium confidence.
   - Where: PhoneMapView.swift:341 and BluetoothTracker.swift:55.
   - Problem: the max(1 m, 30 %) inconsistency test also runs against RSSI distances, which are good to about ±40 % and are often drawn between GPS phones that are ±10 m off.
   - Scenario: half the dashed links glow amber and the warning loses its meaning in the demo.
   - Fix: apply the test to UWB links only, or give RSSI links a ×2 band.

5. **SwiftUI redraws the whole map on every mesh packet.** Medium confidence; the performance cost needs checking on a phone.
   - Where: PhoneMapView.swift:12, 51; MeshModel.swift:120, 402.
   - Problem: `@EnvironmentObject MeshModel` republishes `diagnostics` on every received packet, so the map body and `makeDrawing()` re-run tens of times a second rather than at 1 Hz.
   - Fix: move the `Map` into a child view that takes only `tracker`, `predictor` and `frameID`, or move `diagnostics` into its own object.

6. **Heading-up can snap back to an old camera.** Medium-low confidence.
   - Where: PhoneMapView.swift:459-465.
   - Problem: `rotate` reuses `lastCamera`, which is only updated `onEnd`. A heading step during the 0.6 s refit animation restores the previous centre and distance.
   - Fix: keep the target centre and distance in `@State` and build a fresh `MapCamera` from them.

7. **Pinch and rotate gestures do not stop following.** Low confidence.
   - Where: PhoneMapView.swift:101.
   - Problem: only a drag clears `following`. After a pinch zoom, the next refit (for example when a phone appears) pulls the zoom back. On some iOS versions a `simultaneousGesture(DragGesture)` on a `Map` also interferes with panning; check this on a phone.

8. **Minor issues.**
   - The ring caption is anchored at map north (PhoneMapView.swift:296), so in heading-up mode it may sit below the ring.
   - The TrackView footer and `TrackStyle` (TrackView.swift:28, 163-170) still colour by state (green/orange/grey), while the map colours by basis, so the two tabs have different legends.
   - "GPS on" (PhoneMapView.swift:144) shows even when there is no GPS fix.
   - `simulateGPSLoss` is persisted (MeshModel.swift:112-113), so a demo phone stays "GPS off" after a relaunch.
   - MapKit may refuse to zoom in to a 25 m region; check on a phone.

**Performance otherwise:** the annotation count is about N markers + L link tags + R captions. Particles are behind a debug toggle (75-79, 310, 322). The tracker and predictor publish 1 Hz. This is fine for 20 phones or fewer.

## features.md audit (23 rows)

| # | Feature | Verdict | Evidence |
|---|---|---|---|
| 1 | UWB ranging on every link | Implemented | MeshModel.swift:536-558 (every linked neighbour is a candidate when ranging is on) |
| 2 | UWB on by default | Implemented | MeshModel.swift:160; UWBRanging.swift:257-261 (a denial closes all sessions, RSSI carries on) |
| 3 | Session budget | Implemented, with a small difference | UWBSessionPolicy.swift:32-60 has the 4 sessions, ranking and 20 s hold. After a refusal the budget becomes `active-1`, not "budget minus one" (UWBRanging.swift:262-263) |
| 4 | Distances shared through the mesh | Implemented | MeshModel.swift:297 and 563-572; `maxAge: 2` at UWBRanging.swift:112 |
| 5 | Measured bearings | Implemented | Ranging.swift:206-251 (15° combined with the compass error); OrientationSource.swift:95-102 (no bearing when the compass is uncalibrated) |
| 6 | Wire format v4 | Implemented | Models.swift:21 and 231; Ranging.swift:13-18 (`uwbDirection`) |
| 7 | Layout solver | Implemented | MeshLocator.swift:175 and 270; LayoutSolver.swift:6-10 |
| 8 | GPS as a soft prior | Implemented | MeshLocator.swift:225 (prior σ = accuracy); 279-283 (manual and anchor-fix positions move at most σ) |
| 9 | Ring instead of a false spot | Partial | Correct while the phone is estimated (MeshLocator.swift:190-196 and 316-324). When it is last seen it becomes a dot on the neighbour (finding 1) |
| 10 | Bearing breaks the ring | Implemented | MeshLocator.swift:322-324; bearing term in LayoutSolver |
| 11 | Fair silence penalty | Implemented | BluetoothEstimator.swift:148 and 464-465 |
| 12 | RSSI calibration | Implemented | RadioCalibrator.swift:9-43; MeshLocator `update` (`calibrator.add`) |
| 13 | Steady camera | Implemented, with an extra rule | MapPresentation.swift:11-60; PhoneMapView.swift:403-456. Adds a recentre when this phone moves more than 25 % of the span |
| 14 | Heading-up toggle | Implemented | PhoneMapView.swift:129, 166, 440-444 and 459-465 (see finding 6) |
| 15 | Link styles | Implemented | PhoneMapView.swift:56-62 and 339-347; MapPresentation.swift:28-38 |
| 16 | Inconsistency warning | Implemented as specified, but noisy | PhoneMapView.swift:341 (finding 4) |
| 17 | Colour by basis | Partial | PhoneMapView.swift:379-397. A manual pin gets the GPS colour, and the Track tab colours by state |
| 18 | Direction-unknown ring | Implemented | PhoneMapView.swift:65-73 and 294-303; MapPresentation.swift:100-102 |
| 19 | Calmer clouds | Implemented | PhoneMapView.swift:74-79 and 306-309; MovementPredictor.swift:26 and 64 |
| 20 | Distance list | Implemented | TrackView.swift:109-121; ContentView `directLinkText` |
| 21 | UWB ranging toggle | Implemented | ContentView `uwbSection`; MeshModel.swift:496-503 (persisted, default on) |
| 22 | Budget display | Implemented | ContentView ("Sessions at once"); MeshModel.swift:523 |
| 23 | "Use anchor fixes" | Implemented | MeshModel.swift:91 (not persisted) and 333-340 (falls back to manual or GPS when there is no fix) |

**Totals:** 19 Implemented (row 3 has a small difference and row 13 adds a rule), 2 Partial, 0 Missing. Of the other two, row 16 works as specified but is noisy and row 14 has a risk (finding 6). All 23 rows remain "Built, untested".

## Phone verification

1. Run `swift test` in `ios/MeshCore`, in particular `MapPresentationTests`.
2. **Distances are drawn true:** use two UWB phones 4.0 m apart, measured with a tape. The map label should read about 4 m, and the map's scale bar should show the drawn link at 4 m ± 0.3 m.
3. **Rings:** put one placed phone next to one lost SE phone. You should see a ring and no dot. Then walk the lost phone out of range and check that no dot appears on the neighbour (finding 1).
4. **Pin colour:** pin phone A by hand. On phone B, A's colour must differ from GPS (finding 2).
5. **Camera:** watch for 60 s without touching the phone. There should be no camera moves. Pinch, wait 10 s and check that the zoom holds. With heading-up on, walk 10 m and check there is no snap-back.
6. **Amber links:** on GPS phones with RSSI only, count how many dashed links are amber.
7. **Smoothness:** with 6 or more phones, scroll and pan the map. It should stay smooth. If it stutters, profile `makeDrawing`.
8. **Track tab while this phone is on a ring:** the rows must not show compass directions.
