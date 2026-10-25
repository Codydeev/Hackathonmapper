# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Hackathon project: a peer-to-peer BLE mesh positioning network for use when GNSS is unavailable. Foreground iPhones relay position reports to each other over Bluetooth LE. One manually selected **gateway** phone uploads the latest reports over LAN Wi-Fi to a laptop, and the laptop shows them in a 3D web dashboard. Everything runs offline.

There are three parts. The two plan documents are the source of truth for cross-component behavior:

- `website/`: laptop backend and dashboard. Plan: [WEBSITE_PLAN.md](WEBSITE_PLAN.md).
- `ios/`: native iPhone app. Plan: [app.md](app.md). Work on the app must not modify `website/`. Integrate through the HTTP contract in WEBSITE_PLAN.md, not through backend implementation details.
- `android/`: Kotlin port of the iPhone app that joins the same mesh. It follows app.md too; see "Android app" below.

[VISION.md](VISION.md) states the project's goals and non-goals. Check a feature against it before building it.

## Docs are updated before every push

Every push brings the docs up to date with what it changes, on the same branch. A doc fix is part of the change, never a follow-up.

1. **Find what is stale.** For each name the push changes (a type, file, setting, UI label, command, wire field or constant), search the Markdown, e.g. `grep -rn --include='*.md' 'TrackRangeSource' .`, and fix every sentence that no longer holds. In-app help text (form footers, captions) counts as docs too.
2. **Update the doc that owns the topic:**
   - CLAUDE.md: commands, architecture, rules.
   - OVERVIEW.md: what exists and how the parts fit.
   - app.md: app behavior, screens, feature switches, wire format.
   - WEBSITE_PLAN.md: dashboard and the HTTP contract.
   - ARCHITECTURE.md: GhostCore engines, contract, field tests.
   - HANDOVER.md: which build runs where and what to test next.
   - DEMO.md: demo steps and the UI labels it quotes.
   - docs/AUDIT.md: mark findings fixed, or add new ones.
   - VISION.md: only when the goals change.
3. **Keep "as of" lines true:** dates, commit hashes, test counts and build numbers the push makes wrong.
4. **Say it in the commit or PR:** which docs were updated, or "no docs affected" and why.

## GhostCore (positioning core)

[ARCHITECTURE.md](ARCHITECTURE.md) is the integration contract for the GhostCore work: the shared records (`ios/MeshCore/Sources/MeshCore/Contract/GhostCoreContract.swift`, mirrored in `website/shared/ghostcore.ts`, golden JSON in `contract/fixtures/`), who owns which files, the merge gate and the field tests. Run `contract/validate.sh` (or `--quick` to skip the iOS build) before handing off or merging; it runs `swift test`, the TypeScript contract check, the website typecheck, the signal-map check, the mesh wire port and version check, the movement-model goldens, the GPS scenarios and the unsigned iOS build. GitHub Actions runs it on every push (see "Building the iPhone app"). Change the contract only together with its TS mirror and fixtures.

## Website (`website/`)

All commands run from `website/`. The root `package.json` only forwards the same script names to `website/` (`npm run setup` installs its dependencies), so they also work from the repository root. You need Node 20 or later.

```powershell
npm install
npm run demo           # first run: install, build, start and open http://localhost:3000
npm start              # tsc + vite build, then backend on :3000 serving dist/ (PORT, HOST env vars)
npm run watch          # nodemon: rebuild + restart `npm start` on changes (restart clears server state)
npm run dev            # Vite on :5173, proxies /api to :3000
npm run server         # backend only (tsx); run alongside `npm run dev`
npm run typecheck      # tsc --noEmit over src, server, shared, scripts
npm run sample         # POST sample batches to a running server (accepted/moving/duplicate), frame hervanta-v1
npm run sample -- --duplicate   # or --stale, or --frame=<id>
npm run signalmap:check          # signal-map solver on known geometry; -- --write-golden updates the Swift golden file
npm run check:mesh     # src/meshproto.ts (the app's BLE wire format) and its version against MeshProtocol.version
npm run check:ghostcore          # shared/ghostcore.ts against contract/fixtures (the GhostCore contract mirror)
npm run tunnel         # publish the dashboard through Cloudflare (needs cloudflared + running backend)
npm run tunnel:setup -- mesh.example.com   # one-time named tunnel for a fixed hostname
npm run tunnel:install # download cloudflared into website/.bin (no winget/admin); scripts also honor $CLOUDFLARED and PATH
npm run dashboard      # open Edge on :3000 with the Web Bluetooth extras the laptop mesh node uses (RSSI, reconnect)
```

There is no test runner or linter. `typecheck`, `signalmap:check`, `check:mesh`, `check:ghostcore` and `sample` against a running server (on a spare port) are the verification loop. TypeScript is strict with `noUnusedLocals` and `noUnusedParameters`. Imports use explicit `.ts` extensions (`allowImportingTsExtensions`, `verbatimModuleSyntax`), so use `import type` for type-only imports.

### Architecture

- **`shared/contract.ts`** is the single source of the wire types (`UpdateBatch`, `DeviceUpdate`, `SceneSnapshot`) and of the limits and timing constants (max body 256 KiB, max 100 devices per batch, fade/stale thresholds, trail limits). The server and the browser both import it. Change constants here, not inline.
- **`server/index.ts`** uses the plain `node:http` server with no framework. It routes `/api/*` manually and otherwise serves static files from `dist/`, then `public/`, with an SPA fallback. Browsers get updates over **SSE** (`/api/events`): the server sends a full snapshot right after accepted uploads and simulated batches (`schedulePush`, coalesced, at most every 100 ms), when the store's `revision` changed on the 1 s tick, and a heartbeat every 15 s. After a mutating control request it pushes immediately with `pushSnapshot(true)`.
- **`server/validate.ts`** turns untrusted JSON into a `NormalizedBatch` or an error. Every upload goes through it before reaching the store.
- **`server/store.ts`** (`SceneStore`) holds all state in memory. It keeps **separate `live` and `simulated` states**, and `mode` (`idle | live | simulated`) selects which one is shown. Merge rules:
  - Updates are keyed by device id + `epochId` + `sequence`. A lower or repeated sequence is ignored.
  - A new `epochId` restarts the sequence. Old epochs are retired for the rest of the session.
  - A `frameId` different from the established one throws `FrameMismatchError`, which the server returns as 409.
  - Uploads while in simulated mode are rejected with 409.
  - Restarting the server clears all state except the live scene's operator pins (git-ignored `.anchors.json`).
  - The revision (and so an SSE snapshot) changes only when something did: an upload, a control request, or a changed signal-map result or trail. Trails get at most one point per second, from the 1 s tick.
- **`server/simulation.ts`** (`SimulationEngine`) produces synthetic batches every 2 s into the simulated state, in the GPS frame `hervanta-v1` so the map background works. It can inject faults: stale devices and a down gateway.
- **`server/access.ts`** plus the public listener in `index.ts` (loopback-only `127.0.0.1:3001`, the tunnel target): every request needs a secret. Bearer gateway token reaches only `/api/health` and `/api/updates`; browsers need the dashboard key cookie (set via `/?key=` or `/login`) for everything else. Secrets live in the git-ignored `.gateway-token` / `.dashboard-key`. `/api/tunnel` (register the public URL) exists only on the LAN server and only for loopback callers. The LAN server has no secrets, so it answers only Host names a DNS-rebinding page cannot own (IPs, `localhost`, single-label and local-only names; more via `TRUSTED_HOSTS`) and refuses state-changing requests whose `Origin` names another host. Both listeners run every handler inside `guarded` (a bad request answers 400/500, never stops the server: the scene lives in memory); the 1 s snapshot tick is guarded the same way. Never route around these checks.
- **`shared/signalmap.ts`** (`solveSignalMap`) is the one estimator for phones without a position: the dashboard, the app's Track tab (`BluetoothTracker`) and the app's main map (`SignalMapPositioning` in GhostCore's positioning slot) all run it: it lays every fresh phone out so distances match its Bluetooth ranges (RSSI through `RADIO_MODEL` in `contract.ts`), with reported positions as priors. `SceneStore.updateEstimates` runs it every second: phones without a position are placed from it, and linked phones are drawn at its spot so map distances equal measured ones (`reportedPosition` keeps the report). It is mirrored line by line by MeshCore `SignalMap.swift`; `npm run signalmap:check -- --write-golden` regenerates the golden file the Swift tests replay. Change both together.
- **`src/graph.ts`** (`buildMeshGraph`) reconciles both ends' `neighbors` reports into the edges the scene draws and the side panel lists.
- **`src/main.ts`** handles DOM and UI state and keeps an `EventSource` connection. It corrects for clock offset using the snapshot's `serverTime`. **`src/scene.ts`** (`SceneView`) handles Three.js rendering: OrbitControls, CSS2D labels, position interpolation, trails, and role colors. The 2D map tab is the same `SceneView` seen straight down (`setProjection('top')`: an orthographic camera with pan and zoom only), so the two views cannot disagree; do not give it its own data or renderer. Operator pins (`store.setPin`, `POST /api/anchors`) override a phone's role and position in snapshots (`pinned`, `reported`) and act as anchors for the Bluetooth estimator; `SceneView` frames and moves the grid to anchors (or the main phone group) via `focusPoints()`. **`src/meshnode.ts`** (`MeshNode`, Web Bluetooth) makes the dashboard a mesh node on the Network page (`src/meshnodepanel.ts`). It is also the gateway fallback (reconnects remembered phones via `getDevices()` when uploads stop) and measures laptop-to-phone distance from advertisement RSSI, reported as its neighbors' `rssi`; **`src/meshproto.ts`** ports the app's wire format and must change with `MeshProtocol.version`. **`src/pages.ts`** (`PagesView`) renders the Network, Positions and Gateway pages, the dashboard counterparts of the app's tabs, from the same snapshots. Header tabs (`#map`, `#network`, `#positions`, `#gateway`) switch views: elements list their views in `data-view` (space separated) and `setView` hides the rest with `.view-hidden`. Lists that refresh every second update rows in place (rebuilding them swallows clicks).

Coordinate frame: meters, `y` up. In a GPS frame (`GeoFrame` origin, e.g. `hervanta-v1`) `x` is east and `z` north, unless the origin sets a bearing for `+z`; a frame without an origin is a room frame with `x` right and `z` forward. **`shared/geoframe.ts`** mirrors the app's `GeoFrame.origins` (keep the two tables identical). `SceneView` converts frame to scene with `toScene`: frame +z is scene -z (drawing it as +z mirrors the site); it can also lay OpenStreetMap tiles under the stage. With `positionMode: "floor"`, `y` must be 0 and the height is shown as assumed. `accuracyMeters` is always a 95 % radius. The LAN server (port 3000) has no authentication and must never be exposed; only the protected public listener may sit behind a tunnel.

## iOS app (`ios/`)

The app needs macOS to build and physical iPhones (iOS 17+) to run. From Windows, push a branch: GitHub Actions builds and tests it (see "Building the iPhone app").

- `ios/project.yml` is an **XcodeGen** spec. Generate the Xcode project with `xcodegen` from `ios/`.
- `ios/MeshCore/` is a platform-independent Swift package holding the models (`DeviceUpdate`, `MeshPacket`, the link handshake `Hello`), `MeshStore` (sequence/epoch dedup), link framing (`Frame`, `FrameAssembler`, the coalescing `LinkOutbox`), `RSSIStatistics`, the shared `RadioModel` and `SignalMap` (Swift port of `website/shared/signalmap.ts`; `SignalMapTests` replays its golden cases, so keep the two in step). It also holds positioning: `PedestrianDeadReckoning`, `PathLossModel`/`PathLossCalibration`/`MotionAwareRSSI`, `PositionFilter` (EKF), `RangeSolver` and `FusionEngine` (see app.md, "Motion + BLE anchor fusion"). `MotionTracker` in the app target only adapts Core Motion, and runs only while fused tracking is chosen or tracking (the GhostCore positioning service runs its own motion feed). The GhostCore modules (`Contract/`, `Integration/`, `Positioning/`, `Ghost/`, `GNSSIntegrity*`, the relay's `Relay*`/`RecordRelay`/`PeerSighting`) are described in ARCHITECTURE.md; `BluetoothEstimator` is now only GhostCore's baseline positioning engine (its TypeScript twin was retired with the signal map). It has the unit tests: run `swift test` from `ios/MeshCore` (use `swift test --filter <TestName>` for a single test). Put logic here when it can be tested without Core Bluetooth.
- `ios/MeshMapper/` is the app target. `BluetoothMesh` handles Core Bluetooth central and peripheral roles, `GatewayClient` uploads with URLSession to `/api/updates`, and `MeshModel` is the `@MainActor` orchestration with settings persisted in `UserDefaults`. It publishes positions on a 0.2 s loop when they moved (heartbeat once per second), keeps the diagnostics counters and sets the hop budget (`originHops`). `PhoneMapView` is the root: the GhostUI map drawn from `GhostCoreHub` (ARCHITECTURE.md §6); the Start, Network, Position and Gateway tabs from `ContentView.swift` live in a settings sheet. `BluetoothTracker` runs the signal map on the phone every second over the mesh reports, the same solver as the dashboard and the main map, and `TrackView.swift` draws it (its radar is the signal map), so tracking a phone without GPS needs no network. The Track tab is also the test bench for distance: its radar can use UWB + Bluetooth, Bluetooth only or UWB only (`SignalRanges`), and `DistanceLabModel` shows every `DistanceMethod` (MeshCore `DistanceLab`: UWB, signal map, calibrated and default RSSI, the median filter, GPS) for one neighbor, with a tape-measure trial that scores them and exports CSV. Start → Features (`FeaturesView`) switches features at runtime so the phones need no rebuild to compare them: MeshCore `FeatureFlags` (persisted as JSON, every key falls back to its default) covers motion, compass, the main map's placement engine, ranges and radio calibration, the silent-phone prediction, likely paths, fast updates and relaying GPS check records; `MeshModel.applyFeatures` and `GhostCoreHub.configure` apply a change at once. A new feature that can be switched off belongs there (app.md, "Feature switches"). GPS is published only as `GhostCoreHub` decides: with GPS check on, only GPS the integrity engine trusts. The Position tab's source (`PositionChoice`) is GPS, manual or fused (motion + BLE anchors, published as `positionSource: "fused"` while tracking, otherwise GPS or no position). With UWB positioning on, a non-anchor publishes UWB fixes as `positionSource: "uwb"`, otherwise GPS or no position, never manual coordinates. Keep app-side limits matched to `website/server/validate.ts`: labels at most 40 characters, frame IDs must match `^[A-Za-z0-9._-]{1,64}$`, and coordinates within ±10 000 m.

### Building the iPhone app

Nobody on the team has a Mac now; the team and Claude work on Windows. `.github/workflows/ios.yml` runs on GitHub's macOS runners:
- **Every push and pull request:** the gate (`contract/validate.sh`: `swift test`, the TypeScript checks and an unsigned app build). Push a branch to get Swift compiled and tested; `gh run view <id> --log-failed` shows a failure (the gate's logs are uploaded as an artifact only when it fails).
- **Every push:** an unsigned `.ipa` under the run's Artifacts, for sideloading from Windows with a free Apple ID (HANDOVER.md).
- **"Run workflow" on `main`:** a signed Release uploaded to TestFlight as build 100 + run number. It needs the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` repository secrets (an App Store Connect API key) and checks them first.
- **"iOS signing key"** (`.github/workflows/ios-keys.yml`: Run workflow, every Monday, and before every TestFlight upload): `.github/scripts/check-asc-key.mjs` checks the key works without building. It checks that `ASC_KEY_P8` is laid out the way xcodebuild's CryptoKit reads it (stricter than OpenSSL: 64-character lines), signs in to App Store Connect, and checks the key sees the app, can manage signing on the team in `ios/project.yml` and has the Admin role. The same script tries a key on Windows before it is saved (usage at its top).

Installing on phones is the expensive step: every phone must get the same build in one round when the wire format changes. Hand over iOS work as finished as possible: complete features rather than steps, with everything that can be checked on Windows checked and the gate green.

1. **Logic in MeshCore, the app target thin.** Anything that isn't Core Bluetooth, Core Motion, Core Location, Nearby Interaction or SwiftUI goes in MeshCore with unit tests. App files only adapt framework callbacks and draw.
2. **Run the algorithm before writing the Swift.** Write it in TypeScript (`website/shared/` when the dashboard needs it too, otherwise a scratch port) and run it with Node on known geometry and simulated noise. Pick Swift test thresholds from those runs, not guesses. When both sides share an algorithm, follow the signal-map pattern: the TypeScript check writes golden cases (`--write-golden`) and a Swift test replays them, with no randomness or trigonometry in the shared steps.
3. **Check the compile pitfalls that broke builds here:**
   - Duplicate top-level names across files in one module (MeshCore had two `Vector3`s). Run this from `ios/` (MeshCore has subfolders); it must print nothing:
     `grep -hoE "^(public |private |fileprivate )?(final )?(struct|enum|class|func|protocol|typealias) [A-Za-z_]+" $(find MeshCore/Sources/MeshCore -name '*.swift') | awk '{print $NF}' | sort | uniq -d`
   - Exhaustive `switch`es over MeshCore enums in the app (a new `MeshCoreError` case broke `MeshModel`'s `errorDescription`). Grep for every `switch` over an enum you change.
   - The app target sees only `public` MeshCore API. Memberwise initializers are internal, so public structs used from the app need an explicit `public init`.
   - `let speed = speed(at:)` (a local shadowing the function it calls), `reduce(0)` where a `Double` is meant (write `0.0`), `Int(x)` on a value that may be non-finite (traps), `%d` for `Int` in `String(format:)` (use `%ld`), tuple destructuring into uninitialized `let`s, and synthesized `Equatable`/`Codable` with a member that doesn't conform.
4. **Keep mirrors in step in the same change.** Update `SignalMap.swift` and `shared/signalmap.ts`, then regenerate the golden file. Keep `DashboardContract` aligned with `contract.ts`/`validate.ts`, and `RadioModel.standard` with `RADIO_MODEL`. The Kotlin twin of a changed MeshCore file (same name under `android/`) should change with it, and `./gradlew :meshcore:test` replays the same golden file; CI does not build Android, so run it locally (JDK 17).
5. **Run every check available on Windows:** `npm run typecheck`, `npm run signalmap:check`, `npm run check:mesh`, a store or server smoke test on a spare port (never the user's :3000), and a careful read of every changed Swift file. Then push and let the gate compile the Swift.
6. **Say what is unverified.** The PR or commit lists what was compiled or run (and whether the gate passed) and what was only read, and ends with the on-device checks still to do.
7. **Batch install rounds.** Bundle everything ready for the phones on one branch rather than a series of small installs. Wire-format changes must reach every phone in the same install round.

Key protocol rules from app.md:
- The mesh is an application-level relay over GATT connections, not Bluetooth SIG Mesh.
- Relays preserve the origin `id`, `epochId` and `sequence` of each report. Duplicates are suppressed by origin, epoch and sequence (`MeshStore`), hop limits and the relay path.
- Messages are fragmented to fit a single ATT write or notification.
- The gateway keeps one request in flight with a ~3 s timeout and retries only the latest report per device. On success it removes only the entries that were actually sent.
- Positions from manual entry or RSSI must never be presented as measured coordinates.
- Each phone reports its direct BLE neighbors in its own update (`neighbors`); the dashboard draws only those links. Neighbors come from the link Hello, so only handshake-ready links count.
- Wire format version 5 (`MeshProtocol.version`, mirrored by `MESH_PROTOCOL_VERSION` in `website/src/meshproto.ts`; see app.md. v4 added the `uwb` and `fused` position sources and the 95 % `accuracyMeters`; v5 added `uwbDistanceM` to neighbor observations): typed frames (`Framing`, `FrameAssembler`, unknown types skipped), a Hello per link, `MeshPacket.path`, a coalescing `LinkOutbox` per link, and link-local UWB ranging frames, all in MeshCore and unit tested. A wire change must bump the version and ship to every phone together. `BluetoothMesh` keeps a link table keyed by `LinkID` (`.outgoing` = we are central, `.incoming` = we are peripheral).
- UWB distances (on by default on phones with UWB, "UWB distances" toggle): each phone ranges with up to four linked UWB phones (`UWBSessionPolicy` in MeshCore picks them; `UWBRanging` in the app runs the sessions) and puts its fresh distance in that neighbor's `uwbDistanceM`. The signal map (both ports) uses a pair's UWB distance instead of its RSSI range, with σ 0.3 m, and moves UWB-linked groups as rigid bodies so the stiff links converge (a member's circle is never smaller than its group's); UWB distances also calibrate the radio model. GhostCore's `PeerLocator` (the main map) does not use them yet.
- Optional UWB positioning (off by default): a mounted direction anchor measures neighbors with Nearby Interaction (`UWBRanging` in the app) and sends each a `RangingFix` computed by `AnchorGeometry` (MeshCore). A target with UWB on publishes only fresh fixes, never its manual coordinates.
- `DashboardContract` in MeshCore mirrors the website's validation limits. Keep it in sync with `website/shared/contract.ts` and `website/server/validate.ts`: one invalid device makes the server reject the whole batch.

## Android app (`android/`)

A line-by-line Kotlin/Jetpack Compose port of `ios/`. **It still speaks wire format 3 while iOS and the dashboard speak 5, so Android phones and iPhones refuse each other at the Hello until `android/` is ported to v4 and v5.** Android phones and iPhones are meant to join one mesh (same GATT service, same JSON) and upload through the same HTTP contract. **[android/PORTING.md](android/PORTING.md) holds the binding conventions:** Kotlin names equal Swift names, one Swift file maps to one Kotlin file of the same name, the type mappings (watch for Swift struct copies, which need `copy()` in Kotlin), the Core Motion sign/unit conversion, BLE interop details, and what Android doesn't have (UWB with iPhones; maps are Canvas-drawn, with no Play Services).

- `android/meshcore/` is a pure-JVM module mirroring `ios/MeshCore` with JUnit tests (Swift tests ported, plus `WireCompatibilityTests` pinning frame bytes and Swift-style JSON). `SignalMapTests` reads the Swift golden file in place (`ios/MeshCore/Tests/MeshCoreTests/signalmap-golden.json`), so there is still one golden file.
- `android/app/` mirrors `ios/MeshMapper`: `MeshModel` (an `AndroidViewModel`; settings in SharedPreferences `meshmapper` with the iOS keys), `BluetoothMesh` (GATT server + client with a per-connection op queue; `LinkID` keys are BLE addresses), `GatewayClient` (HttpURLConnection), `LocationSource` (LocationManager), `MotionTracker` (SensorManager), a `UWBRanging` stub, and the Compose screens in `ContentView`/`TrackView`/`PhoneMapView`. `movement-model.json` is copied into `app/src/main/assets/`; keep it in step with the iOS copy.
- Android builds on Windows (no Mac needed). JDK 17 and the Android SDK (platform 35) are required; `local.properties` (git-ignored) sets `sdk.dir`.

```bash
cd android
./gradlew :meshcore:test            # MeshCore tests incl. golden replay and wire vectors
./gradlew :app:testDebugUnitTest    # app JVM tests (gateway batching, movement model golden, links)
./gradlew :app:assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

BLE, sensors, permissions and iPhone↔Android links can only be verified on phones. A wire-format change must ship to iPhones and Android phones in the same round.
