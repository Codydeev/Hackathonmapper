# iPhone mesh app — implementation plan

## Goal and boundaries

Build a native iPhone app for a foreground Bluetooth Low Energy (BLE) mesh demo. Phones discover nearby app instances, exchange and relay position reports, and optionally act as a gateway that uploads the latest reports to a laptop over local Wi-Fi.

This is the iPhone app plan only. Website implementation belongs to another agent. Do not modify `website/` as part of this work. Coordinate HTTP integration using the contract in `WEBSITE_PLAN.md`; do not treat existing backend implementation details as the contract.

The mesh is an application-level relay network over Core Bluetooth connections, not a Bluetooth SIG Mesh implementation. No internet connection is required for the local demo.

## Platform and demo constraints

- Swift and SwiftUI for the interface; Core Bluetooth for peer discovery and data transport.
- Build, sign, install, and test using Xcode on a Mac and physical iPhones. Windows/VS Code alone cannot build and install the native app.
- Start with three to six iPhones. Verify behavior on actual phone models before expanding.
- Keep all participating apps foregrounded during the demo. A visible demo-mode switch may keep the screen awake while networking runs; restore normal idle behavior on stop.
- Ask for Bluetooth permission with a clear usage description. Only gateway mode needs local-network access and HTTP upload behavior.
- Do not promise continuous background relaying, locked-screen operation, or reliable position measurement from BLE RSSI.

## User interface

### Network screen

- Editable device label and stable app-generated device ID.
- Start/stop network control and Bluetooth authorization/power status.
- Direct neighbors: connection state, last packet age, RSSI where available, and short IDs.
- Direct links reported to the dashboard: peers identified by app device ID (see Direct-neighbor reports).
- Known devices: last reported coordinates, source, age, and whether the report arrived directly or through a relay.
- Diagnostics: received, relayed, duplicate, expired, and dropped packet counts.
- Explicit foreground/demo-mode indicator.

### Position screen

- Current positioning source and shared frame ID.
- Manual coordinate entry for deterministic integration tests.
- Anchor mode: enter a fixed known position in meters.
- Mobile mode: consume positions from the positioning component when available.
- Display accuracy as unknown when no estimate exists.
- Clearly label manual/demo coordinates and assumed height. Do not represent them as measured results.

### Gateway screen

- Manual gateway toggle; no automatic election in the MVP.
- Editable and persisted laptop base URL: a LAN URL such as `http://192.168.1.20:3000`, or the public URL printed by `npm run tunnel` (a fixed hostname after `npm run tunnel:setup`, otherwise `https://….trycloudflare.com`) so the gateway can upload from any network, including mobile data.
- Handle `meshmapper://gateway?url=<base>&token=<token>` (registered URL scheme): the QR code from the dashboard or `npm run tunnel` fills in both fields, switches to the Gateway tab and checks the connection, but never starts uploading by itself.
- Gateway token field (persisted). The internet endpoint requires it as `Authorization: Bearer <token>` on health checks and uploads; the LAN server ignores it. A 401 stops uploading with a readable message instead of retrying.
- Check connection button calling `GET /api/health`.
- Last successful upload, accepted/ignored counts, pending-device count, and error message.
- Stop uploading control independent of BLE networking.

`localhost` on the iPhone refers to the phone, not the laptop. The gateway uses the laptop's LAN IPv4 address, or the tunnel URL when it is not on the laptop's network. Keep the app's base URL separate from the `/api/updates` endpoint path.

## Suggested app components

| Component | Responsibility |
|---|---|
| AppModel | UI state and start/stop orchestration |
| IdentityStore | Persist stable device ID, label, frame, and gateway settings |
| BLETransport | Central/peripheral managers, discovery, GATT links, framing, reconnects |
| MeshRouter | Message validation, deduplication, forwarding, hop limits |
| PositionSource | Manual positions, anchors, and future positioning-engine output |
| PositionStore | Latest report per origin, sequence/epoch handling, receive freshness |
| GatewayUploader | HTTP batches, coalesced retries, connection health |

Serialize BLE and routing state on a dedicated serial queue or actor. Deliver observable UI changes on the main actor. Avoid sharing mutable dictionaries between delegate callbacks and upload tasks.

## BLE discovery and connection design

Each phone runs both:

1. A `CBPeripheralManager` advertising one app-specific service UUID.
2. A `CBCentralManager` scanning specifically for that service UUID.

Publish a single message characteristic supporting writes with response and notifications. The central writes messages to the peripheral; the peripheral sends messages back through notifications after subscription. Send all mesh data through these connected GATT channels, not advertising payloads.

### Link setup

1. Discover a matching peripheral and connect with a bounded timeout.
2. Discover the service and characteristic; subscribe to notifications.
3. Exchange a small handshake: protocol version, demo-session ID, and stable app device ID.
4. Reject unsupported protocol versions or a different demo session before processing mesh data.
5. Count the link as ready only after handshake and notification subscription are complete.

Core Bluetooth peripheral identifiers are transport handles, not shared mesh identities. Never use a BLE MAC address as an app device ID.

### Duplicate links and retries

Phones may discover each other simultaneously, producing two physical links for one logical neighbor. Use the handshake IDs to choose a canonical direction deterministically: keep the connection initiated by the lower app device ID once that connection is ready, then retire the redundant connection. Preserve the working link while reconciling to avoid connection churn. Track pending discoveries and apply reconnect backoff with jitter.

Start with a small configurable neighbor limit, such as four logical neighbors. This is an app resource budget, not an iOS guarantee. Validate that the chosen topology still permits relaying; do not assume every phone can connect to every other phone.

## BLE framing and flow control

Do not assume an entire JSON message fits one BLE write or notification.

- Encode logical messages as bounded UTF-8 JSON payloads.
- Fragment into chunks using the actual maximum write/notification payload reported by Core Bluetooth.
- Each chunk carries a protocol version, transfer ID, fragment index, fragment count, and total payload size.
- Permit only bounded payloads, for example 8 KiB per message, with bounded incomplete transfers per peer and a short reassembly timeout.
- Validate fragment sizes, counts, and indices before allocating or copying data. Discard malformed or expired transfers.
- Queue fragments per peer and preserve ordering within a transfer.
- Initially use writes with response and wait for completion before the next central-to-peripheral chunk.
- On the peripheral, when `updateValue` returns false, stop draining the queue and resume from `peripheralManagerIsReady(toUpdateSubscribers:)`.
- Bound outgoing queues; coalesce queued position reports for the same origin where possible. A dropped incomplete transfer must time out cleanly at the receiver.

Transport transfer IDs are distinct from mesh message IDs. Re-fragment a forwarded logical message for each destination's payload limit.

## Mesh protocol

Use one foreground demo-session ID configured consistently across participating phones. The handshake/session ID prevents accidental cross-demo mixing; it is not authentication.

### Envelope

| Field | Meaning |
|---|---|
| `protocolVersion` | Mesh wire-format version, initially 1 |
| `sessionId` | Explicit demo network identifier |
| `messageId` | Origin-generated UUID preserved across relays |
| `originId` | Stable originating app identity |
| `epochId` | New UUID each originating stream starts |
| `sequence` | Increasing integer assigned by the origin |
| `type` | Initially `position`; keep handshake/control messages link-local |
| `hopsRemaining` | Maximum further forwarding depth, initially 4 |
| `payload` | Position report in the agreed shared frame |

### Receive and forward

1. Reassemble and validate the message before changing state.
2. Reject the wrong protocol/session, invalid fields, impossible lengths, and invalid coordinates.
3. Reject duplicate message IDs using a bounded cache, for example a two-minute lifetime and 4,096 entries.
4. Apply position updates by origin, epoch, and sequence; ignore older or duplicate updates.
5. Deliver accepted reports to the UI and gateway's latest-report store.
6. If the message has remaining hops, forward it with one fewer hop to ready neighbors other than the incoming logical neighbor.
7. Never assign a new origin sequence or message ID when forwarding.

Use a small random forwarding delay to reduce simultaneous bursts. Duplicate suppression and hop limits are both required: neither alone prevents unnecessary traffic. Ignore reports returning to their own origin.

For the MVP, send each origin's current position about once per second, including stationary anchors. Each newly produced report gets a new sequence. Relays must not create new sequences for cached reports. Do not periodically replay the whole network cache as new measurements.

## Positioning contract and honest scope

Networking and positioning are separate responsibilities. BLE connectivity or relay count does not produce a position, distance, or height.

### Shared coordinates

- `units`: meters (`m`).
- `x`: right across the floor plan; `y`: up; `z`: forward across the floor plan.
- All phones use one fixed origin and orientation identified by `frameId`.
- A changed origin/orientation requires a new frame and an explicit coordinated reset. Do not silently reinterpret old coordinates.
- `positionMode: "3d"` means a source supplied estimated height.
- `positionMode: "floor"` requires `y: 0` and means height is assumed.
- Omit accuracy and measurement age when unknown. Do not invent precision.

### MVP sources

1. **Manual coordinates:** first integration milestone. Move a phone's coordinates through the app UI and verify they travel through another phone to the dashboard. Mark these as manual/demo data in the app and during presentation.
2. **Fixed anchors:** configure known coordinates and publish them normally.
3. **Real mobile positions:** plug in output from the team's positioning component. If only nearest-anchor zones or RSSI exist, report them separately in the app instead of fabricating dashboard coordinates.
4. **Motion + BLE anchors** (`FusionEngine` in MeshCore): described below.

### Motion + BLE anchor fusion

Dead reckoning (smooth, drifts) is fused with RSSI to linked anchor phones (bounded, noisy) in an extended Kalman filter over x, z, this phone's radio offset (dB) and the gyro heading's offset from the frame.

- **Dead reckoning:** steps are peaks of the vertical acceleration, stride follows their swing (Weinberg), and heading integrates the bias-corrected gyro rate about gravity (works held flat or upright). Heading is relative: the user starts facing `+z`, from known coordinates or from the RSSI-only fix, and can re-align later.
- **Accelerometer against BLE range errors:** while no steps are detected RSSI is averaged over the whole still period; a sample jumping further than the walked distance can explain is dropped (unless three in a row agree); while walking, smoothing lag adds uncertainty; and the filter is re-fed only after 2 m of walking or when the still average doubles its sample count, so correlated shadowing is not counted twice. The innovation gate then rejects ranges the steps cannot explain.
- **Errors between devices:** anchors' reports of each other (known distances) fit the path-loss model and a per-anchor radio offset (`PathLossCalibration`, ridge priors). Each phone's own offset and slow heading drift are filter states.
- **Honest output:** nothing is published until tracking starts. The published `accuracyMeters` is the filter's 1σ radial estimate. The RSSI-only fix is shown in the app for comparison and never published. Height is the start height plus barometric change in 3D mode.

Tuning comes from simulated walks (`PositioningTests`): with four corner anchors in a 12 × 10 m room, the fused error stayed bounded around 1–2 m over ten minutes of drifting dead reckoning, while dead reckoning alone reached about 9 m. On short walks plain dead reckoning is slightly better. Real rooms need on-device validation.

Optional Nearby Interaction/UWB ranging can improve distance estimates on supported phones, but it does not automatically create a shared global frame. A solver, suitable anchors, and coordinate transforms are still required. Do not put UWB integration on the critical path for the mesh/gateway MVP.

## Gateway HTTP integration

Use native `URLSession`. The gateway forwards the latest valid position report for each origin to the laptop backend about once per second.

### Example batch

```json
{
  "schemaVersion": 1,
  "gatewayId": "phone-gateway",
  "frameId": "demo-room-v1",
  "units": "m",
  "devices": [
    {
      "id": "phone-4",
      "label": "Moving phone",
      "epochId": "8fa55ddd-0a2b-49a5-9c58-8fc90f66a555",
      "sequence": 42,
      "role": "mobile",
      "position": { "x": 2.1, "y": 1.2, "z": 3.4 },
      "positionMode": "3d",
      "accuracyMeters": 1.5,
      "neighbors": [
        { "id": "anchor-north", "rssi": -61, "ageMs": 300 }
      ]
    }
  ]
}
```

- `POST /api/updates`, `Content-Type: application/json`.
- Preserve origin ID, epoch, sequence, coordinates, and frame through every mesh hop.
- Maximum 100 device entries and 256 KiB per batch. Split pending reports into bounded batches if needed.
- Keep only one HTTP request in flight, with a timeout around three seconds.
- Coalesce pending retries to the latest report per origin; cap the pending store for the demo's device budget.
- Retain the original update identity during retries. A retry must not refresh position age at the receiver.
- On success, remove only pending entries whose identities match the sent batch. Do not delete newer reports that arrived during the request.
- Periodic retransmission of unchanged latest reports may serve as a gateway heartbeat; the backend must still treat them as ignored position updates.
- Retry connection errors and transient server failures with jittered backoff capped at five seconds.
- Surface 400 validation errors and 409 mode/frame conflicts with readable messages; pause the failing batch until configuration or data changes instead of retrying indefinitely.
- Show gateway upload health separately from individual device freshness.

- Hold every report, including relayed ones, to the dashboard's limits before accepting it into the mesh (`DashboardContract` in MeshCore): IDs at most 64 and labels at most 40 UTF-16 code units, coordinates within ±10,000 m, accuracy at most 1,000 m. The dashboard rejects the whole batch if one entry breaks a limit, so a single bad relayed report would otherwise stall the gateway.

### Direct-neighbor reports

The dashboard draws the mesh as a graph and only draws links that phones report. Each phone includes its current direct neighbors in its own position report as `neighbors` (at most 16 entries: peer app device `id`, optional `rssi` in dBm, optional `ageMs` since that peer was last heard directly). Relays forward the list unchanged, like the rest of the report.

A neighbor is a peer with a ready link: subscribed, with a valid Hello carrying its app device ID (see "Wire format, version 2"). It drops out as soon as its last ready link closes. `rssi` is the smoothed connection RSSI where this phone is the central, otherwise the peer's advertisement RSSI. Never derive neighbors from proximity, RSSI alone, or relayed reports.

### Wire format, version 2

Every phone in a demo must run the same version; version 1 phones cannot link to version 2 phones.

- **Frames:** `[type: UInt8][length: UInt32 big-endian][payload]`, with type `1` = Hello and `2` = position packet, at most 4 KiB per payload. Chunks for central-to-peripheral writes fit one ATT write (`maximumWriteValueLength(for: .withoutResponse)`), still written with response.
- **Hello:** `{protocolVersion, frameId, deviceId, label?}`, the first frame in each direction. A link is ready only when subscribed and a valid Hello arrived. A different protocol version or frame closes the link (the central disconnects and waits 60 s).
- **One link per neighbor:** when two phones link both ways, the higher device ID closes its outgoing link, keeping the one initiated by the lower ID. Each packet is sent once per neighbor and never back to the neighbor it came from.
- **Relay path:** `MeshPacket.path` lists the device IDs of the phones that relayed the copy, oldest first. The origin sends `[]`; each relay appends itself; a phone drops a copy whose path already contains it. Paths are self-reported diagnostics, not proof. Each phone records the route of the first copy it accepted.
- **Queues:** each link holds at most one pending packet per origin; a newer report replaces the queued one. A report not refreshed within 30 s is no longer resent or uploaded.

Start with one manually selected gateway. Do not implement gateway election or browser WebSockets in the phone app. Phones other than the gateway do not need Wi-Fi or internet access. With the tunnel URL the gateway needs only an internet connection (Wi-Fi or mobile data), not the laptop's network.

### Time semantics

The receiving app records local monotonic receipt times for its own freshness UI. Preserve source sequences to distinguish new measurements from repeated packets. Do not calculate mesh measurement ages by subtracting unsynchronized device wall clocks. Omit `measurementAgeMs` unless elapsed age is propagated reliably, including relay queue time; backend receipt time is not proof of measurement freshness.

## iOS configuration and lifecycle

- Add `NSBluetoothAlwaysUsageDescription` explaining nearby mesh communication.
- Add `NSLocalNetworkUsageDescription` explaining gateway access to the laptop.
- Configure local development HTTP/ATS behavior for the target iOS version and test numeric LAN URLs on a physical iPhone. Avoid an unrestricted production HTTP exception.
- Bonjour discovery is not needed for the manual-IP MVP; do not add unnecessary discovery permissions or frameworks.
- Handle permission denied, Bluetooth powered off, disconnected neighbors, and unavailable Wi-Fi with explicit status and recovery actions.
- On stop, end discovery/advertising, unsubscribe/disconnect as appropriate, cancel pending transport and upload tasks, and restore screen-idle settings.
- On foreground return, inspect Bluetooth state and rebuild connections; do not assume they survived backgrounding.

## Implementation phases

1. **Native shell:** Xcode app, permissions, device identity, start/stop UI, and manual position source.
2. **Two-phone transport:** discovery, handshake, fragmented bidirectional messages, backpressure, and reconnects.
3. **Three-phone routing:** duplicate cache, hop limits, origin sequence handling, and visible relay diagnostics.
4. **Gateway:** editable LAN URL, health check, batched uploads, latest-only retries, and status UI.
5. **Position integration:** connect real source output only after frame conventions and availability are agreed.
6. **Demo polish:** anchors, named devices, foreground guidance, failure indicators, and repeatable operator setup.

## Acceptance checks

- Two physical iPhones exchange messages in both directions, including messages larger than one GATT payload.
- Three phones deliver A's report through B to C with no ready direct A–C link. Use diagnostics or a test-only excluded-neighbor setting to prove routing; merely placing three phones nearby is not proof of multi-hop radio coverage.
- Message IDs, origin IDs, epochs, and sequences survive relaying unchanged.
- Duplicate packets and lower sequences do not move a device backward or refresh its accepted-report freshness.
- A restarted origin uses a new epoch; delayed packets from retired epochs are ignored for the session.
- Fragment loss, malformed input, slow subscribers, and disconnected peers do not create unbounded memory growth or crash the app.
- Manual and fixed-anchor positions use the same report path as future measured positions.
- With internet disconnected but local Wi-Fi available, the gateway health check and uploads succeed against the laptop.
- While an upload is in flight, newer reports remain pending and are not accidentally acknowledged by the older response.
- Stopping/restarting networking does not leave duplicate upload timers or stale BLE subscriptions running.
- Permission denial, wrong laptop address, firewall/client isolation, and frame conflicts produce actionable status.
- No part of these app changes modifies the independently owned website code.

**Demo outcome:** a foreground iPhone mesh relays clearly identified position reports to a manually selected gateway, which forwards them to the laptop with a small HTTP integration. Position accuracy remains a separate, explicitly described capability.
