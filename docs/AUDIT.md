# Project audit: inconsistencies, conflicting features and outdated docs

An audit of `main` at `b6b378d` (24–25 October 2026). The parts were built by different people and
merged late, so several features overlap and many docs described an earlier state. Line numbers refer
to `b6b378d` unless a section says otherwise.

Each finding has a status:
- **Fixed** means fixed on `chore/audit-cleanup`. That branch includes `feature/uwb-v5` (wire v5).
- **Open, decision** means it is the team's choice; nothing was changed.
- **Open** means it is not fixed yet, usually because it needs phones to test.

**How it was checked.**
- Six read-only passes: docs against code, the iOS code, the website and tooling, an independent
  review of the v5 change, a review of the BLE transport and relay, and a probing review of the
  backend on spare ports.
- High-severity findings were re-checked by hand before they were fixed.
- Run on Windows: the typecheck (now including `scripts/`), `signalmap:check`, `check:mesh`,
  `check:ghostcore`, the four `ml/runtime` goldens, a Vite build, server smoke tests and probes, and
  the CLAUDE.md duplicate-name grep over all of MeshCore.
- Every pushed commit went through the CI gate (`swift test`, about 280 tests, plus the unsigned app
  build).
- Nothing was run on phones.

## Top items

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | Critical | One request with a malformed cookie crashed the backend through the tunnel; an invalid request target crashed it on the LAN | Fixed ([2.7](#27-backend-security-and-robustness)) |
| 2 | High | Four engines place phones; the main map, the Track tab and the dashboard can show the same phone in different places | Fixed: the signal map places peers everywhere ([1.1](#11-four-bluetooth-placers)) |
| 3 | High | A phone publishes one self-position (`FusionEngine`) and draws another (`PositioningService`) | Open, decision ([1.2](#12-two-self-positions)) |
| 4 | High | Fused tracking treated an anchor phone with no position as standing at (0, 0, 0) | Fixed ([2.1](#21-fusion-used-unplaced-anchors-at-the-origin)) |
| 5 | High | A stale cached report can make every phone retire a phone's live epoch after a restart race | Open ([2.8](#28-ble-transport-and-relay)) |
| 6 | Medium | The LAN server took state changes from any web page in the operator's browser and answered any Host (DNS rebinding could read the gateway token) | Fixed ([2.7](#27-backend-security-and-robustness)) |
| 7 | Medium | Every server tick was a new snapshot; trails covered ~20 s instead of 30 s | Fixed ([2.2](#22-snapshot-revision-always-changed)) |
| 8 | Medium | `npm run sample` locked the live scene to `demo-room-v1`, so phones then got 409 | Fixed ([2.3](#23-sample-script-locked-the-live-frame)) |
| 9 | Medium | Remote dashboards froze for good after a backend restart behind the tunnel | Fixed ([2.7](#27-backend-security-and-robustness)) |
| 10 | Medium | Docs disagreed on which estimator is "the one", on whether a Mac is needed, and on the wire version | Fixed ([3](#3-outdated-docs)) |

## 1. Conflicting and overlapping features

### 1.1 Four Bluetooth placers

**Fixed (decided 25 October 2026).** The main map now places peers with the signal map
(`SignalMapPositioning` in GhostCore's positioning slot), like the Track tab and the dashboard, so all
three agree and the main map uses UWB distances. `PeerLocator` stays in MeshCore with its tests. The
Track tab became the place to compare approaches: its radar can switch to Bluetooth-only or UWB-only
ranges, and "Distance methods" shows every method's distance to one neighbor with a tape-measure
trial (`DistanceLab`). The analysis below is as found at `b6b378d`.

A phone without GPS was placed by:

| Engine | Draws on | Evidence |
|---|---|---|
| GhostCore `PeerLocator` | Main map (the app's root screen) | `GhostCoreHub.swift:100` |
| `SignalMap` via `BluetoothTracker` | Track tab | `BluetoothTracker.swift:116` |
| `SignalMap` | Dashboard | `server/store.ts` `updateEstimates` |
| `FusionEngine` / `RangeSolver` | This phone's own `fused` report | `MeshModel.swift:418-423` |

**Different path-loss models.** Each placer uses its own:
- The signal map auto-calibrates `RadioModel`, from tape-measured anchors and, since v5, UWB distances.
- `FusionEngine` fits `PathLossCalibration` from anchor links.
- GhostCore's `Positioning.PathLossModel` hard-codes −59 dBm / 2.5.

**Paths start away from markers.** `MovementPredictor`'s likely paths are seeded from `BluetoothTracker`
(signal map) positions, while the markers next to them come from `PeerLocator`, so a path can start
away from its marker.

**UWB distances reach only two of the views.** They feed the signal map only, so the dashboard and
the Track tab use them and the main map does not.

**Suggested resolution:** pick one peer placer for the main map. The signal map is the one the
dashboard uses, the only one golden-tested across Swift and TypeScript, and the only one that uses
UWB distances. Wrap it as a GhostCore positioning engine, or seed the main map from `BluetoothTracker`.
The docs now describe the split honestly (app.md, CLAUDE.md, ARCHITECTURE.md §6).

### 1.2 Two self positions

**Open, decision.**
- In fused mode the wire carries `FusionEngine`'s output.
- The main map's self marker shows GhostCore's `PositioningService`, a second dead-reckoning plus RSSI
  filter. Its estimate is never published.
- So the dashboard and the phone's own map disagree about the phone itself.

**Resolution:** keep one filter. Either publish GhostCore's estimate as `fused` and remove
`FusionEngine`, `PositionFilter`, `RangeSolver` and `MotionTracker`, or feed `FusionEngine` into the
pipeline and drop `PositioningService`.

### 1.3 Three motion managers

- **The three:** `MotionSource` (GhostCore, on while the mesh runs), `MotionTracker` (fused mode) and
  `UWBRanging` (a UWB anchor's tilt). Apple advises one `CMMotionManager` per app.
- **Fixed:** `MeshModel.stop()` now stops GhostCore's positioning, which it used to leave running.
- **Open:** sharing one motion feed follows from resolving 1.2.

### 1.4 GPS status vs published GPS

**Fixed.**
- **Before:** the Start tab said "GPS ±x m" whenever Core Location had a fix, while GhostCore may
  publish `none`: with the GPS check on, or when the fix fails its own 30 m / 30 s gate.
- **Now:** it shows what is published, and otherwise why GPS is not shared.

### 1.5 Smaller overlaps

- **Two simulators in one mode.** **Open.**
  - `SimulationEngine` (room frame) feeds the 3D view and the pages.
  - `FieldSimulation` (an 800 × 600 m field) feeds only the Map tab, and its links never go through
    the signal map.
  - Label the Map tab as a separate demo, or drive both views from one simulator.
- **Two link reconcilers.** **Fixed.** The Network page now lists links from `buildMeshGraph`, so it
  shows exactly what the 3D view draws (it used to skip the closed-link check).
- **`dashboardSource`.** **Fixed.** It mapped a measured UWB fix to `manual`; both mirrors now map it
  to `uwb`. It is still unused by the app (the live mapping is `Publication`).
- **A UWB anchor's coordinates** come from `manualX`/`manualZ` (`MeshModel.swift:760`) even when the
  anchor publishes GPS. **Open.**
- **Shadowed names.** **Open.**
  - `PathLossModel`, `RSSISample` and `MotionSample` exist both at top level and inside `Positioning`.
  - `Step` exists at top level and in two nested types.
  - It compiles, but unqualified uses change meaning by context.

## 2. Bugs and inconsistencies

### 2.1 Fusion used unplaced anchors at the origin

**Fixed.**
- **Before:** `anchorSightings`, `anchorLinks`, `anchors` and `markNear` filtered on the anchor role
  only. An anchor that lost GPS reports `none` with a (0, 0, 0) placeholder, which pulled fused
  tracking and path-loss calibration toward the frame origin.
- **Now:** only placed anchors count.

### 2.2 Snapshot revision always changed

**Fixed.**
- **Revision:** it now changes only when the signal map's result or a trail did. An idle dashboard got
  0 snapshots in 4 s; it used to get one per second.
- **Trails:** they get at most one point per second, and only on a move. Points that age out (even
  from a stale phone) also make a new snapshot.
- **Jitter:** the result is compared to the millimeter, so solver wobble below that is not a change.
- **Map events:** an unchanged field snapshot is no longer re-sent every other second.

### 2.3 Sample script locked the live frame

**Fixed.**
- `npm run sample` defaults to `hervanta-v1` (the phones' frame) and takes `--frame=`.
- Its `--stale` frame check never sent a different frame, because the override landed on a device
  instead of the batch. That is fixed too.

### 2.4 Dashboard mesh node

**Fixed.**
- **Overflow:** reports beyond the 100-device batch were dropped. They now stay queued.
- **Typed body:** the upload is typed as `UpdateBatch` with the contract constants.
- **Chunk fallback:** after any write error the node resent the whole frame in 20-byte chunks, which
  corrupts it on the phone when a later chunk failed. It now falls back only when the first chunk
  fails.

### 2.5 Gaps in the merge gate

**Fixed:**
- The gate runs `check:mesh`, which now also compares `MESH_PROTOCOL_VERSION` with
  `MeshProtocol.version`.
- It prints the `swift test` count.
- `npm run typecheck` covers `scripts/`.
- `check:ghostcore` has an npm script.
- The root `package.json` forwards `demo`, `build`, `signalmap:check`, `check:mesh` and
  `check:ghostcore`.

**Open:**
- The app's `MovementModel.swift` and `RouteModel.swift` are copies of `ml/runtime/*.swift`. Only the
  JS ports run against the goldens; the Swift golden runners in `ml/runtime/test-golden*/` never run.
- `contract/scenarios/run.sh` runs `swift test` a second time.

### 2.6 Constants written inline

**Fixed:** upload limits are now named in `contract.ts`, mirroring `DashboardContract`, and used by
`validate.ts`. The frame pattern is shared with the mesh-node panel, and the port with the store and
the mesh node.

**Open:**
- The simulators compute RSSI inline instead of from `SIMULATED_RADIO_MODEL`.
- `GatewayClient.swift:105` hard-codes the batch limit of 100.
- The app validates the frame ID only in `start()`.

### 2.7 Backend security and robustness

**Fixed.** All of these came from probing a backend on spare ports:

| Finding | Now |
|---|---|
| A malformed session cookie (`%E0%A4%A`) made `decodeURIComponent` throw, which stopped the server; anyone with the tunnel URL could do it | 401; every handler runs inside `guarded` |
| `GET //[` made `new URL` throw, on both listeners | 400 |
| The LAN server accepted state-changing POSTs from any web page (`/api/reset`; `/api/tunnel` could point the QR code's gateway token at another host) | 403 when `Origin` names another host |
| The LAN server answered any Host, so DNS rebinding could read `/api/connect` (the gateway token) | Only IPs, `localhost`, single-label and local-only names (421 otherwise; `TRUSTED_HOSTS` for more) |
| `npm run tunnel`'s health checks counted as the gateway phone checking in | They send a probe header |
| The tunnel watchdog restarted a healthy quick tunnel (new URL, every phone rescans) when only the backend was down; it leaked an interval if cloudflared exited while announcing; its backoff never reset | All three fixed |
| EventSource gives up for good after an HTTP error (502 during a restart, 401 when signed out), so remote dashboards froze | Reconnects with backoff, or reloads to the sign-in page |
| The sign-in redirect could leave the site (`//evil.example`) | Same-site paths only |
| An oversized body got a connection reset instead of 413 | 413, then the connection closes |
| No limit on SSE connections | 64 at most |
| The initial `/api/state` could overwrite a newer snapshot | Ignored if older |

Still open:
- `GET /api/connect` gives the gateway token to any LAN client. This is partly by design, since the QR
  code carries it. Decide whether to limit it to loopback.
- Devices are never evicted, and retired epochs grow by one per phone restart (memory only).
- All ages use `Date.now()`, so a clock jump makes devices look fresh until wall time catches up.

### 2.8 BLE transport and relay

From a review of the transport (read only; nothing here was run on phones).

**Fixed:**
- **Restarted peers:** a peer that stops and starts its mesh invalidates our characteristic. The link
  now closes and reconnects (`didModifyServices`) instead of staying "ready" with no notifications.
- **Gateway after a rejection:** after a 409 or 400 the gateway resent the batch up to 5 times a
  second. It now waits 5 s.
- `%d` for an `Int` in a log line.

**Open (these change protocol behavior; test them on phones):**
1. **A stale epoch can retire the live one** (`MeshStore.swift:39-47`, the same rule in
   `RecordRelay.swift`, `meshproto.ts` and `server/store.ts`). This is the most important one.
   - Today an unknown epoch is always accepted as new, and the previous one is then retired.
   - **Race:**
     1. Phone X relaunches and starts epoch B.
     2. The gateway resets and hears B first.
     3. A neighbor still holding X's old epoch A, fresh for 30 s, syncs it.
     4. The gateway switches to A and drops every later B report. The server then retires B too.
     5. X disappears until it relaunches again.
   - **Suggested fix:** accept an unknown epoch only when the current one has not advanced for about
     3 s. Apply it in all four places, and update the two tests that encode today's rule.
2. **Links that never time out.**
   - Ready links never time out, and a write in flight is never abandoned.
   - Incoming links that never become ready never expire.
   - **Suggested fix:** close a ready link with no frame for about 10 s; every phone sends at least
     once a second.
3. **Relay traffic can starve position frames.** The outbox is FIFO by key and each relay envelope has
   its own key, so a summary answer can queue up to 256 envelopes ahead of positions.
   - **Suggested fix:** send Hello, position and ranging frames before relay and record frames.
4. **The handover can be lost.** Closing the redundant duplicate link drops the neighbor-ready handover
   queued on it (the first sync, records and summary).
   - **Suggested fix:** move pending outbox entries to the link that stays.
5. **Packets are echoed back.** `sync()` sends every cached packet to every neighbor every 5 s,
   including the neighbor it came from and the origin. Relays skip only the incoming neighbor, not the
   path members. This wastes bandwidth; app.md says "never back to the neighbor it came from".
6. **Main-thread churn.** `peers` is republished on every advertisement, and `devices` is rebuilt on
   every packet, all on the queue Core Bluetooth uses. Throttle both to about 1 Hz.

### 2.9 UWB distances (wire v5)

From an independent review of the v5 port. It found no compile errors and confirmed that the two
signal-map ports agree statement by statement.

**Fixed:**
- **Overconfident circles.** UWB group members got sub-meter circles even when the whole group was
  placed only by noisy RSSI. A member's circle is now never smaller than its group's, from the shift
  and turn its external links and priors allow.
  - In 400 random meshes, world-frame phones outside their circle fell from 8/27 to 6/27. The rest are
    a mirror flip and rings at their edge; RSSI alone gives 3/26 with about 3× larger circles.
- **A "guest" session path** always overfilled the session budget. It was removed.
- **Session churn.** Sessions are held from when they open, so near-equal candidates no longer close
  each other's sessions before either measures.
- **Cooldown.** An unchanged, resent token no longer ends a neighbor's cooldown.
- **Anchor flag.** A token says "anchor" only while UWB positioning is on.
- **Permission.** Toggling UWB again after a denied permission asks again.
- **"Anywhere" circles.** A UWB group whose turn nothing fixed showed 1000 m circles, the cap: one
  placed phone plus two UWB phones, with RSSI alone showing about 10 m. Its members are now on rings
  around the placed phone (golden case `uwb-triangle-one-anchor`). Found by the final regression
  review.
- **Fused links.** The signal maps' fused-link exclusion (`usedByFusion`, dashboard and Track tab) now
  matches fused tracking: an anchor reporting no position is not used by fusion, so its link counts.

**Open:**
- **Slow settling.** UWB groups that can bend (one phone ranging several others) still settle over a
  few seconds of warm starts rather than in one solve.
- **One-sided picks.** With more than four UWB candidates, one phone's pick may not be returned. That
  session times out after 20 s and that neighbor rests for 60 s.
- **Anchor fixes for at most four targets.** A direction anchor sends fixes to at most four phones at
  a time (the session budget, strongest RSSI first). Before v5 it opened sessions until iOS refused one.
- **Permission prompt.** UWB distances are on by default, so every UWB phone asks for Nearby
  Interaction permission when the mesh first starts. Tell the install round to allow it.

## 3. Outdated docs

Updated on this branch:

| Doc | What changed |
|---|---|
| OVERVIEW.md | Rewritten: it said build 6, wire v3, 63 tests and pre-GhostCore branches |
| README.md | Links HANDOVER, OVERVIEW and this audit |
| HANDOVER.md | Merge status, the build/wire table (v4, v5), the not-merged list |
| CLAUDE.md | CI instead of "only one member has a Mac"; the signal map as the dashboard's estimator, not "the one"; commands (`demo`, `check:ghostcore`, `--frame=`); pins survive restarts; LAN server checks; the recursive duplicate-name grep |
| ARCHITECTURE.md | §2 status on `main`; wire v4/v5 and frame 7 built; §5 removed files; §6 the engines actually wired; §7 the gate as `validate.sh` runs it; §8 GitHub Actions and build numbers |
| app.md | Map-first UI; build and install via CI; wire format v5 with frames 1–7; UWB distances; the signal map as shared by the dashboard and Track tab, not the main map |
| WEBSITE_PLAN.md | All endpoints; LAN Host/Origin checks; snapshot and trail rules; tunnel watchdog; mesh node on v5 with its real upload rate; field map event rate |
| website/README.md | Trimmed to how to run, with the checks; WEBSITE_PLAN holds the contract and API |
| DEMO.md | The app opens on the map; Track and Simulate losing GPS are in Settings |
| ml/README.md | The route model runs in the app; only the route filter does not |
| docs/GNSS_INTEGRITY.md | The engine is wired in (GPS check) |
| BLE_MESH_TEST_PROTOCOL.md | No fixed "v3"; it points to `MeshProtocol.version` |
| `ghost/README.md`, `ghost/heldout/run.sh` | Default to this repository's `ml/`; `heldout/data/` is now git-ignored as the README said |

**Moved to `docs/history/`, each with a banner saying what it describes:**
- POSITIONING_REVIEW.md and BLUETOOTH_REVIEW.md. Their findings were fixed (PR #9, protocol v2).
- The `feature/map-accuracy` review set (TECHNICAL_REPORT, REVIEW_VERDICT, DIRECTION_PLAN and
  `reviews/`). It describes `87b2f6c`, not `main`.

**Still current as written:** POSITIONING.md, docs/AMBIENT_RADIO.md and AC9_CHECKLIST.md.

## 4. Dead or test-only code in the shipped library

**Open.** Most of it serves the scenario runner and tests:

| Code | Suggested action |
|---|---|
| `GNSSFaultInjection.swift` (697 lines, a test harness), `ScenarioWorld`, `GhostReplay`/`GhostScenario`, `Positioning.Replay` | Move to the test target, after checking which of them the app's scenario screen (`ScenarioPanel`) needs |
| `BluetoothEstimator`'s particle filter, with `EstimatorPositioning` and `WalkingCirclePrediction` | None: the pipeline's defaults, which the app never uses |
| `GNSSComparisonRow`, `GNSSRunMetrics`, `GhostCalibration`, `GhostEllipse`, `PositionMode` | None found: referenced nowhere |
| `MovementPredictor.clouds` | Computed every tick and never drawn |
| `PositioningService.declare` | Never called, so a typed spot never reaches GhostCore's own engine |
| `ml/runtime/RouteFilter.swift` | Golden-tested, but not in the app |

## 5. Suggested next steps

1. **Decide this phone's own position (1.2)**: `PositioningService` or `FusionEngine`. Peers are decided (1.1: the
   signal map). Then use the Track tab's tape-measure trial to pick the distance method and radio model
   from real readings.
2. **Fix the epoch race (2.8 item 1)** in all four places, with tests. Then add the ready-link
   timeout and the frame priority (items 2 and 3).
3. **Install one v5 build on every phone** (merge `feature/uwb-v5` and `chore/audit-cleanup` first).
   Then run the field tests:
   - BLE_MESH_TEST_PROTOCOL.md and ARCHITECTURE.md §9.
   - Two UWB phones 4.0 m apart should read 4.00 m on the Track tab and the dashboard.
   - A pair out of UWB range should free its slots after about 20 s.
   - A v4 and a v5 phone should refuse each other at the Hello.
4. **Set the App Store Connect secrets** so "Run workflow" can upload to TestFlight.
5. **Move the test harnesses** out of the shipped library (section 4).
