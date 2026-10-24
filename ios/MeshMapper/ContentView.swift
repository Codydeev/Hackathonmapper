import MeshCore
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        TabView {
            StartView(bluetooth: model.bluetooth, gateway: model.gateway, location: model.location)
                .tabItem { Label("Start", systemImage: "dot.radiowaves.left.and.right") }
            NetworkView(bluetooth: model.bluetooth)
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
            PositionView()
                .tabItem { Label("Position", systemImage: "location") }
            GatewayView(gateway: model.gateway)
                .tabItem { Label("Gateway", systemImage: "arrow.up.to.line") }
        }
    }
}

/// The one screen most people need: the mesh starts by itself, so this only shows whether the
/// phone is linked, where its position comes from, and how to make it the gateway.
@MainActor
struct StartView: View {
    @EnvironmentObject private var model: MeshModel
    @ObservedObject var bluetooth: BluetoothMesh
    @ObservedObject var gateway: GatewayClient
    @ObservedObject var location: LocationSource

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    Section {
                        TextField("Name", text: $model.label)
                            .font(.title2.weight(.semibold))
                    } footer: {
                        Text("This is how the phone appears on the dashboard.")
                    }

                    Section("Status") {
                        statusRow("Bluetooth", systemImage: "point.3.connected.trianglepath.dotted",
                                  text: bluetoothText, ok: !bluetooth.neighbors.isEmpty)
                        statusRow("Position", systemImage: "location", text: positionText, ok: model.lastSource != PositionSource.none)
                        statusRow("Gateway", systemImage: "arrow.up.to.line",
                                  text: gatewayText(now: context.date), ok: gateway.enabled && gateway.lastError == nil)
                        if !model.isRunning {
                            Button("Start the mesh") { model.start() }
                        }
                    }

                    Section {
                        Toggle("Simulate losing GPS", isOn: $model.simulateGPSLoss)
                            .disabled(model.positionChoice == .manual)
                    } header: {
                        Text("Demo")
                    } footer: {
                        Text("This phone stops sharing its GPS, and the dashboard places it from its Bluetooth links instead. Turn it off to share GPS again.")
                    }

                    Section {
                        if gateway.enabled {
                            Button("Stop being the gateway", role: .destructive) { model.setGateway(false) }
                        } else {
                            Text("On the laptop dashboard, open **Pair a gateway phone** and scan the QR code with this iPhone's Camera.")
                        }
                        if let message = model.pairingMessage {
                            Text(message).font(.footnote).foregroundStyle(gateway.enabled ? .green : .red)
                        }
                    } header: {
                        Text("Gateway (one phone only)")
                    } footer: {
                        Text("The gateway uploads every phone's position to the laptop. Other phones need no network.")
                    }
                }
            }
            .navigationTitle("MeshMapper")
        }
    }

    private var bluetoothText: String {
        guard model.isRunning else { return "Mesh stopped" }
        let count = bluetooth.neighbors.count
        return count == 0 ? "Looking for nearby phones…" : "Linked to \(count) phone\(count == 1 ? "" : "s")"
    }

    private var positionText: String {
        if model.positionChoice == .manual { return "Fixed spot (typed on the Position tab)" }
        if model.simulateGPSLoss { return "GPS lost (simulated): placed from Bluetooth" }
        if location.isDenied { return "Location not allowed: placed from Bluetooth" }
        if let gps = model.gpsPosition { return "GPS ±\(Int(gps.accuracy.rounded())) m" }
        return "No GPS fix yet: placed from Bluetooth"
    }

    private func gatewayText(now: Date) -> String {
        guard gateway.enabled else { return "Not the gateway" }
        if let error = gateway.lastError { return error }
        let host = URLComponents(string: GatewayClient.normalizedOrigin(model.serverURL))?.host ?? model.serverURL
        return "Uploading to \(host) · \(ageText(since: gateway.lastSuccess, now: now))"
    }

    private func statusRow(_ title: String, systemImage: String, text: String, ok: Bool) -> some View {
        LabeledContent {
            Text(text).multilineTextAlignment(.trailing).foregroundStyle(ok ? .primary : .secondary)
        } label: {
            Label(title, systemImage: systemImage).foregroundStyle(ok ? .green : .secondary)
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
                    Picker("Source", selection: $model.positionChoice) {
                        Text("GPS").tag(PositionChoice.gps)
                        Text("Fixed spot (manual)").tag(PositionChoice.manual)
                    }
                    LabeledContent("Frame", value: model.frameID)
                } footer: {
                    Text(model.positionChoice == .gps
                         ? "GPS fixes better than ±\(Int(LocationSource.maxAccuracyMeters)) m are shared in meters east (x) and north (z) of the frame origin. Without one, the phone reports no position and the dashboard places it from Bluetooth."
                         : "Manual / demo coordinates in meters: x right, y up, z forward. They are not measured positions.")
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
                        TextField("https://….trycloudflare.com or http://192.168.1.20:3000", text: $model.serverURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(gateway.enabled)
                        SecureField("Gateway token (internet only)", text: $model.gatewayToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(gateway.enabled)
                        Button("Check connection") { model.checkGatewayConnection() }
                        LabeledContent("Status", value: gateway.connectionStatus)
                    } header: {
                        Text("Laptop dashboard")
                    } footer: {
                        Text("Over the internet (any network, including mobile data): run `npm run tunnel` on the laptop and enter the https URL and token it prints. On the laptop's Wi-Fi: use the LAN URL the dashboard shows; no token needed. localhost refers to this phone, not the laptop.")
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
