# Bluetooth mesh mapping: review, issues and fixes

Review of the Bluetooth layer of MeshMapper (`ios/`), checked against [app.md](app.md). The goal of the project is a **Bluetooth mesh mapping** system: iPhones form a Bluetooth LE mesh, relay each phone's position to a gateway, and the laptop draws them on a 3D map, with no GNSS and no internet.

Line numbers refer to the code as reviewed on 2026-10-24 and will drift as fixes land. This is a code-reading review: nothing was run on a phone, so every fix must be verified on physical iPhones (see [Verification](#verification)).

## What the mesh must deliver for mapping

| Mapping need | What it requires from Bluetooth | Today |
|---|---|---|
| **M1. Every phone appears on the map** | Links stay up and every report reaches the gateway | At risk: links may drop on every message (issue 1); one bad report blocks all uploads (issue 2) |
| **M2. Positions on the map are current** | Reports reach the gateway within seconds | At risk: queues can hold tens of seconds of old positions that then look fresh (issue 3) |
| **M3. The map can show the mesh itself** | Know which phone is linked to which, and the signal on each link | Missing: neighbours are known only by Bluetooth identifiers that can't be matched to devices (issues 4, 6, 7) |
| **M4. Each report can be traced back to its origin** | Record the phones a report travelled through | Partial: the origin is known, the relay count is estimated, the route is not recorded (issue 8) |
| **M5. The map is honest** | Manual, anchor and RSSI-derived data are never shown as measured positions | Done in the app UI; must be kept as new data types are added |

The positions themselves come from manual entry, fixed anchors, or the team's positioning component. Bluetooth carries them; it does not measure them. Signal strength (RSSI) is useful for drawing and diagnosing the mesh, but per [app.md](app.md) it must not be turned into map coordinates.

## Summary

| # | Issue | Mapping need | Severity | Effort | Changes the wire format |
|---|---|---|---|---|---|
| 1 | Chunk size can trigger rejected long writes, causing a disconnect loop | M1 | High (verify first) | Small | No |
| 2 | Mesh accepts reports the dashboard rejects; one bad report blocks all uploads | M1 | High | Small | No |
| 3 | Traffic multiplies and queues never coalesce, so positions arrive late but look fresh | M2 | High | Medium | No |
| 4 | No handshake: duplicate links, unknown neighbours | M2, M3 | Medium | Medium | Yes |
| 5 | Connection lifecycle gaps: no timeouts, leaked connects, reconnect loops | M1 | Medium | Small | No |
| 6 | RSSI can't be tied to a mesh device or used for the mesh map | M3 | Medium | Medium | No |
| 7 | Feature: neighbour reports, so the map can draw the mesh links | M3 | Feature | Medium | Yes |
| 8 | Feature: record the relay path back to the origin phone | M4 | Feature | Medium | Yes |
| 9 | Smaller issues: departed devices never expire, repeated advertising, stale UI | M1, M2 | Low | Small | No |

**Recommended order:** 1 → 2 → 5 → 3 (positions reliably reach the map), then 4 → 8 → 7 → 6 (the mesh itself on the map), then 9.

Fixes 1, 2, 3 and 5 are local and can ship one at a time. Fixes 4, 7 and 8 change the wire format, so every phone must be updated together. Bundle them into one protocol version 2 release.

What already works well and should be kept:

- `MeshStore` epoch and sequence handling is correct and well tested, so a phone on the map never jumps back to an older position.
- Hop counts are never refreshed when cached reports are resent.
- A full send queue drops whole messages, never single chunks, so the sender never corrupts the receiver's framing.
- Notification backpressure (`updateValue` returning false, resuming from `peripheralManagerIsReady`) follows Apple's model.
- Manual coordinates and assumed height are clearly labelled in the UI.

---

# Part A: Getting positions onto the map

## 1. Chunk size can trigger rejected long writes

**Mapping impact:** links between phones may fail on every message, so reports don't reach the gateway and phones disappear from the map.

**Where:** [BluetoothMesh.swift:238](ios/MeshMapper/BluetoothMesh.swift#L238), [:220-231](ios/MeshMapper/BluetoothMesh.swift#L220-L231), [:269-273](ios/MeshMapper/BluetoothMesh.swift#L269-L273)

**Problem.** Chunks for central-to-peripheral writes are sized with `maximumWriteValueLength(for: .withResponse)`. On iOS that value is usually 512 regardless of the negotiated ATT MTU, because Core Bluetooth turns a larger write into a long (prepared) write. If two phones negotiate a smaller MTU, for example 185, each 512-byte chunk is sent as several prepared-write requests with non-zero offsets. Then:

1. The peripheral rejects every request with `offset != 0` (`.unlikelyError`).
2. The central gets a write error and cancels the connection.
3. The link reconnects after 5 s and fails again on the next message.

A position packet is about 300 to 400 bytes, so with a small MTU nearly every message would hit this.

The write handler also calls `respond(to:withResult:)` once per request. Apple's contract is to respond exactly once per callback, passing the first request, and to fail the whole batch if any request fails.

**Fix.** Size chunks so a single ATT write always fits, while still writing with response:

```swift
// broadcast(_:)
let chunks = split(framed, size: remote.maximumWriteValueLength(for: .withoutResponse))
```

Validate the whole batch first, then respond once:

```swift
func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    let valid = running && requests.allSatisfy { request in
        request.characteristic.uuid == Self.characteristicID && request.offset == 0 &&
            request.value != nil && subscribers[request.central.identifier] != nil
    }
    guard valid else { peripheral.respond(to: first, withResult: .unlikelyError); return }
    for request in requests {
        receive(request.value ?? Data(), from: "w:\(request.central.identifier)")
    }
    peripheral.respond(to: first, withResult: .success)
}
```

**Verify.** Log `maximumWriteValueLength(for:)` for both write types on each phone pair. Send a message of at least 1 KiB in both directions and confirm the link stays up and the Rejected counter stays at 0.

---

## 2. One bad report blocks the whole map

**Mapping impact:** a single phone with an out-of-range value stops **every** phone from reaching the dashboard.

**Where:** [Models.swift:54-67](ios/MeshCore/Sources/MeshCore/Models.swift#L54-L67), [GatewayClient.swift:86-108](ios/MeshMapper/GatewayClient.swift#L86-L108), [website/server/validate.ts](website/server/validate.ts)

**Problem.** `DeviceUpdate.validate()` accepts values that `validate.ts` rejects with HTTP 400:

| Field | Mesh accepts | Dashboard accepts |
|---|---|---|
| `id` | up to 128 UTF-8 bytes | up to 64 characters (UTF-16 units), non-blank after trim |
| `label` | up to 128 UTF-8 bytes | up to 40 characters (UTF-16 units) |
| `position` | any finite value | within ±10 000 m |
| `accuracyMeters` | any finite value ≥ 0 | 0 to 1000 |

The gateway sends all pending devices in one batch, so one invalid device makes the whole batch fail. The invalid phone keeps publishing new sequences, so each new batch differs from `rejectedBody` and is retried and rejected every second. No position reaches the map while the bad report stays pending.

This can be triggered from the app's own UI:

- Set **Accuracy (m)** to 5000. `publish` checks coordinates but not accuracy.
- Use a label with emoji. `MeshModel` limits the label to 40 Swift `Character`s, but JavaScript counts most emoji as 2, so 25 emoji plus 15 letters is 40 for Swift and 65 for the dashboard.

**Fix.**

1. Make `DeviceUpdate.validate()` enforce the dashboard limits, counting text in UTF-16 units to match JavaScript:

   ```swift
   guard !id.trimmingCharacters(in: .whitespaces).isEmpty, id.utf16.count <= 64,
         label.map({ $0.utf16.count <= 40 }) ?? true,
         [position.x, position.y, position.z].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }),
         accuracyMeters.map({ $0.isFinite && $0 >= 0 && $0 <= 1000 }) ?? true,
         // ...existing epoch, sequence, role and mode checks
   ```

   Reports from older builds are then rejected at the first phone instead of blocking the gateway.

2. Truncate the label in `MeshModel` by UTF-16 length without splitting a character:

   ```swift
   didSet {
       var value = label
       while value.utf16.count > Self.maxLabelLength { value.removeLast() }
       if value != label { label = value }
       UserDefaults.standard.set(label, forKey: "deviceLabel")
   }
   ```

3. Update `testUpdateValidation` in [MeshCoreTests.swift](ios/MeshCore/Tests/MeshCoreTests/MeshCoreTests.swift). It currently treats 128-character ids and labels as valid. Add cases for coordinates of ±10 000.001, accuracy of 1000.1, and an emoji label over 40 UTF-16 units.

4. Optional hardening in `GatewayClient`: after a 400, upload devices individually once to find the offender, keep it paused, and continue uploading the rest.

---

## 3. Positions arrive late but look fresh

**Mapping impact:** the map shows phones where they were tens of seconds ago, and nothing indicates the delay.

**Where:** [BluetoothMesh.swift:233-252](ios/MeshMapper/BluetoothMesh.swift#L233-L252), [MeshModel.swift:84](ios/MeshMapper/MeshModel.swift#L84), [MeshModel.swift:215-220](ios/MeshMapper/MeshModel.swift#L215-L220)

**Problem.** Four things combine:

- **Double links.** Each pair of phones connects in both directions, and `broadcast` sends over both, so every neighbour receives every packet twice.
- **Echo.** A relayed packet is also sent back to the neighbour it came from.
- **Sync floods every link.** When a new link comes up, `sync()` resends every cached report to every link, not just the new one. Both ends trigger this.
- **FIFO queues without coalescing.** Each link queues up to 1024 chunks in order. If a link falls behind, it delivers old positions in order before new ones. The receiver stamps them with the arrival time, so a report that waited in a queue looks fresh. [app.md](app.md) asks for coalescing per origin.

For mapping, only the **latest** position of each phone matters. Anything older that is still queued is wasted airtime.

**Fix.**

**3a. Coalescing outbox per link.** Keep at most one pending message per origin, plus the transfer already in progress, which is never interrupted. Put it in MeshCore so it can be unit tested:

```swift
// ios/MeshCore/Sources/MeshCore/LinkOutbox.swift
public struct LinkOutbox {
    // The transfer in progress. Never dropped part-way, so receiver framing stays intact.
    public private(set) var chunks: [Data] = []
    private var pending: [String: Data] = [:]
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { chunks.isEmpty && order.isEmpty }

    // A newer message for the same key replaces the queued one and keeps its place in line.
    public mutating func enqueue(_ framed: Data, key: String) {
        if pending.updateValue(framed, forKey: key) == nil { order.append(key) }
    }

    public mutating func nextChunk(maxLength: Int) -> Data? {
        if chunks.isEmpty, !order.isEmpty, let framed = pending.removeValue(forKey: order.removeFirst()) {
            let size = max(1, maxLength)
            chunks = stride(from: 0, to: framed.count, by: size).map {
                framed.subdata(in: $0..<min($0 + size, framed.count))
            }
        }
        return chunks.first
    }

    public mutating func chunkSent() {
        if !chunks.isEmpty { chunks.removeFirst() }
    }
}
```

Replace `writeQueues` and `notifyQueues` with `[UUID: LinkOutbox]`. Change `broadcast(_ payload: Data)` to `broadcast(_ payload: Data, key: String)`. From `MeshModel`, pass `"position:" + packet.update.id` as the key. Neighbour reports (issue 7) use `"neighbors:" + originId`, so the two kinds never replace each other. The queue is then bounded by the number of known devices instead of 1024 chunks.

**3b. Sync only the new link.** Change `onLinkReady: (() -> Void)?` to pass the link, and add a targeted send:

```swift
var onLinkReady: ((LinkID) -> Void)?
func send(_ payload: Data, key: String, to link: LinkID)
```

where `LinkID` is either a peripheral identifier (outgoing link) or a central identifier (incoming link). The 5-second periodic `sync()` can stay as is.

**3c. Don't echo.** Have `onPacket` report which link a packet arrived on, and skip that link when relaying it. The second, duplicate link is removed by issue 4.

**3d. Optional: random forwarding delay.** Wait a random 0 to 100 ms before relaying, so neighbours that received the same packet don't all transmit at once.

**Tests for `LinkOutbox`:** a newer message replaces an older one with the same key; an in-progress transfer finishes before the replacement starts; ordering across keys is first-in-first-out; chunk sizes respect `maxLength`.

---

## 5. Connection lifecycle gaps

**Mapping impact:** phones that move around the room (the normal case for mapping) can end up with stuck or looping connections, so they drop off the map until the app is restarted.

**Where:** [BluetoothMesh.swift:130-151](ios/MeshMapper/BluetoothMesh.swift#L130-L151), [:180-186](ios/MeshMapper/BluetoothMesh.swift#L180-L186), [:207-211](ios/MeshMapper/BluetoothMesh.swift#L207-L211), [:308-320](ios/MeshMapper/BluetoothMesh.swift#L308-L320)

| Problem | Fix |
|---|---|
| `central.connect` has no timeout, so a connection to a phone that walked away stays pending forever. | Record the connect start time. In `tick()`, cancel the connection if it isn't ready within 10 s; this covers connect, discovery, subscription and handshake. |
| `tick()` drops `peripherals[id]` after 30 s without cancelling a pending connection. Core Bluetooth needs the `CBPeripheral` to stay referenced, so the attempt is leaked. | Call `central.cancelPeripheralConnection(peripheral)` before removing it. |
| `connected = true` is set in `didConnect`, before the service, characteristic and subscription exist. | Replace the `Bool` with a state: `discovered`, `connecting`, `linking`, `ready`. Count only `ready` as connected. |
| If the characteristic is missing or lacks `.write`/`.notify`, the code returns without disconnecting, and the link holds a slot forever. | Cancel the connection and back off for 60 s. |
| Subscribers beyond 8 are not registered, so their writes fail, they disconnect, and they retry every 5 s forever. | Use exponential backoff with jitter for failed links: 5, 10, 20, 40, then a 60 s cap, plus a random 0 to 2 s. Reset after a link has been ready for 30 s. Long term, enforce one neighbour limit through the handshake (issue 4) rather than separate central and subscriber caps. |
| `didUpdateNotificationStateFor` ignores the case where notifications turn off. | If `isNotifying` is false, treat the link as not ready and cancel it. |

---

# Part B: Mapping the mesh itself

Issues 4, 6, 7 and 8 together let the map show not just where each phone is, but **how the mesh is connected**: which phones are linked, how strong each link is, and which route each report took to the gateway.

## 4. Add a link handshake

**Mapping impact:** without it, a phone doesn't know which mesh device is on the other end of each link, so links can't be drawn on the map, duplicate links waste airtime, and RSSI can't be attributed to a device.

**Where:** [BluetoothMesh.swift](ios/MeshMapper/BluetoothMesh.swift). Specified in [app.md](app.md) under "Link setup", but not implemented.

**Problem.** Core Bluetooth identifies the other phone only by an identifier that differs on each observing phone and changes as iOS rotates private addresses. The app device ID, which is what the map uses, is never exchanged.

**Fix.**

**4a. Add a message type to the framing.** Add one type byte before the length:

```
[type: UInt8][length: UInt32 big-endian][payload]
0x01 = hello, 0x02 = position packet, 0x03 = neighbour report (issue 7)
```

Update `receive(_:from:)` to read 5 header bytes and route by type. Reject unknown types like an invalid frame.

**4b. Hello message.**

```swift
public struct Hello: Codable {
    public let protocolVersion: Int   // 2 once this ships
    public let frameId: String
    public let deviceId: String
    public let label: String?
}
```

- **Central side:** send Hello as the first write once `isNotifying` becomes true.
- **Peripheral side:** send Hello as the first notification after `didSubscribeTo`.
- A link is **ready** only when the subscription is active and a valid Hello has been received from the other side. `broadcast` skips links that aren't ready.
- On a protocol or frame mismatch, the central cancels the connection and backs off for 60 s. The peripheral can't disconnect a central, so it sends its own Hello; the central sees the mismatch and disconnects. Phones mapping a different room (different `frameId`) never join the same mesh.

**4c. Neighbour table and canonical link.** Track logical neighbours by device ID, each with up to two physical links:

```swift
struct Neighbor {
    let deviceId: String
    var label: String?
    var outgoing: UUID?   // we are central; CBPeripheral identifier
    var incoming: UUID?   // we are peripheral; CBCentral identifier
    var rssi = RSSIStatistics()
    var preferred: LinkID? { ... }
}
private var neighbors: [String: Neighbor] = [:]    // key: app device ID
private var peripheralDevice: [UUID: String] = [:] // learned from Hello, used to skip reconnects
```

Rule from [app.md](app.md): keep the connection initiated by the **lower** device ID.

- Send each message once per neighbour, over its preferred link. This removes duplicate delivery immediately, even while both links exist.
- If my ID is higher and the canonical (incoming) link is ready, cancel my outgoing connection to that neighbour.
- In `didDiscover`, don't connect to a peripheral whose learned device ID already has a ready neighbour entry.
- If the canonical link drops, clear the entry so the other side may reconnect.

**4d. UI.** Show neighbours by label and short device ID, matching the Known devices list, with link state and RSSI. Use the Bluetooth identifier only for debugging.

---

## 6. RSSI for the mesh map

**Mapping impact:** link strength is the natural weight for edges on a mesh map, but today it can't be tied to a device and the values are inconsistent.

**Where:** [BluetoothMesh.swift:130-137](ios/MeshMapper/BluetoothMesh.swift#L130-L137), [:193-200](ios/MeshMapper/BluetoothMesh.swift#L193-L200), [RSSIStatistics.swift](ios/MeshCore/Sources/MeshCore/RSSIStatistics.swift)

**Problem.**

- RSSI is keyed by the Bluetooth identifier, so readings can't be attributed to a mesh device.
- Advertisement RSSI (advertising channels, irregular rate) and connection RSSI (data channels, 1 Hz `readRSSI`) are mixed into one average. They are measured differently and are not interchangeable.
- The smoothing factor of 0.25 is applied per sample, but samples arrive at an uneven rate, so the effective smoothing window keeps changing.
- `standardDeviation` is calculated but never shown.
- Nothing leaves the phone, so the map can't use it.

**Fix.**

1. After the handshake, store RSSI in the `Neighbor` entry, keyed by app device ID.
2. Keep two separate statistics per neighbour: `advertisementRSSI` and `connectionRSSI`. Use connection RSSI from `readRSSI` for link strength, since it is sampled at a steady 1 Hz. Use advertisement RSSI only for phones seen but not connected.
3. Make the smoothing time-based: `alpha = 1 - exp(-dt / tau)` with, for example, `tau = 3 s`, where `dt` is the time since the previous sample.
4. Show the standard deviation and sample count next to the smoothed value, so readers can see how noisy it is.
5. Send it to the map as link data in neighbour reports (issue 7), never as a position. RSSI depends heavily on body position, phone model and surroundings; it shows link quality, not distance.

---

## 7. Feature: neighbour reports, so the map can draw the mesh

**Mapping impact:** the map can draw every Bluetooth link between phones, coloured by signal strength, and show which phones are isolated or acting as bridges.

**Goal.** Every phone, and therefore the gateway, learns the full link graph of the mesh.

**Design.** Each phone floods a small neighbour report every 5 s through the same mesh as positions (same hop limit, deduplication by origin, epoch and sequence, and coalescing by `"neighbors:" + originId`):

```swift
public struct NeighborReport: Codable {
    public let originId: String
    public let epochId: String
    public let sequence: Int
    public let neighbors: [NeighborLink]
}

public struct NeighborLink: Codable {
    public let deviceId: String
    public let rssi: Int?        // smoothed connection RSSI, rounded; nil if unknown
}
```

1. **MeshCore:** add `NeighborReport` with validation (at most 8 neighbours, IDs 1 to 64 characters, no repeats, RSSI within -127 to 20). Store the latest report per origin with the same epoch and sequence rules as positions. Reuse the `MeshStore` logic or generalise it; don't duplicate it.
2. **BluetoothMesh:** list only neighbours whose link is **ready** (after handshake), using the RSSI from issue 6.
3. **MeshModel:** publish the report every 5 s and whenever a link becomes ready or drops.
4. **App UI:** in the Network tab, show the link list (A ↔ B, −62 dBm). A simple graph drawing is optional.
5. **Dashboard:** this needs a new upload field or endpoint agreed with the website owners, for example a `links` array in the batch. The dashboard can then draw edges between device markers. Per [CLAUDE.md](CLAUDE.md), app work must not modify `website/`, so agree the contract first and add it to [WEBSITE_PLAN.md](WEBSITE_PLAN.md).

**Size:** 8 neighbours with UUID IDs is about 500 bytes of JSON every 5 s per phone. With coalescing (issue 3) only the latest report per phone is ever queued.

**Honesty:** the edges show which phones can talk to each other, not where they are. Two phones far apart can have a strong link in open space, and two nearby phones a weak one through a body or wall.

---

## 8. Feature: record the relay path

**Mapping impact:** the map can trace each report back to its origin phone through the mesh, showing which phones carried it to the gateway.

**What exists today.** The origin is already known: `update.id` is the originating phone and is preserved across relays. The relay count is only inferred as `originHops - 1 - hopsRemaining` ([ContentView.swift:113](ios/MeshMapper/ContentView.swift#L113)), which is wrong whenever phones run builds with different `originHops`, and gives no phone IDs.

**Fix.** Add a `path` to the position packet that each relay appends to:

```
A publishes:  path = []
B relays:     path = [B]
C relays:     path = [B, C]
Gateway D:    origin A, via B → C, 2 relays
```

1. **[Models.swift](ios/MeshCore/Sources/MeshCore/Models.swift):** add `public let path: [String]` to `MeshPacket` and bump `schemaVersion` to 2. In `validate()`, require at most 8 entries, each 1 to 64 characters, with no repeats and not equal to `update.id`. This is the mesh packet version only; the dashboard upload `schemaVersion` is separate and stays 1.
2. **[MeshStore.swift](ios/MeshCore/Sources/MeshCore/MeshStore.swift):** pass this phone's device ID to `init`. In `ingest`, build the relay copy with `path: packet.path + [selfId]` only for packets received from others, not for this phone's own publications. Cached relays are resent unchanged by `sync()`, so the path never grows on resend.
3. **Loop protection:** drop a received packet whose `path` already contains this phone's ID.
4. **[MeshModel.swift](ios/MeshMapper/MeshModel.swift):** store `path` in `KnownDevice` instead of `hopsRemaining`.
5. **[ContentView.swift](ios/MeshMapper/ContentView.swift):** show "Direct" for an empty path, otherwise "via B → C", using labels where known and short IDs otherwise.
6. **Tests:** the path grows by one per hop; resending a cached relay doesn't change it; a packet containing this phone's ID is dropped; invalid paths are rejected.
7. **Dashboard:** the dashboard ignores unknown fields, so uploads keep working, but it won't store or draw the path. Drawing the route on the map needs a contract change agreed with the website owners, the same as issue 7.

**Limits to communicate:**

- Each phone records the route of the first copy it accepted. Different phones may record different routes for the same report, and the route can change every second.
- The path is self-reported by each relay. It is good for diagnostics, not proof.
- Full UUIDs add about 37 bytes per hop. If packet size matters after issue 3, use a shorter per-phone ID in the path.

---

# Part C: Smaller issues

## 9. Smaller issues

| Issue | Mapping impact | Where | Fix |
|---|---|---|---|
| Devices that leave are never forgotten. Their reports are resent every 5 s by `sync()` and re-uploaded every second by the gateway heartbeat. | Departed phones keep using airtime; new phones joining receive old positions. | [MeshStore.swift](ios/MeshCore/Sources/MeshCore/MeshStore.swift), [MeshModel.swift:171-179](ios/MeshMapper/MeshModel.swift#L171-L179) | Record a local receive time per origin. Stop resending and uploading reports not refreshed within, for example, 30 s. Keep the epoch history so retired epochs stay retired. |
| "First copy wins": if a report arrives first via a long route with few hops left, a later copy with more hops is discarded. | Reports may not reach far corners of the mesh. | [MeshStore.swift:34](ios/MeshCore/Sources/MeshCore/MeshStore.swift#L34) | Optional: if the same sequence arrives with more hops remaining than the cached relay, update the cached relay and forward it once more. |
| Returning to the foreground calls `startAdvertising` again while already advertising, which can surface an error. | Misleading error in the UI. | [BluetoothMesh.swift:75-76](ios/MeshMapper/BluetoothMesh.swift#L75-L76) | Check `peripheralManager.isAdvertising` first. |
| The Neighbours list keeps showing peers after Stop. | Misleading mesh state. | [BluetoothMesh.swift:53-66](ios/MeshMapper/BluetoothMesh.swift#L53-L66) | Clear `peers`, `peripherals` and `retryAfter` in `stop()`. |
| The framing and reassembly code has no tests. | Transport bugs are only found on phones. | [BluetoothMesh.swift:254-306](ios/MeshMapper/BluetoothMesh.swift#L254-L306) | Move framing and reassembly into MeshCore as a pure `FrameAssembler`, and test split frames, several frames in one chunk, invalid lengths, oversize buffers and timeouts. |
| There is no authentication; any phone running the app can inject positions. | Anyone nearby with the app could add fake phones to the map. | Whole protocol | Acceptable for the demo. State it in the presentation. |

---

## Verification

Run `swift test` in `ios/MeshCore` after every MeshCore change. Then check on physical iPhones, building on the acceptance checks in [app.md](app.md):

1. **Two phones:** messages of at least 1 KiB in both directions; the link stays up for 10 minutes; the Rejected counter stays at 0.
2. **Bad report (after issue 2):** set accuracy to 5000 on one phone. That phone shows a local error, and the gateway keeps putting all other phones on the map.
3. **Freshness (after issue 3):** six phones publishing every second for 5 minutes. Move one phone's manual coordinates; the map updates within a few seconds every time.
4. **Duplicate links (after issue 4):** each phone pair keeps one link, and the Neighbours list shows labels that match Known devices.
5. **Multi-hop (after issue 8):** three phones in a line, A–B–C, with no direct A–C link (use distance or a test-only excluded-neighbour setting). A's report reaches C with path `[B]`.
6. **Mesh map (after issue 7):** every phone and the gateway show the same set of links within 10 s of a link forming or dropping.
7. **Movement:** walk one phone out of range and back. It reconnects within the backoff window, reappears on the map, and no pending connections or stale neighbours accumulate.
8. **Stop and restart:** no duplicate timers, no stale subscriptions, and the Neighbours list is empty after Stop.
