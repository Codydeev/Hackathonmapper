# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Hackathon project: a peer-to-peer BLE mesh positioning network for use when GNSS is unavailable. Foreground iPhones relay position reports to each other over Bluetooth LE. One manually selected **gateway** phone uploads the latest reports over LAN Wi-Fi to a laptop, and the laptop shows them in a 3D web dashboard. Everything runs offline.

There are two independent parts, each with its own plan document. The plans are the source of truth for cross-component behavior:

- `website/`: laptop backend and dashboard. Plan: [WEBSITE_PLAN.md](WEBSITE_PLAN.md).
- `ios/`: native iPhone app. Plan: [app.md](app.md). Work on the app must not modify `website/`. Integrate through the HTTP contract in WEBSITE_PLAN.md, not through backend implementation details.

## Website (`website/`)

All commands run from `website/`. You need Node 20 or later.

```powershell
npm install
npm start              # tsc + vite build, then backend on :3000 serving dist/ (PORT, HOST env vars)
npm run dev            # Vite on :5173, proxies /api to :3000
npm run server         # backend only (tsx); run alongside `npm run dev`
npm run typecheck      # tsc --noEmit over src, server, shared
npm run sample         # POST sample batches to a running server (accepted/moving/duplicate)
npm run sample -- --duplicate   # or --stale
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
- **`src/main.ts`** handles DOM and UI state and keeps an `EventSource` connection. It corrects for clock offset using the snapshot's `serverTime`. **`src/scene.ts`** (`SceneView`) handles Three.js rendering: OrbitControls, CSS2D labels, position interpolation, trails, and role colors.

Coordinate frame: meters, `x` right, `y` up, `z` forward. With `positionMode: "floor"`, `y` must be 0 and the height is shown as assumed. The server has no authentication and is meant for a LAN only.

## iOS app (`ios/`)

The app requires Xcode on a Mac and physical iPhones (iOS 17+). It cannot be built or installed from Windows.

- `ios/project.yml` is an **XcodeGen** spec. Generate the Xcode project with `xcodegen` from `ios/`.
- `ios/MeshCore/` is a platform-independent Swift package holding the models (`DeviceUpdate`, `MeshPacket`, the link handshake `Hello`), `MeshStore` (sequence/epoch dedup), link framing (`Frame`, `FrameAssembler`, the coalescing `LinkOutbox`) and `RSSIStatistics`. It has the unit tests: run `swift test` from `ios/MeshCore` (use `swift test --filter <TestName>` for a single test). Put logic here when it can be tested without Core Bluetooth.
- `ios/MeshMapper/` is the app target. `BluetoothMesh` handles Core Bluetooth central and peripheral roles, `GatewayClient` uploads with URLSession to `/api/updates`, and `MeshModel` is the `@MainActor` orchestration with settings persisted in `UserDefaults`. It also publishes manual positions once per second, keeps the diagnostics counters and sets the hop budget (`originHops`). `ContentView.swift` holds the Network, Position and Gateway tabs. Keep app-side limits matched to `website/server/validate.ts`: labels at most 40 characters, frame IDs must match `^[A-Za-z0-9._-]{1,64}$`, and coordinates within ±10 000 m.

Key protocol rules from app.md:
- The mesh is an application-level relay over GATT connections, not Bluetooth SIG Mesh.
- Relays must preserve `messageId`, `originId`, `epochId` and `sequence`. Duplicates are suppressed with a bounded message-ID cache and hop limits.
- Messages are fragmented to the negotiated BLE payload size.
- The gateway keeps one request in flight with a ~3 s timeout and retries only the latest report per device. On success it removes only the entries that were actually sent.
- Positions from manual entry or RSSI must never be presented as measured coordinates.
