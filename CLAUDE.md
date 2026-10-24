# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Hackathon project: a peer-to-peer BLE mesh positioning network for use when GNSS is unavailable. Foreground iPhones relay position reports to each other over Bluetooth LE. One manually selected **gateway** phone uploads the latest reports over LAN Wi-Fi to a laptop, and the laptop shows them in a 3D web dashboard. Everything runs offline.

There are two independent parts, each with its own plan document. The plans are the source of truth for cross-component behavior:

- `website/`: laptop backend and dashboard. Plan: [WEBSITE_PLAN.md](WEBSITE_PLAN.md).
- `ios/`: native iPhone app. Plan: [app.md](app.md). Work on the app must not modify `website/`. Integrate through the HTTP contract in WEBSITE_PLAN.md, not through backend implementation details.

## Website (`website/`)

All commands run from `website/`. The root `package.json` only forwards the same script names to `website/` (`npm run setup` installs its dependencies), so they also work from the repository root. You need Node 20 or later.

```powershell
npm install
npm start              # tsc + vite build, then backend on :3000 serving dist/ (PORT, HOST env vars)
npm run watch          # nodemon: rebuild + restart `npm start` on changes (restart clears server state)
npm run dev            # Vite on :5173, proxies /api to :3000
npm run server         # backend only (tsx); run alongside `npm run dev`
npm run typecheck      # tsc --noEmit over src, server, shared
npm run sample         # POST sample batches to a running server (accepted/moving/duplicate)
npm run sample -- --duplicate   # or --stale
npm run tunnel         # publish the dashboard through Cloudflare (needs cloudflared + running backend)
npm run tunnel:setup -- mesh.example.com   # one-time named tunnel for a fixed hostname
npm run tunnel:install # download cloudflared into website/.bin (no winget/admin); scripts also honor $CLOUDFLARED and PATH
```

There is no test runner or linter. `typecheck` plus `sample` against a running server is the verification loop. TypeScript is strict with `noUnusedLocals` and `noUnusedParameters`. Imports use explicit `.ts` extensions (`allowImportingTsExtensions`, `verbatimModuleSyntax`), so use `import type` for type-only imports.

### Architecture

- **`shared/contract.ts`** is the single source of the wire types (`UpdateBatch`, `DeviceUpdate`, `SceneSnapshot`) and of the limits and timing constants (max body 256 KiB, max 100 devices per batch, fade/stale thresholds, trail limits). The server and the browser both import it. Change constants here, not inline.
- **`server/index.ts`** uses the plain `node:http` server with no framework. It routes `/api/*` manually and otherwise serves static files from `dist/`, then `public/`, with an SPA fallback. Browsers get updates over **SSE** (`/api/events`): the server sends a full snapshot when the store's `revision` has changed (checked every 1 s) and a heartbeat every 15 s. After a mutating control request it pushes immediately with `pushSnapshot(true)`.
- **`server/validate.ts`** turns untrusted JSON into a `NormalizedBatch` or an error. Every upload goes through it before reaching the store.
- **`server/store.ts`** (`SceneStore`) holds all state in memory. It keeps **separate `live` and `simulated` states**, and `mode` (`idle | live | simulated`) selects which one is shown. Merge rules:
  - Updates are keyed by device id + `epochId` + `sequence`. A lower or repeated sequence is ignored.
  - A new `epochId` restarts the sequence. Old epochs are retired for the rest of the session.
  - A `frameId` different from the established one throws `FrameMismatchError`, which the server returns as 409.
  - Uploads while in simulated mode are rejected with 409.
  - Restarting the server clears all state.
- **`server/simulation.ts`** (`SimulationEngine`) produces synthetic batches every second into the simulated state. It can inject faults: stale devices and a down gateway.
- **`server/field.ts`** (`FieldSimulation`) is the simulated outdoor field site for the Map view: towers, Wi-Fi APs, a beacon and anchor phones (simulation only, not in the upload contract) plus phones on looping routes. Positions are a pure function of elapsed time; it advances only in simulated mode while running. Its `MapSnapshot` (types in **`shared/map.ts`**) goes out as the SSE `map` event and `GET /api/map`.
- **`server/access.ts`** plus the public listener in `index.ts` (loopback-only `127.0.0.1:3001`, the tunnel target): every request needs a secret. Bearer gateway token reaches only `/api/health` and `/api/updates`; browsers need the dashboard key cookie (set via `/?key=` or `/login`) for everything else. Secrets live in the git-ignored `.gateway-token` / `.dashboard-key`. `/api/tunnel` (register the public URL) exists only on the LAN server and only for loopback callers. Never route around these checks.
- **`src/graph.ts`** (`buildMeshGraph`) reconciles both ends' `neighbors` reports into the edges the scene draws and the side panel lists.
- **`src/main.ts`** handles DOM and UI state and keeps an `EventSource` connection. It corrects for clock offset using the snapshot's `serverTime`. **`src/scene.ts`** (`SceneView`) handles Three.js rendering: OrbitControls, CSS2D labels, position interpolation, trails, and role colors. **`src/map.ts`** (`MapView`) draws the field map on a 2D canvas. Operator pins (`store.setPin`, `POST /api/anchors`) override a phone's role and position in snapshots (`pinned`, `reported`) and act as anchors for the Bluetooth estimator; `SceneView` frames and moves the grid to anchors (or the main phone group) via `focusPoints()`. **`src/pages.ts`** (`PagesView`) renders the Network, Positions and Gateway pages, the dashboard counterparts of the app's tabs, from the same snapshots. Header tabs (`#map`, `#network`, `#positions`, `#gateway`) switch views: elements list their views in `data-view` (space separated) and `setView` hides the rest with `.view-hidden`. Lists that refresh every second update rows in place (rebuilding them swallows clicks).

Coordinate frame: meters, `x` right, `y` up, `z` forward. With `positionMode: "floor"`, `y` must be 0 and the height is shown as assumed. The LAN server (port 3000) has no authentication and must never be exposed; only the protected public listener may sit behind a tunnel.

## iOS app (`ios/`)

The app requires Xcode on a Mac and physical iPhones (iOS 17+). It cannot be built or installed from Windows.

- `ios/project.yml` is an **XcodeGen** spec. Generate the Xcode project with `xcodegen` from `ios/`.
- `ios/MeshCore/` is a platform-independent Swift package holding the models (`DeviceUpdate`, `MeshPacket`, the link handshake `Hello`), `MeshStore` (sequence/epoch dedup), link framing (`Frame`, `FrameAssembler`, the coalescing `LinkOutbox`), `RSSIStatistics` and `BluetoothEstimator` (Swift port of `website/server/estimator.ts`; keep the two in step, the tests reproduce `estimator-check.ts` numbers). It also holds positioning: `PedestrianDeadReckoning`, `PathLossModel`/`PathLossCalibration`/`MotionAwareRSSI`, `PositionFilter` (EKF), `RangeSolver` and `FusionEngine` (see app.md, "Motion + BLE anchor fusion"). `MotionTracker` in the app target only adapts Core Motion. It has the unit tests: run `swift test` from `ios/MeshCore` (use `swift test --filter <TestName>` for a single test). Put logic here when it can be tested without Core Bluetooth.
- `ios/MeshMapper/` is the app target. `BluetoothMesh` handles Core Bluetooth central and peripheral roles, `GatewayClient` uploads with URLSession to `/api/updates`, and `MeshModel` is the `@MainActor` orchestration with settings persisted in `UserDefaults`. It also publishes manual positions once per second, keeps the diagnostics counters and sets the hop budget (`originHops`). `ContentView.swift` holds the Start, Network, Position and Gateway tabs. `BluetoothTracker` runs the estimator on the phone every second over the mesh reports, and `TrackView.swift` (the default tab) draws it, so tracking a phone without GPS needs no network. The Position tab's source (`PositionChoice`) is GPS, manual or fused (motion + BLE anchors, published as `positionSource: "fused"` while tracking, otherwise GPS or no position). With UWB positioning on, a non-anchor publishes UWB fixes as `positionSource: "uwb"`, otherwise GPS or no position, never manual coordinates. Keep app-side limits matched to `website/server/validate.ts`: labels at most 40 characters, frame IDs must match `^[A-Za-z0-9._-]{1,64}$`, and coordinates within ±10 000 m.

Key protocol rules from app.md:
- The mesh is an application-level relay over GATT connections, not Bluetooth SIG Mesh.
- Relays preserve the origin `id`, `epochId` and `sequence` of each report. Duplicates are suppressed by origin, epoch and sequence (`MeshStore`), hop limits and the relay path.
- Messages are fragmented to fit a single ATT write or notification.
- The gateway keeps one request in flight with a ~3 s timeout and retries only the latest report per device. On success it removes only the entries that were actually sent.
- Positions from manual entry or RSSI must never be presented as measured coordinates.
- Each phone reports its direct BLE neighbors in its own update (`neighbors`); the dashboard draws only those links. Neighbors come from the link Hello, so only handshake-ready links count.
- Wire format version 3 (`MeshProtocol.version`, see app.md): typed frames (`Framing`, `FrameAssembler`, unknown types skipped), a Hello per link, `MeshPacket.path`, a coalescing `LinkOutbox` per link, and link-local UWB ranging frames, all in MeshCore and unit tested. A wire change must bump the version and ship to every phone together. `BluetoothMesh` keeps a link table keyed by `LinkID` (`.outgoing` = we are central, `.incoming` = we are peripheral).
- Optional UWB positioning (off by default): a mounted direction anchor measures neighbors with Nearby Interaction (`UWBRanging` in the app) and sends each a `RangingFix` computed by `AnchorGeometry` (MeshCore). A target with UWB on publishes only fresh fixes, never its manual coordinates.
- `DashboardContract` in MeshCore mirrors the website's validation limits. Keep it in sync with `website/shared/contract.ts` and `website/server/validate.ts`: one invalid device makes the server reject the whole batch.
