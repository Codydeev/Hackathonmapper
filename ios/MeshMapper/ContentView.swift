import MeshCore
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NetworkView(bluetooth: model.bluetooth)
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppTab.network)
            PositionView()
                .tabItem { Label("Position", systemImage: "location") }
                .tag(AppTab.position)
            GatewayView(gateway: model.gateway)
                .tabItem { Label("Gateway", systemImage: "arrow.up.to.line") }
                .tag(AppTab.gateway)
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
                    Picker("Source", selection: $model.positionSource) {
                        ForEach(PositionSource.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.isPublishing)
                    LabeledContent("Frame", value: model.frameID)
                } footer: {
                    switch model.positionSource {
                    case .manual:
                        Text("Manual / demo coordinates in meters: x right, y up, z forward. They are not measured positions.")
                    case .fused:
                        Text("Estimated from steps and turns (accelerometer, gyro) corrected by RSSI to linked anchor phones. Accuracy is the filter's own estimate, typically a few meters indoors.")
                    }
                }

                Section(model.positionSource == .manual ? "Coordinates" : "Start point") {
                    Picker("Height", selection: $model.positionMode) {
                        Text("Floor (assumed)").tag("floor")
                        Text(model.positionSource == .manual ? "Estimated 3D" : "Barometer 3D").tag("3d")
                    }
                    coordinateField("x (right)", value: $model.manualX)
                    coordinateField("y (up)", value: $model.manualY)
                        .disabled(model.positionMode == "floor")
                    coordinateField("z (forward)", value: $model.manualZ)
                    if model.positionSource == .manual {
                        Toggle("Accuracy known", isOn: $model.accuracyKnown)
                        if model.accuracyKnown {
                            coordinateField("Accuracy (m)", value: $model.accuracyMeters)
                        } else {
                            LabeledContent("Accuracy", value: "Unknown")
                        }
                    }
                }

                if model.positionSource == .fused {
                    FusionSections(status: model.fusionStatus)
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

/// Tracking controls and what motion filtering does to each anchor's BLE range.
@MainActor
struct FusionSections: View {
    @EnvironmentObject private var model: MeshModel
    let status: FusionStatus

    var body: some View {
        Section {
            if status.tracking {
                Button("Re-align heading (facing +z now)") { model.alignHeading() }
                Menu("I'm next to an anchor…") {
                    ForEach(model.anchors, id: \.id) { anchor in
                        Button(anchor.label ?? shortID(anchor.id)) { model.markNear(anchor: anchor.id) }
                    }
                }
                .disabled(model.anchors.isEmpty)
                Button("Stop tracking", role: .destructive) { model.stopTracking() }
            } else {
                Button("Start here, facing +z") { model.startTracking() }
                Button("Start at RSSI fix, facing +z") { model.startTrackingFromFix() }
                    .disabled(status.fix == nil)
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("Hold the phone in front of you the same way while walking. Heading is relative, so face the frame's +z direction when starting or re-aligning.")
        }
        .disabled(!model.isRunning)

        Section("Estimate") {
            if let x = status.x, let z = status.z {
                LabeledContent("Position", value: String(format: "x %.2f  z %.2f m", x, z))
                LabeledContent("Accuracy", value: status.accuracy.map { String(format: "±%.1f m", $0) } ?? "Unknown")
            } else {
                Text("Not tracking").foregroundStyle(.secondary)
            }
            LabeledContent("Heading", value: String(format: "%.0f° (gyro offset %+.0f°)", status.headingDegrees, status.headingOffsetDegrees))
            LabeledContent("Steps", value: String(format: "%ld · %.1f m · %@", status.steps, status.walked,
                                                  status.walking ? "walking" : "still"))
            LabeledContent("Radio offset", value: status.receiverOffsetDB.map { String(format: "%+.1f dB", $0) } ?? "–")
            LabeledContent("Path loss", value: String(format: "n %.2f · %.0f dBm at 1 m · %ld anchor links",
                                                      status.calibration.model.exponent,
                                                      status.calibration.model.referenceRSSI, status.calibration.linkCount))
            LabeledContent("RSSI updates", value: "\(status.accepted) used · \(status.rejected) rejected · \(status.recoveries) resets")
        }

        Section {
            if status.ranges.isEmpty { Text("No linked anchors with recent RSSI").foregroundStyle(.secondary) }
            ForEach(status.ranges, id: \.anchorId) { range in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.displayName(range.anchorId))
                        Spacer()
                        Text(rangeText(range)).font(.caption.monospaced())
                    }
                    Text(detailText(range)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Anchor ranges")
        } footer: {
            Text("RSSI range after motion filtering, then the range from the fused position. Standing still averages RSSI; jumps the steps can't explain are dropped.")
        }

        Section {
            if let fix = status.fix {
                LabeledContent("Position", value: String(format: "x %.2f  z %.2f m", fix.x, fix.z))
                LabeledContent("Accuracy", value: String(format: "±%.1f m · %ld anchors · %.1f dB residual",
                                                         fix.accuracy, fix.anchorCount, fix.residualDB))
            } else {
                Text("Needs RSSI from three or more anchors").foregroundStyle(.secondary)
            }
        } header: {
            Text("RSSI-only fix")
        } footer: {
            Text("For comparison and to start tracking. It is never published on its own.")
        }
    }

    private func rangeText(_ range: AnchorRange) -> String {
        let fused = range.fusedDistance.map { String(format: " → %.1f m", $0) } ?? ""
        return String(format: "%.1f m", range.rssiDistance) + fused
    }

    private func detailText(_ range: AnchorRange) -> String {
        var parts = [String(format: "±%.1f dB", range.sigmaDB)]
        parts.append(range.stillSamples > 0 ? "\(range.stillSamples) still samples averaged" : "walking")
        if range.droppedSamples > 0 { parts.append("\(range.droppedSamples) jumps dropped") }
        switch range.lastResult {
        case .accepted: parts.append("used")
        case .rejected: parts.append("rejected")
        case .skipped: parts.append("skipped")
        case nil: break
        }
        return parts.joined(separator: " · ")
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
                        Text("Easiest: scan the gateway QR code from the dashboard's Connect panel or from `npm run tunnel` with the Camera app; it fills in both fields. Over the internet (any network, including mobile data) use the https URL and token; on the laptop's Wi-Fi the LAN URL works without a token. localhost refers to this phone, not the laptop.")
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
