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

                    Section("Neighbors (\(bluetooth.peers.values.filter(\.connected).count) connected)") {
                        let peers = bluetooth.peers.values.sorted { $0.lastSeen > $1.lastSeen }
                        if peers.isEmpty { Text("No nearby mapping phones").foregroundStyle(.secondary) }
                        ForEach(peers) { peer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                    Text(shortID(peer.id.uuidString)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(peer.connected ? "Connected" : "Seen")
                                        .foregroundStyle(peer.connected ? .green : .secondary)
                                    Text(peer.rssi.smoothed.map { "\(Int($0.rounded())) dBm" } ?? "RSSI unknown")
                                    Text(ageText(since: peer.lastSeen, now: context.date))
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Section {
                        if model.directNeighbors.isEmpty { Text("None heard directly yet").foregroundStyle(.secondary) }
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
                        Text("Sent with this phone's position so the dashboard can draw the mesh. Only phones whose own reports arrive directly are listed.")
                    }

                    Section("Known devices (\(model.devices.count))") {
                        if model.devices.isEmpty { Text("No position reports yet").foregroundStyle(.secondary) }
                        ForEach(model.devices) { device in
                            DeviceRow(device: device, isSelf: device.id == model.deviceID, now: context.date)
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
}

@MainActor
struct DeviceRow: View {
    let device: KnownDevice
    let isSelf: Bool
    let now: Date

    private var route: String {
        if isSelf { return "This phone" }
        guard let hops = device.hopsRemaining else { return "Unknown route" }
        let relays = MeshModel.originHops - 1 - hops
        return relays <= 0 ? "Direct" : "Relayed via \(relays) phone\(relays == 1 ? "" : "s")"
    }

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
