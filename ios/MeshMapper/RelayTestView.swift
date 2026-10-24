import MeshCore
import SwiftUI

/// Test console for the Bluetooth relay: send messages, see routes, ages and receipts, exclude
/// phones to force multi-hop, and export the event log as evidence (BLE_MESH_TEST_PROTOCOL.md).
struct RelayTestView: View {
    @ObservedObject var bluetooth: BluetoothMesh
    @ObservedObject private var relay: MeshRelay
    @ObservedObject private var log: MeshEventLog
    let label: String?

    @State private var destination = ""
    @State private var text = ""
    @State private var ttlMinutes = 10
    @State private var hops = 6
    @State private var pings = 0
    @State private var sendError: String?
    @State private var exported: String?
    @State private var beaconHops = 2

    init(bluetooth: BluetoothMesh, label: String? = nil) {
        self.bluetooth = bluetooth
        self.label = label
        relay = bluetooth.relay
        log = bluetooth.eventLog
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                status
                if !bluetooth.blockedDeviceIds.isEmpty {
                    Section {
                        Label("Test filter on: ignoring \(bluetooth.blockedDeviceIds.count) phone(s). Turn it off before the demo.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                links(now: context.date)
                beacon
                compose
                sentSection
                receivedSection(now: context.date)
                filter
                counters
                recordSection
                logSection
            }
        }
        .navigationTitle("Relay test")
    }

    private var status: some View {
        Section {
            LabeledContent("This phone", value: relay.selfId.map(MeshEventLog.short) ?? "–")
            LabeledContent("Relay", value: relay.isRunning ? "running" : "stopped (start the mesh)")
            Text(bluetooth.status).font(.footnote).foregroundStyle(.secondary)
            if let error = bluetooth.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            Text("Foreground only: keep the app open and the screen on. iOS suspends Bluetooth relaying in the background.")
        }
    }

    private func links(now: Date) -> some View {
        Section("Linked now (\(bluetooth.neighbors.count))") {
            if bluetooth.neighbors.isEmpty { Text("No linked phones").foregroundStyle(.secondary) }
            ForEach(bluetooth.neighbors) { neighbor in
                HStack {
                    VStack(alignment: .leading) {
                        Text(relay.name(neighbor.deviceId))
                        Text(MeshEventLog.short(neighbor.deviceId) + (relay.relayNeighbors.contains(neighbor.deviceId) ? " · relay" : " · no relay yet"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("link " + rssi(neighbor.connectionRSSI))
                        Text("adv " + rssi(neighbor.advertisementRSSI))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private var beacon: some View {
        Section {
            Stepper("Beacon hops: \(beaconHops)", value: $beaconHops, in: 1...RelayEnvelope.maxHops)
                .disabled(relay.beaconRun != nil)
            Toggle("Send 1 Hz beacon", isOn: Binding(
                get: { relay.beaconRun != nil },
                set: { $0 ? relay.startBeacon(hops: beaconHops) : relay.stopBeacon() }
            ))
            .disabled(!relay.isRunning)
            if let run = relay.beaconRun {
                LabeledContent("Sending run \(run)", value: "\(relay.beaconsSent) sent")
                    .font(.callout.monospacedDigit())
            }
            ForEach(relay.beaconStats.keys.sorted(), id: \.self) { origin in
                if let stats = relay.beaconStats[origin] { beaconRow(stats) }
            }
            if !relay.beaconStats.isEmpty {
                Button("Reset received statistics") { relay.resetBeaconStats() }
            }
        } header: {
            Text("T3 relay test (AC-3)")
        } footer: {
            Text("Sender: P1. Receiver: P3, with the test filter set so P1 and P3 can't link directly. Pass: at least 95 % received over 120 beacons, route = the middle phone only, median age at most 3 s, no duplicates.")
        }
    }

    private func beaconRow(_ stats: BeaconStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("From \(relay.name(stats.originId)) · run \(stats.run)")
            Text("received \(stats.received) of \(stats.expected) (\(percent(stats.deliveryRatio))) · seq \(stats.firstSequence ?? 0)–\(stats.lastSequence ?? 0)")
            Text("median age \(stats.medianAgeMs.map(seconds) ?? "–") · p95 \(stats.ageMs(percentile: 95).map(seconds) ?? "–") · max \(stats.agesMs.max().map(seconds) ?? "–")")
            ForEach(stats.routes.keys.sorted(), id: \.self) { key in
                let relays = key.isEmpty ? "direct" : key.components(separatedBy: " > ").map(relay.name).joined(separator: " → ")
                Text("via \(relays): \(stats.routes[key] ?? 0)")
            }
            Text("duplicates delivered: \(stats.duplicates)")
                .foregroundStyle(stats.duplicates == 0 ? Color.secondary : Color.red)
        }
        .font(.caption.monospacedDigit())
    }

    private var compose: some View {
        Section {
            Picker("To", selection: $destination) {
                Text("Everyone (broadcast)").tag("")
                ForEach(peerIds, id: \.self) { id in Text(relay.name(id)).tag(id) }
            }
            TextField("Message", text: $text)
            Stepper("Hops: \(hops)", value: $hops, in: 0...RelayEnvelope.maxHops)
            Picker("TTL", selection: $ttlMinutes) {
                ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            Button("Send") {
                sendError = relay.send(body: text.isEmpty ? "test" : text, to: destination.isEmpty ? nil : destination,
                                       ttlMs: ttlMinutes * 60_000, hops: hops)
                if sendError == nil { text = "" }
            }
            .disabled(!relay.isRunning)
            Button("Ping") {
                pings += 1
                sendError = relay.send(kind: "ping", body: "ping \(pings) from \(label ?? "phone")",
                                       to: destination.isEmpty ? nil : destination, ttlMs: ttlMinutes * 60_000, hops: hops)
            }
            .disabled(!relay.isRunning)
            if let sendError { Text(sendError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Send")
        } footer: {
            Text("A message for one phone is carried by every phone that hears it until it is delivered (receipt), expires (TTL) or runs out of hops. 0 hops reaches direct neighbors only.")
        }
    }

    private var sentSection: some View {
        Section("Sent (\(relay.sent.count))") {
            ForEach(relay.sent.prefix(20)) { message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.envelope.body).lineLimit(2)
                    Text("\(MeshEventLog.short(message.id.uuidString)) · to \(message.envelope.destinationId.map(relay.name) ?? "everyone") · \(message.sentAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(deliveryStatus(message)).font(.caption)
                        .foregroundStyle(message.receipt == nil ? Color.secondary : Color.green)
                }
            }
        }
    }

    private func receivedSection(now: Date) -> some View {
        Section("Received (\(relay.received.count))") {
            ForEach(relay.received.prefix(30)) { message in
                let envelope = message.delivery.envelope
                VStack(alignment: .leading, spacing: 2) {
                    Text(envelope.body).lineLimit(3)
                    Text(relay.route(envelope)).font(.caption)
                    Text("\(message.delivery.hops) hop(s) · age ≥ \(seconds(envelope.ageMs)) · \(envelope.hopsRemaining) hops left · \(MeshEventLog.short(envelope.messageId.uuidString))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("arrived \(message.arrivedAt.formatted(date: .omitted, time: .standard))" + originClock(envelope))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filter: some View {
        Section {
            if peerIds.isEmpty { Text("No other phones seen yet").foregroundStyle(.secondary) }
            ForEach(peerIds, id: \.self) { id in
                Toggle("Ignore \(relay.name(id))", isOn: Binding(
                    get: { bluetooth.blockedDeviceIds.contains(id) },
                    set: { blocked in
                        if blocked { bluetooth.blockedDeviceIds.insert(id) } else { bluetooth.blockedDeviceIds.remove(id) }
                    }
                ))
            }
        } header: {
            Text("Test filter (A–B–C)")
        } footer: {
            Text("Refuses Bluetooth links to the chosen phones so a message must hop through another phone. Set it on both phones of the pair. Cleared when the app restarts.")
        }
    }

    private var counters: some View {
        let s = relay.statistics
        return Section("Counters") {
            LabeledContent("Originated / accepted", value: "\(s.originated) / \(s.accepted)")
            LabeledContent("Delivered here", value: "\(s.delivered)")
            LabeledContent("Copies sent", value: "\(s.sent)")
            LabeledContent("Duplicates / loops", value: "\(s.duplicates) / \(s.loops)")
            LabeledContent("Expired / hop-limited", value: "\(s.expired) / \(s.hopLimited)")
            LabeledContent("Stored now / evicted / cleared", value: "\(relay.storedCount) / \(s.evicted) / \(s.cleared)")
            LabeledContent("Invalid", value: "\(s.invalid)")
        }
        .font(.callout.monospacedDigit())
    }

    private var recordSection: some View {
        let s = relay.recordStatistics
        return Section {
            LabeledContent("Published / accepted", value: "\(s.published) / \(s.accepted)")
            LabeledContent("Copies sent", value: "\(s.sent)")
            LabeledContent("Duplicates / loops", value: "\(s.duplicates) / \(s.loops)")
            LabeledContent("Out of order / stale / expired", value: "\(s.outOfOrder) / \(s.stale) / \(s.expired)")
            LabeledContent("Invalid", value: "\(s.invalid)")
            ForEach(relay.recordRoutes.keys.sorted(), id: \.self) { origin in
                let path = relay.recordRoutes[origin] ?? []
                Text("\(relay.name(origin)): " + (path.isEmpty ? "direct" : "via " + path.map(relay.name).joined(separator: " → ")))
                    .font(.caption)
            }
        } header: {
            Text("GhostCore records")
        } footer: {
            Text("Positions, GNSS assessments and predictions from the pipeline (frame type 7).")
        }
        .font(.callout.monospacedDigit())
    }

    private var logSection: some View {
        Section {
            ForEach(log.recent.reversed()) { entry in
                VStack(alignment: .leading) {
                    Text(entry.detail).font(.caption)
                    Text("\(entry.wallClock.formatted(date: .omitted, time: .standard)) · \(entry.category)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Button("Prepare log for sharing") { exported = log.export(deviceId: relay.selfId, label: label) }
            if let exported {
                ShareLink("Share log (\(log.entries.count) events)", item: exported)
            }
            Button("Clear log", role: .destructive) {
                log.clear()
                exported = nil
            }
        } header: {
            Text("Event log")
        } footer: {
            Text("Export after every hardware test and attach it to the results table.")
        }
    }

    // MARK: Formatting

    private var peerIds: [String] {
        relay.knownPeers.keys.sorted { relay.name($0) < relay.name($1) }
    }

    private func deliveryStatus(_ message: MeshRelay.SentMessage) -> String {
        guard message.envelope.destinationId != nil else { return "Broadcast: no receipts" }
        guard let receipt = message.receipt else { return "Waiting for a receipt" }
        let info = RelayReceiptInfo.decode(body: receipt.envelope.body)
        let route = info.map { ([relay.selfId ?? ""] + $0.path + [receipt.envelope.originId]).map(relay.name).joined(separator: " → ") } ?? "?"
        return "Delivered: \(route), age ≥ \(info.map { seconds($0.ageMs) } ?? "?")"
    }

    private func originClock(_ envelope: RelayEnvelope) -> String {
        guard let createdAt = envelope.createdAt else { return "" }
        let date = Date(timeIntervalSince1970: createdAt / 1000)
        return " · origin clock \(date.formatted(date: .omitted, time: .standard)) (not synced)"
    }

    private func percent(_ ratio: Double?) -> String {
        ratio.map { String(format: "%.1f %%", $0 * 100) } ?? "–"
    }

    private func seconds(_ ms: Int) -> String {
        String(format: "%.1f s", Double(ms) / 1000)
    }

    private func rssi(_ statistics: RSSIStatistics?) -> String {
        guard let statistics, let smoothed = statistics.smoothed else { return "–" }
        let deviation = statistics.standardDeviation.map { String(format: " ±%.0f", $0) } ?? ""
        return String(format: "%.0f dBm", smoothed) + deviation
    }
}
