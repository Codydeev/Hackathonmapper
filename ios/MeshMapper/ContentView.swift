import MeshCore
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        TabView {
            NetworkView(bluetooth: model.bluetooth)
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
            PositionView()
                .tabItem { Label("Position", systemImage: "location") }
            GatewayView(gateway: model.gateway)
                .tabItem { Label("Gateway", systemImage: "arrow.up.to.line") }
        }
    }
}

func shortID(_ id: String) -> String { String(id.prefix(8)) }

func ageText(since date: Date?, now: Date) -> String {
    guard let date else { return "never" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
}

@MainActor
struct NetworkView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var bluetooth: BluetoothMesh

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    Section {
                        TextField("Label", text: $model.label)
                        LabeledContent("Device ID", value: shortID(model.deviceID))
                        TextField("Frame ID", text: $model.frameID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(model.isRunning)
                        Toggle("Mesh running", isOn: Binding(
                            get: { model.isRunning },
                            set: { $0 ? model.start() : model.stop() }
                        ))
                        Toggle("Keep screen awake", isOn: $model.keepAwake)
                        Text(bluetooth.status).font(.footnote).foregroundStyle(.secondary)
                        if let error = model.lastError ?? bluetooth.lastError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("This phone")
                    } footer: {
                        if model.isRunning {
                            Label("Demo mode: keep this app in the foreground. Relaying stops when the phone is locked or the app is backgrounded.",
                                  systemImage: "exclamationmark.triangle")
                        }
                    }

                    Section {
                        if bluetooth.neighbors.isEmpty { Text("No linked mapping phones").foregroundStyle(.secondary) }
                        ForEach(bluetooth.neighbors) { neighbor in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(neighbor.label ?? shortID(neighbor.deviceId))
                                    Text("\(shortID(neighbor.deviceId)) · \(linkDirection(neighbor))")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("Link " + rssiText(neighbor.connectionRSSI))
                                    Text("Adv " + rssiText(neighbor.advertisementRSSI))
                                    Text("heard " + ageText(since: neighbor.lastHeard, now: context.date))
                                }
                                .font(.caption)
                            }
                        }
                        DisclosureGroup("Bluetooth radios seen (\(bluetooth.peers.count))") {
                            ForEach(bluetooth.peers.values.sorted { $0.lastSeen > $1.lastSeen }) { peer in
                                HStack {
                                    Text(shortID(peer.id.uuidString)).font(.caption.monospaced())
                                    Spacer()
                                    Text("\(rssiText(peer.rssi)) · \(ageText(since: peer.lastSeen, now: context.date))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.footnote)
                    } header: {
                        Text("Neighbors (\(bluetooth.neighbors.count) linked, \(bluetooth.pendingLinks) connecting)")
                    } footer: {
                        Text("RSSI shows link quality (smoothed ± deviation, samples), not distance. Bluetooth radio identifiers are for debugging only.")
                    }

                    Section {
                        if model.directNeighbors.isEmpty { Text("No ready links yet").foregroundStyle(.secondary) }
                        ForEach(model.directNeighbors, id: \.id) { neighbor in
                            HStack {
                                Text(model.devices.first { $0.id == neighbor.id }?.update.label ?? shortID(neighbor.id))
                                Spacer()
                                Text(neighbor.rssi.map { "\($0) dBm" } ?? "RSSI unknown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Direct links reported (\(model.directNeighbors.count))")
                    } footer: {
                        Text("Sent with this phone's position so the dashboard can draw the mesh. Only phones linked after a successful handshake are listed.")
                    }

                    Section("Known devices (\(model.devices.count))") {
                        if model.devices.isEmpty { Text("No position reports yet").foregroundStyle(.secondary) }
                        ForEach(model.devices) { device in
                            DeviceRow(device: device, route: route(device), now: context.date)
                        }
                    }

                    Section("Diagnostics") {
                        LabeledContent("Received", value: "\(model.diagnostics.received)")
                        LabeledContent("Accepted", value: "\(model.diagnostics.accepted)")
                        LabeledContent("Relayed", value: "\(model.diagnostics.relayed)")
                        LabeledContent("Duplicate / old", value: "\(model.diagnostics.duplicate)")
                        LabeledContent("Rejected", value: "\(model.diagnostics.rejected)")
                    }
                }
            }
            .navigationTitle("Network")
        }
    }

    private func route(_ device: KnownDevice) -> String {
        guard let path = device.path else { return "This phone" }
        // Self-reported by each relay: useful for diagnostics, not proof of the route.
        return path.isEmpty ? "Direct" : "via " + path.map { model.displayName($0) }.joined(separator: " → ")
    }

    private func linkDirection(_ neighbor: MeshNeighbor) -> String {
        switch (neighbor.outgoing, neighbor.incoming) {
        case (true, true): return "both directions"
        case (true, false): return "outgoing"
        default: return "incoming"
        }
    }

    private func rssiText(_ stats: RSSIStatistics?) -> String {
        guard let stats, let smoothed = stats.smoothed else { return "–" }
        let deviation = stats.standardDeviation.map { String(format: " ±%.0f", $0) } ?? ""
        return "\(Int(smoothed.rounded()))\(deviation) dBm (\(stats.sampleCount))"
    }
}

@MainActor
struct DeviceRow: View {
    let device: KnownDevice
    let route: String
    let now: Date

    var body: some View {
        let update = device.update
        let p = update.position
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(update.label ?? shortID(update.id)).font(.headline)
                Text(update.role).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ageText(since: device.receivedAt, now: now)).font(.caption)
            }
            Text(String(format: "x %.2f  y %.2f  z %.2f m", p.x, p.y, p.z)).font(.caption.monospaced())
            Text("\(route) · seq \(update.sequence)\(update.positionMode == "floor" ? " · height assumed" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct PositionView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Role", selection: $model.role) {
                        ForEach(DeviceRole.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    LabeledContent("Source", value: "Manual coordinates")
                    LabeledContent("Frame", value: model.frameID)
                } footer: {
                    Text("Manual / demo coordinates in meters: x right, y up, z forward. They are not measured positions.")
                }

                Section("Coordinates") {
                    Picker("Height", selection: $model.positionMode) {
                        Text("Floor (assumed)").tag("floor")
                        Text("Estimated 3D").tag("3d")
                    }
                    coordinateField("x (right)", value: $model.manualX)
                    coordinateField("y (up)", value: $model.manualY)
                        .disabled(model.positionMode == "floor")
                    coordinateField("z (forward)", value: $model.manualZ)
                    Toggle("Accuracy known", isOn: $model.accuracyKnown)
                    if model.accuracyKnown {
                        coordinateField("Accuracy (m)", value: $model.accuracyMeters)
                    } else {
                        LabeledContent("Accuracy", value: "Unknown")
                    }
                }

                Section {
                    Toggle("Publish every second", isOn: Binding(
                        get: { model.isPublishing },
                        set: { model.setPublishing($0) }
                    ))
                    .disabled(!model.isRunning)
                    LabeledContent("Last sequence", value: model.lastSequence.map { String($0) } ?? "–")
                    if let error = model.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    if !model.isRunning { Text("Start the mesh on the Network tab first.") }
                }
            }
            .navigationTitle("Position")
        }
    }

    private func coordinateField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
    }
}

@MainActor
struct GatewayView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var gateway: GatewayClient

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    Section {
                        TextField("http://192.168.1.20:3000", text: $model.serverURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(gateway.enabled)
                        Button("Check connection") { gateway.checkConnection(origin: model.serverURL) }
                        LabeledContent("Status", value: gateway.connectionStatus)
                    } header: {
                        Text("Laptop dashboard")
                    } footer: {
                        Text("Use a LAN URL printed by the dashboard server. localhost refers to this phone, not the laptop.")
                    }

                    Section("Upload") {
                        Toggle("Upload as gateway", isOn: Binding(
                            get: { gateway.enabled },
                            set: { model.setGateway($0) }
                        ))
                        LabeledContent("Last success", value: ageText(since: gateway.lastSuccess, now: context.date))
                        LabeledContent("Pending devices", value: "\(gateway.pendingCount)")
                        LabeledContent("Accepted / ignored", value: "\(gateway.acceptedCount) / \(gateway.ignoredCount)")
                        if let error = gateway.lastError ?? model.lastError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Gateway")
        }
    }
}
