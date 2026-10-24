# Ambient radio fingerprinting (experimental)

Owner: GNSS trust session. Code: `ios/MeshCore/Sources/MeshCore/AmbientRadio.swift` (observations,
recording, matching), `ios/MeshMapper/AmbientRadioScanner.swift` (Core Bluetooth scan and the on-phone
store), `ios/MeshMapper/AmbientRadioView.swift` (the experimental screen). Tests:
`ios/MeshCore/Tests/MeshCoreTests/AmbientRadioTests.swift`.

## What it is, and what it is not

A phone listens to the Bluetooth LE advertisements around it at a spot whose position is known, and
records what that spot "sounds like". Later it listens again and asks which recorded spot this
sounds like. The answer is either **"sounds like spot X, within r95, with confidence p"** or
**"insufficient evidence"**, with the reason.

- **The devices heard are observations, not peers.** Beacons, TVs, printers and other people's phones
  and earbuds are not GhostCore phones. They do not relay messages, they do not report positions, they
  are not anchors, and nothing here estimates where they are. A match places this phone near a spot
  somebody recorded, never at a device.
- **GhostCore peers are left out.** Anything advertising the mesh service (`BluetoothMesh.serviceID`)
  is dropped before recording: peers are handled by the mesh, and they move.
- **Isolated.** GNSS integrity, positioning, the pipeline and the contract do not use this module.
  `AmbientRadioTests.testIsolatedFromGNSSIntegrityAndPositioning` fails if any other MeshCore source
  mentions its types. It stays that way until field data shows it helps.
- **Off by default, foreground only.** The scanner runs only while the Ambient radio screen is open and
  the user has switched listening on. It stops when the screen closes and when the app leaves the
  foreground.

## iOS scanning

- `AmbientRadioScanner` has its **own** `CBCentralManager` on its own queue and calls
  `scanForPeripherals(withServices: nil, options: [AllowDuplicates: true])`. It never connects.
  `BluetoothMesh` is unchanged: it keeps its own central, scanning only for the mesh service, and its
  links and relaying are untouched.
- **Shared radio, effect unmeasured.** Two centrals scanning at once share one radio. How much the
  ambient scan slows mesh discovery and link-up has **not been measured**. Before the scanner is ever
  used next to a demo, measure T1 link-up time between two phones with listening on and off (5 runs
  each, median and worst). Until then, don't listen during a demo.
- **Foreground only.** iOS ignores scans for every service while an app is in the background and
  coalesces duplicates. The scanner stops anyway when the app leaves the foreground.
- **What an advertisement offers:** an identifier iOS assigns (`CBPeripheral.identifier`, never the
  hardware address), RSSI, and, when present, a local name, manufacturer data, service UUIDs, service
  data, Tx power and a connectable flag. Advertisements arrive irregularly, from several a second to
  one every few seconds.
- **iBeacon is invisible here.** iOS withholds iBeacon advertisements from Core Bluetooth; they need
  Core Location ranging with known proximity UUIDs, which this module does not do. Eddystone beacons
  are visible through their service data.
- **RSSI is coarse.** It swings by 10 dB or more with body position, phone orientation, people in
  between and phone model. The matcher allows about 6 dB between two visits to the same spot.

## Identifier stability

| Key | Where it comes from | Stable? | Same on other phones? |
|---|---|---|---|
| `ios` | iOS's identifier for the advertiser | Only while the device keeps its address. Most phones, watches, laptops and earbuds rotate a private address about every 15 min; fixed devices (many TVs, printers, beacons) do not | No: each phone gets its own identifiers |
| `eddystoneUID` | an Eddystone-UID beacon's namespace + instance | Yes, until reconfigured | Yes |
| `classRank` | the n-th strongest steady device of one advertisement class (company + message type + services + connectable) | Survives rotation, but any device of that class can take the rank | Yes |

- Matching on identifiers alone decays within minutes wherever the devices are phones and earbuds.
  The evaluation shows this: half an hour after recording, "devices only" falls from 81 % to 46 %
  correct at the recorded spot.
- **Class ranks** carry the place across rotation, but they are not specific to a place: every
  building has "a strongest Apple phone". On their own they matched another building in 36 % of
  synthetic visits. So they may strengthen a match but never make one: a match needs at least **two
  recognised devices** (`minCommonDevices`), and they count half (`classWeight`).
- **Spots recorded on another phone** are compared on portable keys only (Eddystone, class ranks).

## Moving devices

- **Passing by while recording:** an emitter goes into a fingerprint only if it is heard in at least
  half of the 20 s, at least 5 times, with a spread ≤ 8 dB and a level trend ≤ 0.4 dB/s. Someone
  walking past changes faster than that.
- **Passing by while matching:** live emitters heard in less than 30 % of the window are ignored.
- **Travelling with the user:** the user's own watch or earbuds, or a companion's phone, sound the same
  everywhere. An emitter heard stronger than −72 dBm (within a few metres) at two spots at least 30 m
  apart cannot be one fixed device near both, so it is marked travelling and never counts as
  evidence of place. This works on class ranks too, so it survives the watch's address rotation.
- **Not handled:** furniture or people moving between visits, devices switched off, a different
  phone model's RSSI offset (absorbed only by the 6 dB tolerance), and anyone who moves a fixed
  device. The phone should stand still while listening; the matcher does not check that.

## Recording and matching

Recording a spot needs ≥ 15 s of listening (the screen uses the last 20 s) and ≥ 3 steady devices.
Its position comes from this phone:

- a pinned spot (`declared`);
- GPS that the GPS check trusts (`gnss`);
- GPS while the GPS check is off (`gnssUnchecked`).

Bluetooth estimates and predictions are refused as too rough to label a spot with.

Matching listens for ≥ 10 s (the screen compares the last 15 s) and scores each recorded spot in the
frame against a "somewhere not recorded" hypothesis:

- each device or class rank heard at both: Gaussian in the RSSI difference (σ = √(6² + spreads²) dB)
  against an unexplained level anywhere in a 60 dB span;
- each recorded emitter not heard now: ×0.25/0.9 if it was strong (≥ −75 dBm), ×0.7/0.9 if weak;
- each strong emitter heard now but not recorded there: ×0.5;
- class ranks at half weight; a spot sharing fewer than 2 devices (or 3 devices/ranks) scores zero.

Posteriors are shared among the spots and "somewhere not recorded" (weight 1). Spots within 40 m of
the best one pool their posteriors.

| Verdict | When |
|---|---|
| `match` | Pooled confidence ≥ 0.7. Position = posterior-weighted spot. r95 = √(20² + spot r95²) + the pool's extent |
| `insufficientEvidence` / `windowTooShort` | Listened < 10 s |
| … / `noFingerprints` | No spot recorded in this frame |
| … / `tooFewEmittersHeard` | Fewer than 3 steady devices heard |
| … / `tooFewCommonEmitters` | No spot shares 2 devices and 3 devices or ranks with what is heard (elsewhere, or rotated) |
| … / `ambiguous` | Confidence < 0.7 and another spot more than 40 m away has ≥ 0.2 |
| … / `weakMatch` | Confidence < 0.7 otherwise |

**r95 is never below 20 m.** Moving 15 m relative to a device 20 m away changes its level by about
6 dB, no more than two visits to the same spot differ, so a fingerprint cannot resolve finer. With a
10 m floor, half of the synthetic visits made 12–18 m from a spot came back as confident wrong
answers.

## What is stored (bystanders' privacy)

Per recorded spot, in `FingerprintDatabase`:

- label, frame, x/z, how the position was known and its r95;
- this phone's device ID, the time, the duration, and how many emitters were left out;
- per steady emitter: a key, median RSSI (0.5 dB), spread, presence, sample count and trend.

Keys are **FNV-1a digests**:

- of iOS's per-phone identifier (itself random, never a hardware address);
- of an Eddystone namespace + instance;
- of the advertisement class (company ID, the first payload byte, service UUIDs, connectable), plus a rank.

**Not stored, not logged:** device names (the local name is never read), manufacturer data or service
data (they are read only to form a digest), raw identifiers, and the live scan beyond its 120 s
rolling buffer. The digest is not cryptographic: a class comes from a small space and could be
guessed back, but it says only "an Apple phone of this message type", never whose.

**Where:** `Application Support/ambient-fingerprints.json` on the phone, file protection on, excluded
from iCloud backup. **Never relayed, uploaded or logged.** Nothing in the mesh, the gateway or the
dashboard reads it. "Delete all spots" removes the file's contents.

## Results (synthetic)

**All numbers are synthetic** (`AmbientRadioTests.Site`): a 100 m × 100 m building, 16 spots on a
25 m grid recorded 20 s each, then 15 s visits at the spot, 5 m away, between spots (12–18 m from the
nearest), and in another building with the same kinds of devices. 5 sites per row. Correct = a match
whose r95 holds the truth; wrong = a match whose r95 does not (any match in another building is
wrong). Not field accuracy; nothing has run on a phone.

| Matcher | Minutes after recording | At a spot: correct / wrong / insufficient | Between spots | Another building: wrong |
|---|---|---|---|---|
| devices + class ranks (default) | 2 | 91 % / 0 % / 9 % | 90 % / 0 % / 10 % | 0 % |
| devices + class ranks (default) | 30 and 60 | 84 % / 0 % / 16 % | 64 % / 0 % / 36 % | 0 % |
| devices only | 2 | 81 % / 0 % / 19 % | 76 % / 0 % / 24 % | 0 % |
| devices only | 30 and 60 | 46 % / 0 % / 54 % | 20 % / 0 % / 80 % | 0 % |
| class ranks only, no device requirement | 2, 30 and 60 | 68 % / 0 % / 33 % | 39 % / 3 % / 59 % | **36 %** |
| default, building with only rotating devices | 2 | 89 % / 0 % / 11 % | 78 % / 0 % / 23 % | 0 % |
| default, building with only rotating devices | 30 and 60 | 0 % / 0 % / 100 % | 0 % / 0 % / 100 % | 0 % |

(30 and 60 minutes are identical because every rotating device has rotated once by 30 minutes.)

Reading it:

- In the synthetic building with 4 Eddystone beacons and 7 fixed-address devices, the default matcher
  holds up across address rotation and never claims a spot in another building.
- Where everything rotates (a hall full of phones and laptops, no beacons), fingerprints are usable
  for about 15 minutes and then honestly say "insufficient evidence".
- Class ranks alone are not safe; that is why a match needs two recognised devices.

Full table: `AMBIENT_REPORT=/tmp/ambient.md swift test --filter AmbientRadioTests/testEvaluationReport`
(from `ios/MeshCore`, about 35 s).

## Validating it on phones (before any use)

1. **Coexistence (T1 on/off):** two phones, mesh only, measure link-up time 5 times. Then 5 times with
   ambient listening on in one phone. Pass only if the median link-up time stays within the T1
   threshold.
2. **Recording:** 6–8 spots in one building, 20–30 m apart, pinned or on trusted GPS, standing still.
   Note how many steady devices each keeps, and whether any are beacons or fixed devices.
3. **Revisits after 5, 30 and 60 min:** at each spot, 5 m away, and between spots, record the verdict,
   the r95 and the true distance. Also visit another building. Report correct / wrong / insufficient as
   in the table, labelled field.
4. Only if wrong answers stay near 0 % could it become evidence for positioning: an own-estimate with
   `gnssDependent` true for spots recorded on GPS. That would go through the integration lead and the
   contract, not around them.

## Limitations

- Synthetic only; no phone run.
- One phone's fingerprints don't transfer to another phone except through beacons and class ranks.
- Halls full of phones decay to "insufficient evidence" within one rotation period. Fixed devices
  or Eddystone beacons are what make it last.
- Accuracy is spot-level (r95 ≥ 20 m), not a coordinate.
- The phone must stand still while listening; nothing enforces it.
- The radio-sharing cost to the mesh is unmeasured.

## Appendix: full evaluation (synthetic)

Synthetic: AmbientRadioTests.Site, 5 sites × 16 spots recorded 20 s each, then 15 s visits. Correct = match whose radius holds the truth; wrong = match whose radius does not (any match in another building is wrong).

| Features | Minutes after recording | Place | Correct | Wrong | Insufficient evidence |
|---|---|---|---|---|---|
| devices only | 2 | at a recorded spot | 81 % | 0 % | 19 % |
| devices only | 2 | 5 m from a spot | 80 % | 3 % | 18 % |
| devices only | 2 | between spots (12–18 m) | 76 % | 0 % | 24 % |
| devices only | 2 | another building | 0 % | 0 % | 100 % |
| devices only | 30 | at a recorded spot | 46 % | 0 % | 54 % |
| devices only | 30 | 5 m from a spot | 36 % | 0 % | 64 % |
| devices only | 30 | between spots (12–18 m) | 20 % | 0 % | 80 % |
| devices only | 30 | another building | 0 % | 0 % | 100 % |
| devices only | 60 | at a recorded spot | 46 % | 0 % | 54 % |
| devices only | 60 | 5 m from a spot | 36 % | 0 % | 64 % |
| devices only | 60 | between spots (12–18 m) | 20 % | 0 % | 80 % |
| devices only | 60 | another building | 0 % | 0 % | 100 % |
| class ranks only (no device requirement) | 2 | at a recorded spot | 68 % | 0 % | 33 % |
| class ranks only (no device requirement) | 2 | 5 m from a spot | 59 % | 1 % | 40 % |
| class ranks only (no device requirement) | 2 | between spots (12–18 m) | 39 % | 3 % | 59 % |
| class ranks only (no device requirement) | 2 | another building | 0 % | 36 % | 64 % |
| class ranks only (no device requirement) | 30 | at a recorded spot | 68 % | 0 % | 33 % |
| class ranks only (no device requirement) | 30 | 5 m from a spot | 58 % | 1 % | 41 % |
| class ranks only (no device requirement) | 30 | between spots (12–18 m) | 39 % | 3 % | 59 % |
| class ranks only (no device requirement) | 30 | another building | 0 % | 36 % | 64 % |
| class ranks only (no device requirement) | 60 | at a recorded spot | 68 % | 0 % | 33 % |
| class ranks only (no device requirement) | 60 | 5 m from a spot | 58 % | 1 % | 41 % |
| class ranks only (no device requirement) | 60 | between spots (12–18 m) | 39 % | 3 % | 59 % |
| class ranks only (no device requirement) | 60 | another building | 0 % | 36 % | 64 % |
| both (default) | 2 | at a recorded spot | 91 % | 0 % | 9 % |
| both (default) | 2 | 5 m from a spot | 91 % | 1 % | 8 % |
| both (default) | 2 | between spots (12–18 m) | 90 % | 0 % | 10 % |
| both (default) | 2 | another building | 0 % | 0 % | 100 % |
| both (default) | 30 | at a recorded spot | 84 % | 0 % | 16 % |
| both (default) | 30 | 5 m from a spot | 85 % | 0 % | 15 % |
| both (default) | 30 | between spots (12–18 m) | 64 % | 0 % | 36 % |
| both (default) | 30 | another building | 0 % | 0 % | 100 % |
| both (default) | 60 | at a recorded spot | 84 % | 0 % | 16 % |
| both (default) | 60 | 5 m from a spot | 85 % | 0 % | 15 % |
| both (default) | 60 | between spots (12–18 m) | 64 % | 0 % | 36 % |
| both (default) | 60 | another building | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 2 | at a recorded spot | 89 % | 0 % | 11 % |
| both, site with only rotating devices | 2 | 5 m from a spot | 90 % | 1 % | 9 % |
| both, site with only rotating devices | 2 | between spots (12–18 m) | 78 % | 0 % | 23 % |
| both, site with only rotating devices | 2 | another building | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 30 | at a recorded spot | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 30 | 5 m from a spot | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 30 | between spots (12–18 m) | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 30 | another building | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 60 | at a recorded spot | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 60 | 5 m from a spot | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 60 | between spots (12–18 m) | 0 % | 0 % | 100 % |
| both, site with only rotating devices | 60 | another building | 0 % | 0 % | 100 % |
