# GhostCore architecture

GhostCore is the positioning core of MeshMapper: phones that lose GNSS keep a position from phones
that still have one, every position says where it came from and how far it can be trusted, and a
phone whose GNSS behaves impossibly stops anchoring others. This document is the integration
contract between the five GhostCore agents and the release branch. [app.md](app.md),
[WEBSITE_PLAN.md](WEBSITE_PLAN.md) and [CLAUDE.md](CLAUDE.md) still own the transport, dashboard and
build details they describe.

Status words used below: **verified** means someone ran it and the evidence is named; **built** means
it compiles and its unit tests pass on the Mac; **planned** means it does not exist yet. Nothing is
claimed beyond what its status says.

## 1. The demo we are building

One story, three iPhones, no laptop needed:

| Step | Phone A | Phone B | Phone C |
|---|---|---|---|
| 1 | GNSS **trusted** (outdoors) | GNSS | GNSS |
| 2 | anchors B | **loses GNSS** (outage) and is placed over Bluetooth: "Bluetooth estimate ±r95" | |
| 3 | | estimate unaffected by C | GNSS **spoofed** by in-app injection: jumps 400 m. Shown "GPS rejected: jumped 400 m in 2 s; steps say 2 m"; stops anchoring others |
| 4 | | walks out of Bluetooth range: grey "last seen", prediction cloud grows | |
| 5 | | comes back: the prediction is dropped, Bluetooth estimate again | GNSS restored; trust climbs back through `recovering` |

An end-to-end run of this story on three phones beats any extra feature. Everything below serves it.

## 2. Current state (release branch `ghostcore/release`)

| Commit | Content | Status |
|---|---|---|
| `588bba1` | Build 7 (`all-work`): one-screen MapKit app, GPS / typed spot / none, on-phone Bluetooth estimator, movement model v2, wire v2 | built (gate passed on the Mac). The phones run this today |
| `b476a13` | + `origin/main` UWB positioning (Cody), **wire v3** | built |
| `ffcae45` | + GhostCore contract, fixtures, TS mirror, merge gate | built |
| `3efbda5` | + movement model v2 without the map (movement-model session) | built |
| `b2ac042`, `74680ad` | + store-and-forward relay, PeerObservation snapshots, frame-7 contract records, T3 tooling (relay agent) | built; relay agent's T3 in simulation only |
| `ca5de64`, `50094c9` | + GhostUI map (viz agent, legacy binding), route model engine (phone-test session) | built; viz agent checked on the iOS simulator |
| `044aa04`, `b377e2b` | + GhostCorePipeline, scenario runner S0–S6, GhostCoreHub in the app (lead) | built |
| `fa6f3d8`, `6b4c211` | + GNSS integrity engine (trust agent) in the pipeline slot | built; scenarios pass with it (synthetic) |
| `c09b574` | + calibrated Kalman prediction (prediction agent) | built |
| **`b1269c9`** | **Build 10**: the first release build for the three phones | built; handed to the phone-test session for install; install result pending |
| `fcdd8b1`, `d2aea29`, `d91f294` | + positioning engine, MotionSource, PositioningService; hub runs them and, with GPS check on, the integrity engine | built; integrity on real phones untested (T4) |
| `ba040e1` | + prediction fix for overconfident / ambiguous inputs | built; S5-c 95 % with GhostCore engines (synthetic) |
| `07688d6` | GPS check off by default (simulator showed an untrusted phone vanishing from the map) | built; checked on the iOS simulator |
| `1904abc` | + map bound to `GhostCoreHub`, simulation panel, GPS check toggle, calibration screen (viz agent) | built; viz agent checked on the simulator |
| **`c455be9`** | **Build 11**: GhostCore demo build | built: gate passed (swift test 234, 2 opt-in skipped; scenarios 29 pass / 1 non-gating fail / 8 pending, pending = integrity checks in the baseline run by design); simulator launch checked; installed on one phone only, then superseded by build 12 |
| `d740b03`, `1f84dd1` | + GNSS circular-evidence fix (trust agent); PeerLocator places lost phones (positioning agent) | built; S1-c 100 %, S6-b 100 %, S5-c 99 % with r95 288 m (synthetic, reproduced by the lead) |
| **`b793f3b`** | **Build 12**: the build for the three phones and field tests T1–T11 | built: gate passed on this commit. Installed on all three phones 2026-10-24 21:05–21:08 by the phone-test session (version read back on iPhone Silas and P diddy; Oskar's install confirmed by devicectl); app running on all three. No field test result yet |

Earlier phone results (builds 3 to 7: three-phone install, Bluetooth placement on the phone) are from
other sessions' notes and were not re-verified here. The user decided (2026-10-24) that the phones run
`ghostcore/release` builds only; the phone-test session installs the build the lead marks ready. Wire v3 phones refuse wire v2 phones at the Hello,
so **every phone must get the same release build in one go**.

## 3. System overview

```
 Sensors (per phone)               GhostCore engines (MeshCore, pure Swift)          Out
 ───────────────────               ─────────────────────────────────────────          ───
 CoreLocation ──raw fix──────────▶ GNSS integrity ──IntegrityAssessment──┐
 CoreMotion ──MotionObservation──▶ (trust agent)                         │
                    │                                                    ▼
 Bluetooth links ──PeerObservation─▶ Positioning ──PositionEstimate──▶ GhostCorePipeline ──▶ GhostCoreHub ──▶ GhostUI (map)
 (relay agent)            ▲         (positioning agent)                   │   (MeshCore,        (@MainActor)
                          │                                               │    integration)
 Mesh relay ◀──RelayMessage── own PositionEstimate + IntegrityAssessment ─┘         │
 (relay agent) ──peers' records──▶ Positioning / Prediction (kalman agent) ──Prediction─┘
                                                                                     └──▶ DeviceUpdate ──▶ gateway ──▶ dashboard
```

- Engines are pure MeshCore code: deterministic, unit tested with `swift test`, and replayable from
  scenario files without phones.
- `GhostCorePipeline` (MeshCore, integration) runs the engines once per second in a fixed order and
  owns the selection rules (section 6). `GhostCoreHub` (app) feeds it real sensors and mesh data,
  publishes its output to SwiftUI, and is the only place scenario inputs enter the pipeline.
- The dashboard path is unchanged: `DeviceUpdate` over the wire and HTTP. A `PositionEstimate` maps
  to it with `dashboardSource` (only measured GNSS becomes `gps`; estimates and predictions go as
  `none`, so the dashboard never shows them as measured).

## 4. The shared contract

Source of truth: [`ios/MeshCore/Sources/MeshCore/Contract/GhostCoreContract.swift`](ios/MeshCore/Sources/MeshCore/Contract/GhostCoreContract.swift).
TypeScript mirror: [`website/shared/ghostcore.ts`](website/shared/ghostcore.ts). Golden records:
[`contract/fixtures/`](contract/fixtures/) (valid) and `contract/fixtures/invalid/` (each names the one
rule it breaks). Swift (`ContractTests`) and TypeScript (`scripts/ghostcore-check.ts`) must agree on
every fixture, so the two never drift.

### Fields every record has

| Field | Meaning |
|---|---|
| `timestamp` | Unix seconds on the clock of the phone that produced the record, when the value holds. For a `Prediction`, the time predicted. **Never subtract two phones' clocks.** |
| `frameId` | Shared metric frame, `hervanta-v1`: metres, x east, y up, z north, origin Tietotalo. Pattern `^[A-Za-z0-9._-]{1,64}$`. Lat/lon exist only at the GNSS boundary (`GeoFrame`). |
| `source` | `gnss`, `bluetooth`, `uwb`, `inertial`, `manual`, `fusion` or `prediction`: the evidence behind the record |
| uncertainty | Type-specific. Every position carries `r95`, the horizontal radius holding 95 % of the belief, plus `ambiguous` (ring or several spots), optional 2×2 covariance and `vertical95` |
| `freshness` | `ageAtHandoff`: seconds already elapsed when the record was handed on (producer age plus each relay's hold time); `maxAge`: after this age the record is not current. A receiver's age = `ageAtHandoff` + its own seconds since receipt |
| `provenance` | `producerId`, `algorithm` (`name@version`), `inputs` (each used or rejected, with a reason), `contributors` (devices at any depth, producer first), `gnssDependent`, `simulated`. Both flags propagate to everything derived from such an input |

Conversions: iOS `horizontalAccuracy` is treated as a 68 % radius, so `r95 = 1.62 × accuracy`; a
per-axis 1-σ gives `r95 = 2.45 σ` (`PositionUncertainty.r95(fromRadius68:)`, `r95(fromSigma:)`).

### The six records

| Record | Produced by | Key fields | Rules that matter |
|---|---|---|---|
| `PeerObservation` | relay | observerId, peerId (from the Hello; nil if only advertising), channel (connection / advertisement), linkState, `rawRSSI` (≤ 16 samples since last snapshot), smoothedRSSI, stdDev, sampleCount, txPower?, peerModel? | ≤ 1 Hz per peer. **No distance field:** RSSI is link quality, ranges belong to the positioning engine's calibrated model |
| `PositionEstimate` | positioning (and the GNSS adapter for raw fixes) | subjectId, `kind`, `method`, position (nil if unavailable), positionMode, uncertainty, candidates, heading ± σ, velocity, lastAbsoluteAt | `kind` is the honesty class: `measured` (a GNSS or UWB fix), `estimated` (from peers / motion), `predicted`, `declared` (typed), `unavailable`. Method must match kind. GNSS needs a **trusted** assessment before it is shown as measured or anchors anyone |
| `IntegrityAssessment` | GNSS trust | status (`trusted`, `degraded`, `suspect`, `rejected`, `unavailable`, `insufficientEvidence`), trustScore 0…1 with interval, 17 reason codes, evidence list, `evaluatedFix` (the raw fix, even when rejected), `minimumDetectableOffsetMeters`, summary | **Cannot say "spoofed"**: phone data shows inconsistency, not intent. `trusted` needs at least one GNSS-independent check agreeing. Only `trusted` may anchor others |
| `MotionObservation` | positioning | interval, method, steps, displacement (dx, dz), heading (rad from +z toward +x), stationary, uncertainty | From this phone's own sensors only |
| `Prediction` | prediction | method, lastObservedAt, lastObservedPosition, center, uncertainty (r95 grows), cloud (≤ 128 points) | Never shown as live. The cloud is local only and never travels. A fresh observation of the subject replaces it |
| `RelayMessage` | relay | messageId, originId, epochId, sequence, hopsRemaining, path, freshness, payload (position / integrity / prediction / observations) | Identity never changes on relay; `relayed(by:heldFor:)` takes a hop, appends the relay, adds hold time and refuses loops. ≤ 3,072 bytes encoded |

### Versioning

- Contract version `GhostCoreContract.version = 1`. Adding an optional field keeps the version;
  renaming, removing or tightening a rule bumps it, and the Swift, TypeScript and fixtures change
  in the same commit. Only the integration lead edits the contract; agents request changes.
- Wire format: v3 (`MeshProtocol.version`). Unknown frame types are skipped, so new frame types
  need no bump. Frame types: 1 Hello, 2 position packet, 3 ranging token, 4 ranging fix (UWB),
  5 relay envelope and 6 relay summary (store-and-forward, merged), 7 contract `RelayMessage` JSON
  (≤ 3,072 bytes; planned, relay agent). A relayed record's `freshness` is the payload's own
  freshness at hand-off, so each hop's added hold time gives receivers its true age. New optional JSON fields inside
  `MeshPacket` are ignored by older v3 builds. Any change a v3 phone would refuse needs a bump and a
  same-build install on every phone.
- Dashboard upload contract (`DeviceUpdate`, `website/shared/contract.ts`) is unchanged. The server
  rejects a whole batch on one bad field, so GhostCore never adds values to its enums
  (`positionSource` stays `gps | manual | none`).

## 5. Module ownership

An agent edits only the paths it owns. A change needed in someone else's file goes to the owner (or
to the integration lead for shared files) as a diff; the owner applies it.

| Agent (session) | Owns | Produces | Consumes |
|---|---|---|---|
| **Integration lead** (`ghostcore integration contract`) | `ARCHITECTURE.md`, `MeshCore/Contract/*`, `MeshCore/Integration/*`, `ContractTests.swift`, `Integration*Tests.swift`, `contract/` (fixtures, scenarios, `validate.sh`), `website/shared/ghostcore.ts`, `website/scripts/ghostcore-check.ts`, `ios/MeshMapper/MeshModel.swift`, `LocationSource.swift`, `GhostCoreHub.swift`, `ios/project.yml`, `Info.plist`, `Package.swift`, `CLAUDE.md`, `DEMO.md`; build numbers, TestFlight, the release branch | The pipeline, the hub, releases | Everything |
| **Bluetooth mesh relay** (`ghostcore bluetooth mesh relay`) | `MeshCore/{RelayEnvelope,RelayEngine,PeerSighting,ReconnectBackoff}.swift`, `Framing.swift`, `MeshStore.swift`, `RSSIStatistics.swift`, `Ranging.swift`, additive optional fields in `Models.swift` (not `DeviceUpdate`, `Position`, `GeoFrame`, `DashboardContract`), `MeshCoreTests.swift`, `RelayEngineTests.swift`, `ios/MeshMapper/{BluetoothMesh,GatewayClient,MeshRelay,RelayTestView}.swift`, `BLE_MESH_TEST_PROTOCOL.md` | `PeerObservation`, `RelayMessage` | Records to carry |
| **Positioning engine** (`ghostcore positioning engine`) | `MeshCore/Positioning/*`, `Tests/MeshCoreTests/Positioning/*`, `BluetoothEstimator.swift` + tests, `ios/MeshMapper/{BluetoothTracker,MotionSource,Positioning*}.swift`, `website/server/estimator.ts`, `website/scripts/estimator-check.ts` (Swift and TS kept in step), `POSITIONING.md` | `PositionEstimate`, `MotionObservation` | `PeerObservation`, raw fixes, `IntegrityAssessment`, peers' estimates |
| **GNSS trust engine** (`ghostcore gnss trust engine`) | `MeshCore/GNSSIntegrity.swift`, `GNSSFaultInjection.swift`, `GNSSIntegrityTests.swift`, `GNSSFaultHarnessTests.swift`, `docs/GNSS_INTEGRITY.md` | `IntegrityAssessment` | Raw fix (`PositionEstimate`, method gnss), `MotionObservation`, peers' estimates (`gnssDependent` decides independence) |
| **Prediction** (`ghost mode kalman predictor`) | `MeshCore/Ghost/*`, `Ghost*Tests.swift`, repo-root `ghost/` (fixtures, eval, metrics) | `Prediction` | `PositionEstimate`, `MotionObservation` |
| **Map visualisation** (`ghostcore ios map visualization`) | `ios/MeshMapper/GhostUI/*`, `PhoneMapView.swift`, `TrackView.swift`, `ContentView.swift`, the in-app scenario player UI | UI | `GhostCoreHub` only |

Outside GhostCore: `ml/`, `MovementModel.swift` and `MovementPredictor.swift` (movement-model session);
`website/` apart from the two files above (dashboard session); the three test phones and their
installs (phone-test session, coordinated through the integration lead).

## 6. Integration seam: `GhostCorePipeline` and `GhostCoreHub`

`GhostCorePipeline` (MeshCore, pure) holds the latest records per phone and runs one step per second:

1. Ingest inputs since the last step: raw fixes, motion, peer observations, peers' relayed records.
2. **Integrity:** this phone's raw fix and motion → `IntegrityAssessment`.
3. **Positioning:** anchors are phones whose GNSS assessment `mayAnchorOthers` (plus declared and UWB
   fixes); estimates whose `provenance` already contains this phone are dropped (no loops) →
   `PositionEstimate` for this phone and for peers without a position.
4. **Prediction:** for phones with no fresh estimate → `Prediction`.
5. **Selection** of the one position shown per phone, in this order: trusted measured GNSS or a UWB
   fix; declared; fresh estimate; prediction; otherwise unavailable. Untrusted GNSS is never
   selected, but stays visible as `evaluatedFix` next to the selected position.
6. Outputs: per-phone selected position, assessment, prediction, raw records; this phone's
   `RelayMessage`s; this phone's `DeviceUpdate` (via `dashboardSource`).

Engines in the app now: positioning = `PositioningService` for this phone (dead reckoning, fusion,
ranging) and `BluetoothEstimator` for peers; integrity = `GNSSIntegrityMonitor` when **GPS check** is on
(`MeshModel.gpsCheck`, off by default until T4 shows real phones reach trusted); prediction = `GhostPredictor`. With GPS check off, integrity is **not
assessed** (`nil`, shown as "GPS not checked"), never faked as trusted.

Publishing: a phone sends its GPS in its mesh report only when its own assessment is `trusted`;
otherwise it reports `none` and the others place it over Bluetooth. Its own assessment travels as a
frame-7 record, so other phones can show why. Unconfirmed GPS (`insufficientEvidence`, `degraded`)
is still shown on the phone itself, flagged "GPS (unchecked)". `trusted` needs GNSS-independent
evidence (in practice motion), so in the demo the anchor phone A should stay mostly still.

`GhostCoreHub` (app, `@MainActor ObservableObject`) publishes `positions`, `integrity`,
`predictions`, `observations`, `routes` (`[originId: [relay ids, oldest first]]`) and `scenario`
(name, elapsed, step, caption, running). `inject(_:)` is the only door for scenario inputs: raw
inputs only (fixes, outages, offsets, motion, link up/down), stamped `simulated`, so everything
derived from them carries the SIMULATED badge.

## 7. Integration process

### Branches

- `ghostcore/release`: the release branch. Its head always passes the gate. Only the integration
  lead commits or merges to it. Local only until the team agrees to push (the shared GitHub repo
  belongs to Cody).
- One branch and worktree per agent: `ghostcore/<area>` in `.claude/worktrees/ghostcore-<area>`,
  branched from `ghostcore/release` and rebased on its latest head before each hand-off.
- `main` / `origin/main` belong to the team; the release merges `origin/main` in, never the reverse
  without the team.

### Hand-off and merge

1. The agent rebases onto the latest `ghostcore/release`, runs `contract/validate.sh`, and sends:
   branch, commit, gate output, and exactly what (if anything) ran on a phone.
2. The integration lead checks the diff touches only that agent's paths (`git diff --stat`), re-runs
   the gate on a merge of the branch, and merges with `--no-ff`. The merge commit message records
   what was verified and where.
3. A merge that breaks the gate is reverted at once; the agent gets the failing log.
4. Wiring into `GhostCorePipeline` / `GhostCoreHub` / `MeshModel` is a separate integration commit
   by the lead, also gated.

### Merge gate (`contract/validate.sh`)

| Check | Command |
|---|---|
| MeshCore unit tests | `cd ios/MeshCore && swift test` |
| Contract fixtures in TypeScript | `cd website && npx tsx scripts/ghostcore-check.ts` |
| Website typecheck | `cd website && npm run typecheck` |
| Bluetooth estimator, TS side | `cd website && npx tsx scripts/estimator-check.ts` |
| Movement model goldens | `node ml/runtime/test-golden.mjs`, `node ml/runtime/test-golden-v2.mjs` |
| GPS outage / spoofing scenarios | `contract/scenarios/run.sh` (once present) |
| iOS app, unsigned | `xcodegen` then `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` |

### Planned integration order

| Step | What | Depends on | Done when |
|---|---|---|---|
| I0 | Build 7 + UWB merged into the release | — | done (`b476a13`), gate green |
| I1 | Contract, fixtures, TS mirror, gate | — | done (`ffcae45`) |
| I2 | `GhostCorePipeline` + `GhostCoreHub` on today's engines; scenario format and headless runner | I1 | **done** (`044aa04`, `b377e2b`) |
| I3 | GNSS trust engine in the pipeline; untrusted GNSS stops anchoring | trust agent | **done** headless (S2–S4 pass); in the app behind GPS check (`d2aea29`), untested on phones |
| I4 | Positioning engine for this phone + `MotionSource` | positioning agent | **done** (`fcdd8b1`, `d2aea29`); PeerLocator places lost phones (`1f84dd1`) |
| I5 | Relay carries `IntegrityAssessment` (frame 7) + `PeerObservation` snapshots | relay agent | **done** in code (`74680ad`, `b377e2b`); T3 on phones open |
| I6 | Prediction (calibrated Kalman; learned model hook unset) | prediction agent | **done** (`c09b574` + fix); held-out coverage not re-run by the lead (needs the ml data checkout) |
| I7 | GhostUI bound to `GhostCoreHub`, GPS check toggle, scenario player | viz agent | **done** (`1904abc`), simulator only |
| I8 | Same build on 3 phones; then TestFlight | I2–I7 | build 12 (`b793f3b`) handed over for cable install; TestFlight upload waits for the user's OK |
| I9 | Field test T1–T11 | I8 | Results recorded in `contract/field-results/` |

If time runs short, cut from the bottom of this list upward, except I8 and the field test of
whatever is merged: an honest demo of fewer steps beats an untested full one.

## 8. Build and TestFlight validation

Signing: STUHI's paid team `Q485H7YK66` (in `ios/project.yml`), bundle `com.hackathonmapper.MeshMapper`,
App Store Connect record "MeshMapperSTUHI". The user's personal team cannot use TestFlight.

### Before any build leaves the Mac

1. `contract/validate.sh` passes on the exact commit.
2. `CURRENT_PROJECT_VERSION` in `ios/project.yml` is one higher than any uploaded build (build 7 is
   the last one in the repository; check App Store Connect for higher).
3. `MeshProtocol.version` matches the build on every phone in the test, or all phones are updated.
4. The commit is on `ghostcore/release` and the build number is noted in the commit message.

### Test phones (cable, fastest)

```
cd ios && xcodegen
xcodebuild -project MeshMapper.xcodeproj -scheme MeshMapper -configuration Debug \
  -destination id=<UDID> -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <device id> <path to MeshMapper.app>
xcrun devicectl device info apps --device <device id> | grep MeshMapper   # check the build number
```

### TestFlight

```
cd ios && xcodegen
xcodebuild -project MeshMapper.xcodeproj -scheme MeshMapper -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/MeshMapper.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/MeshMapper.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates   # uploads
```

After upload: the build appears in App Store Connect as Processing, then Ready to Test, and installs
through the internal group (automatic distribution). Done means **all three phones show the same
CFBundleVersion** and a Hello succeeds between each pair (T1). Uploading is outward-facing:
the integration lead asks the user before each upload.

## 9. Three-iPhone field tests

Phones: P1 iPhone 16 Pro, P2 iPhone 13 Pro (the only one with UWB direction, so the UWB anchor),
P3 iPhone 15. All foreground, screen awake, same build. Ground truth: marked spots measured on the
satellite map (expect about ±3 m truth error); distances between phones with a tape measure.
Every run is recorded in `contract/field-results/<date>-<test>.md`: build, phones, place, weather,
what was seen, numbers, pass/fail.

| ID | Test | Setup and steps | Pass when |
|---|---|---|---|
| T1 | Install and handshake | Same build on P1–P3; open app | All three show each other as ready neighbours within 30 s; build numbers equal |
| T2 | Peer observations | P1–P2 at 2, 5, 10, 20 m for 60 s each | `PeerObservation` from each at ≥ 0.8 Hz while linked; RSSI recorded per distance (calibration input) |
| T3 | Forced relay A→B→C | Test-only link mask blocks P1–P3; P2 in the middle | ≥ 95 % of P1's 1 Hz reports reach P3 over 2 min; identity (origin, epoch, sequence) unchanged; path = [P2]; median age at P3 ≤ 3 s |
| T4 | GNSS trust | Build 12, Settings → GPS check on, restart the mesh. P1 outdoors in the open, still on a table, 3 min; then walk 3 min. Screenshot the trust explainer (status, reasons, evidence, minimum detectable offset, raw-fix accuracy) at 10 s, 30 s, 60 s and on any change | Still: `trusted` about 6 s after the first fix with accuracy ≤ 30 m, and stays trusted, 0 `suspect` / `rejected`. Walking: dropping to `insufficientEvidence` part of the time is expected (synthetic ~35 % trusted), alarms are not |
| T5 | GNSS outage | P2 "Simulate losing GPS", P1 trusted 10–20 m away; P2 walks a 3-min loop through 6 marked checkpoints (taped corners measured on the map) and taps the time at each; PositioningService records the walk (JSONL) | P2 placed (estimated) within 5 s; truth inside r95 at ≥ 90 % of checkpoints; median checkpoint error reported. Do not score against P2's own GPS: it understates containment (positioning agent: 84 % vs 100 % on a synthetic walk) |
| T6 | Jump spoof | In-app scenario on P3: fix offset 400 m | P3 `rejected` or `suspect` within 3 s; P3 never anchors P2 afterwards (provenance shows the rejection); P2's error unchanged within ±20 % |
| T7 | Drift spoof | In-app scenario on P3: offset grows 1 m/s | Flagged before the offset reaches 50 m, or `minimumDetectableOffsetMeters` shown and honest; detection delay recorded |
| T8 | Out of range | P2 walks away until all links drop | Grey "last seen" within 10 s of the last link; prediction cloud shown and growing; truth inside r95 at 30 and 60 s (record yes / no) |
| T9 | Recovery | P2 walks back | Prediction dropped within 2 s of a fresh estimate; trail continues |
| T10 | Gateway (optional) | P1 uploads to the laptop dashboard | Dashboard shows P1–P3; P2 as Bluetooth-placed, never as GPS |
| T11 | Robustness | Bluetooth off/on, app to background and back, app restart | Links recover within 30 s; restart gives a new epoch and old reports are ignored; no crash in a 30-min run |

### Diagnosing T4 (from the GNSS trust agent)

| What the explainer shows | Likely cause |
|---|---|
| Stays `insufficientEvidence`, no "inertial" evidence | Motion is not reaching the engine, or gaps over 3 s between motion records, or fix timestamps more than 1 s ahead of the latest motion |
| `insufficientEvidence` with "a slow drift up to N m could pass unseen" | Inertial bound above 50 m; should not happen while still |
| `degraded` / degradedAccuracy | Reported accuracy over ~30 m (indoors or near buildings; iOS often reports 30–65 m inside). Not an integrity problem: move into the open |
| `suspect` while still | A real multipath step: note its size and the reported accuracy |

## 10. GPS outage and spoofing simulation

GhostCore never transmits radio: GNSS jamming or spoofing transmitters are illegal, and phone data
is all we need. Faults are injected as **raw inputs** into the real pipeline, so the engines cannot
tell a scenario from life except by the `simulated` flag, which every derived record carries.

- **Headless** (CI, no phones): `contract/scenarios/*.json` replayed by `contract/scenarios/run.sh`
  through `GhostCorePipeline` with seeded noise; each scenario lists expectations (e.g. "phone-c
  status in {suspect, rejected} by t = 93") that pass, fail or are reported **pending** while the
  engine they need has not landed. Pending is never reported as pass.
- **In the app**: the viz agent's scenario player feeds the same scenario steps through
  `GhostCoreHub.inject`. The map shows a SIMULATED banner while any injection is active.

| ID | Scenario | Injected | Expected |
|---|---|---|---|
| S1 | Outage | Phone B's fixes stop for 120 s | B estimated from A within 5 s; r95 covers truth ≥ 90 % |
| S2 | Jump | Phone C's fixes offset by 400 m at once | C `rejected` / `suspect` within 3 s; C excluded as an anchor |
| S3 | Slow drift | C's offset grows 1 m/s, bearing 90° | Flagged before 50 m, or `minimumDetectableOffsetMeters` reported |
| S4 | Recovery | C's offset removed | C passes through `recovering` / `insufficientEvidence` before `trusted`; no instant re-trust |
| S5 | Out of range | B's links to A and C drop for 90 s | Prediction within 10 s, r95 grows; dropped within 2 s after links return |
| S6 | Link flap | B–A link toggles every 5 s | No estimate jumps beyond its r95; no crash; freshness honoured |

Synthetic results are always labelled synthetic and never presented as field accuracy.

## 11. Acceptance criteria

Release candidate = all of AC-1 to AC-10 measured on phones and recorded. Synthetic results below are evidence for the code, not for the field.

| ID | Criterion | Threshold | Measured by | Status (2026-10-24) |
|---|---|---|---|---|
| AC-1 | Build | Gate green on the release head; TestFlight build processed; same build number on 3 phones | `contract/validate.sh`, App Store Connect, `devicectl` | Gate green on every merge; build 12 installed on all 3 phones (2 versions read back, 1 confirmed by devicectl); no TestFlight upload yet |
| AC-2 | Contract | Swift and TS agree on all fixtures; every produced record passes `validate()` (0 failures in a 10-min run log) | `ContractTests`, `ghostcore-check.ts`, app log | Fixtures agree (Swift + TS); app run log not yet taken |
| AC-3 | Relay | T3: ≥ 95 % delivery, 100 % identity preserved, median age ≤ 3 s | T3 log | Simulation only (relay agent: 120/120); phones open |
| AC-4 | Outage | S1 headless and T5 on phones: placed within 5 s; truth inside r95 ≥ 90 % of samples | Scenario runner, T5 record | S1 headless (estimator for peers): placed at once, 94 %, median error 41 m (synthetic). Positioning engine for this phone: 100 %, median 2.4 m (synthetic). T5 open |
| AC-5 | Jump spoof | S2: flagged within 3 s in 10 of 10 seeded runs; T6 on phones once; 0 anchoring by a non-trusted phone | Runner, T6 record, provenance | S2: flagged at 0 s, never anchors (synthetic; trust agent: 10/10 seeds). T6 open |
| AC-6 | Drift spoof | S3: flagged before 50 m offset in ≥ 9 of 10 seeded runs, or the shown minimum detectable offset is ≥ the actual undetected offset | Runner | S3: flagged after 9 s (synthetic; trust agent 10/10 with motion, never without, offset honestly unbounded) |
| AC-7 | False alarms | T4 and S1 clean phones: 0 `rejected`, ≤ 1 `suspect` episode per 10 min | T4 record, runner | S0 and the trust agent's open-sky runs: 0 alarms (synthetic). Urban-multipath model: 2–4 episodes / 10 min, would fail. T4 open |
| AC-8 | Prediction | Held-out r95 coverage 0.90–0.98 at 30, 60, 120 s (reproduced by the lead); dropped within 2 s on recovery (S5, T9) | `ghost/` eval, runner, T9 | Prediction agent held-out 0.92–0.95 (not reproduced by the lead); S5 95 % with GhostCore engines; recovery at 0 s (synthetic). T8/T9 open |
| AC-9 | Honest UI | Every shown position has its kind label; ambiguous shows a ring or candidates; predicted and stale look not live; SIMULATED badge whenever `simulated`; no "spoofed" wording anywhere | Checklist on a phone, `grep` of the UI strings | No "spoof" in GhostUI (viz agent's grep); checklist on a phone open |
| AC-10 | Demo | The section 1 story runs start to finish on 3 phones in ≤ 5 min, three rehearsals in a row without reinstalling | Rehearsal log | Not yet rehearsed |

## 12. What we must not claim

- Bluetooth RSSI gives a rough range (about ±40 % per hop with the current radio model), not a
  measured coordinate. Estimates are labelled estimates.
- Phone data detects GNSS behaving inconsistently; it cannot prove spoofing or identify an attacker.
- Synthetic and held-out-track numbers are not field accuracy until T5 to T9 say so.
- The app works in the foreground only; iOS stops Bluetooth relaying when the phone is locked.
- UWB direction works only from iPhone 11–13-class phones, about 8 m, in line of sight.

## 13. Open decisions and risks

| Item | Owner | Note |
|---|---|---|
| Push `ghostcore/release` to GitHub | user / team | Repo belongs to Cody; push only with the user's OK |
| Movement model v2 with map is overconfident (r95 held 81–88 % in the prediction agent's held-out test) | movement-model session | Asked to run without the map; not yet reproduced by the lead |
| Wire v3 needs every phone updated at once | integration lead | One install session for all three phones before field tests |
| Field ground truth is only about ±3 m | field team | Report errors with that floor |
