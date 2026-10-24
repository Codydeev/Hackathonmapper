# Map accuracy features

What the iPhone app's on-phone map (Track tab) gains from the "measured distances first" design.
Work packages: **P1** positioning math (MeshCore), **P2** UWB ranging and transport, **P3** tracker,
map and settings UI. The website is unchanged.

Status key: **In progress** = being built now. **Stretch** = only if time allows.

## Measuring

| Feature | What it does | WP | Status | Verify on phones |
|---|---|---|---|---|
| UWB ranging on every link | Every UWB-capable phone ranges with its linked UWB-capable neighbours, not only with a direction anchor. | P2 | In progress | Two iPhone 11+ phones linked: Network → Direct links shows a distance in metres. |
| UWB on by default | Ranging starts without a toggle when the phone supports UWB distance. If the user denies Nearby Interaction permission, the phone falls back to Bluetooth only. | P2 | In progress | Fresh install: links show UWB metres without touching settings. Deny the prompt: the mesh keeps working on RSSI. |
| Session budget | At most 4 UWB sessions per phone, ranked: direction anchor, then links touching a phone without a position, then stronger RSSI. A session holds its slot for at least 20 s. If iOS reports too many sessions, the budget drops by one for the rest of the run. | P2 | In progress | Link 6 phones: settings show the budget; no more than that many peers have UWB metres at once. |
| Distances shared through the mesh | Each phone adds its fresh (≤ 2 s) UWB distance, and bearing if it has one, to its own `neighbors` entries. Relays carry them, so every phone can use every link. | P2 | In progress | Network → Known devices: another phone's report contains `uwbDistanceM`. |
| Measured bearings | On iPhone 11–13, the UWB direction is turned into a map bearing with the compass. Error is 15° combined with the compass error (10°/20°/35°). No bearing when the compass is uncalibrated or the peer is outside the field of view. | P2 | In progress | Stand north of a peer, then east of it: the bearing changes by about 90° in the right direction. |
| Wire format v4 | Adds `uwbDistanceM`, `uwbBearingDeg`, `uwbBearingErrorDeg` to `neighbors`, and `uwbDirection` to the ranging token. A v3 phone is refused at the Hello. | P2 | In progress | Mix a v3 and a v4 phone: they do not link. `swift test`: v3 packet rejected. |

## Positioning

| Feature | What it does | WP | Status | Verify on phones |
|---|---|---|---|---|
| Layout solver | Solves all phones in a connected group together (Levenberg-Marquardt), so "3.4 m apart" holds even when each phone's GPS is off by ±10 m. UWB ranges weigh far more than RSSI and GPS. | P1 | In progress | Two GPS phones 3 m apart with UWB: the map draws them about 3 m apart. |
| GPS as a soft prior | GPS no longer fixes a phone's spot; UWB distances can move it within its GPS accuracy. Manual and anchor-fix positions stay put. | P1 | In progress | Same as above; a Fixed spot phone does not move. |
| Ring instead of a false spot | A lost phone heard by one placed phone is "direction unknown". It is no longer drawn on top of its neighbour. | P1 | In progress | One placed phone, one lost phone 4 m away: map shows a 4 m ring, not a dot. |
| Bearing breaks the ring | One measured bearing places a ring phone on a spot. | P1 | In progress | iPhone 11–13 pair in view of each other: the ring becomes a dot. |
| Fair silence penalty | Phones that are not linked no longer push a lost phone away when either side already has 6 or more links. | P1 | In progress | Crowd of linked phones: a lost phone does not drift away from an unlinked neighbour. |
| RSSI calibration | Pairs with both UWB and RSSI fit the RSSI-to-distance model, which improves RSSI-only links (SE, out of UWB range). | P1 | Stretch | RSSI-only link distances move closer to the UWB distances after a minute. |

## Map

| Feature | What it does | WP | Status | Verify on phones |
|---|---|---|---|---|
| Steady camera | Centred on this phone, span max(25 m, 2.5 × farthest direct neighbour). Refits only on a > 30 % span change, a new phone, or the scope button. | P3 | In progress | Watch for 30 s: the map does not jump every second. |
| Heading-up toggle | Rotates the map with the compass heading. | P3 | In progress | Turn around with the toggle on: the map turns. |
| Link styles | UWB link solid, labelled "3.42 m". Bluetooth link dashed, labelled "≈ 4 m". Labels on this phone's links; tap others. | P3 | In progress | A UWB pair shows a solid line with metres; an SE pair shows a dashed "≈" line. |
| Inconsistency warning | A link turns amber when its drawn length differs from the measured one by more than max(1 m, 30 %). | P3 | In progress | Block a pair's line of sight: the link may turn amber. |
| Colour by basis | Marker colour shows GPS, GPS+UWB, UWB-ranged, Bluetooth or predicted. | P3 | In progress | Each phone's status title matches its colour. |
| Direction-unknown ring | An unresolved phone gets no dot, only a dashed ring around its neighbour: "Otter 42 · 4.1 m · direction unknown". | P3 | In progress | See "Ring instead of a false spot". |
| Calmer clouds | Particle dots only behind a debug toggle. The predictor shows one 95 % circle and takes over after 5 s lost. | P3 | In progress | Default map has no dots; debug toggle shows them. |
| Distance list | Track list shows "3.42 m UWB · −61 dBm". | P3 | In progress | Compare with the map label for the same peer. |

## Settings

| Feature | What it does | WP | Status | Verify on phones |
|---|---|---|---|---|
| UWB ranging toggle | Turns peer ranging on or off (persisted, default on). | P3 / P2 | In progress | Off: links show no UWB metres. |
| Budget display | Shows the current UWB session budget. | P3 | In progress | Value drops after a session-limit error. |
| "Use anchor fixes" | The old UWB positioning toggle, now only for direction-anchor fixes. It no longer blocks manual pinning when there is no fix. | P2 / P3 | In progress | On, without an anchor in range: a Fixed spot phone still publishes. |

## Honesty and limits

- Labels say **UWB-ranged** or **Bluetooth estimate**, never "measured position".
- UWB distance: about ±10–30 cm in line of sight. Bodies, pockets and walls bias it long.
- Bearings: only iPhone 11–13, only inside the UWB field of view, so expect them to come and go. Indoors and near laptops the compass can be off by 30° or more.
- Bluetooth distance is rough (about ±40 %); a dashed "≈" link is never as good as a solid one.
- One neighbour gives a distance, not a direction: that is why the ring exists.
- Distances travel in the once-per-second reports, so a moving phone lags 1–3 s.

## Not in scope / follow-ups

- Dashboard use of the new UWB fields (website `estimator.ts` and drawing). Uploads stay valid without it, because unknown neighbour keys are ignored.
- ARKit camera assistance for bearings on newer iPhones (U2 chip). Too much code for the hackathon; those phones give distance only.

## Requirements

- UWB distance: iPhone 11 or later, not iPhone SE.
- UWB bearing: iPhone 11, 12 or 13.
- Protocol v4 on every phone in the demo. Install the new build on all phones together.
