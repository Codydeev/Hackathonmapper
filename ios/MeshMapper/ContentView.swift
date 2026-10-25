import MeshCore
import SwiftUI

/// One map for everyone; the detailed screens live behind the settings button.
@MainActor
struct ContentView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        PhoneMapView(hub: model.ghost, predictor: model.predictor, bluetooth: model.bluetooth)
            .sheet(isPresented: $model.showingSettings) { SettingsView() }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            TrackView(tracker: model.tracker, bluetooth: model.bluetooth)
                .tabItem { Label("Track", systemImage: "scope") }
                .tag(AppTab.track)
            StartView(bluetooth: model.bluetooth, gateway: model.gateway, location: model.location)
                .tabItem { Label("Start", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppTab.start)
            NetworkView(bluetooth: model.bluetooth)
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppTab.network)
            PositionView(uwb: model.uwb)
                .tabItem { Label("Position", systemImage: "location") }
                .tag(AppTab.position)
            GatewayView(gateway: model.gateway)
                .tabItem { Label("Gateway", systemImage: "arrow.up.to.line") }
                .tag(AppTab.gateway)
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { model.showingSettings = false }
                .buttonStyle(.borderedProminent)
                .padding(.trailing, 16)
                .padding(.top, 8)
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
                        Text("Scan the gateway QR code in the dashboard's **Connect** panel with this iPhone's Camera, then turn on uploading here.")
                        Toggle("Upload as gateway", isOn: Binding(
                            get: { gateway.enabled },
                            set: { model.setGateway($0) }
                        ))
                        .disabled(model.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        if model.lastSource == .uwb { return "UWB fix from an anchor" }
        if model.lastSource == .fused { return "Motion + BLE anchors" }
        if model.positionChoice == .manual, !(model.uwbEnabled && model.role != .anchor) {
            return "Fixed spot (typed on the Position tab)"
        }
        if model.simulateGPSLoss { return "GPS lost (simulated): placed from Bluetooth" }
        if location.isDenied { return "Location not allowed: placed from Bluetooth" }
        // What is actually published: GhostCore decides whether this phone's GPS may be shared.
        let publication = model.ghost.publication
        if publication.source == .gps { return "GPS ±\(Int((publication.accuracyMeters ?? 0).rounded())) m" }
        if let gps = model.gpsPosition {
            return model.gpsCheck
                ? "GPS not trusted yet (GPS check): placed from Bluetooth"
                : "GPS ±\(Int(gps.accuracy.rounded())) m not shared yet: placed from Bluetooth"
        }
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
                    Section {
                        NavigationLink("Relay test (store-and-forward)") {
                            RelayTestView(bluetooth: bluetooth, label: model.label)
                        }
                    }
                    Section {
                        NavigationLink("Ambient radio (experimental)") {
                            AmbientRadioView(deviceId: model.deviceID, frameId: model.frameID) {
                                model.ghost.phones.first(where: \.isSelf)
                            }
                        }
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
    @ObservedObject var uwb: UWBRanging

    private var usesUWBFix: Bool { model.uwbEnabled && model.role != .anchor }
    private var axes: (x: String, z: String) { GeoFrame.axisNames(frameId: model.frameID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Role", selection: $model.role) {
                        ForEach(DeviceRole.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    if usesUWBFix {
                        LabeledContent("Source", value: "UWB fix from an anchor")
                    } else {
                        Picker("Source", selection: $model.positionChoice) {
                            ForEach(PositionChoice.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    LabeledContent("Frame", value: model.frameID)
                } footer: {
                    if usesUWBFix {
                        Text("Published coordinates come from a UWB anchor; without a fresh fix, GPS or no position. The manual coordinates below are not used while UWB positioning is on.")
                    } else {
                        switch model.positionChoice {
                        case .gps:
                            Text("GPS fixes better than ±\(Int(LocationSource.maxAccuracyMeters)) m are shared in meters \(axes.x) (x) and \(axes.z) (z) of the frame origin, with a 95 % accuracy radius. Without one, the phone reports no position and the dashboard places it from Bluetooth. With GPS check on, only GPS that agrees with this phone's motion is shared.")
                        case .manual:
                            Text("Manual / demo coordinates in meters: x \(axes.x), y up, z \(axes.z). They are not measured positions.")
                        case .fused:
                            Text("Estimated from steps and turns (accelerometer, gyro) corrected by RSSI to linked anchor phones. Accuracy is the filter's own 95 % estimate, typically a few meters indoors. Until tracking starts: GPS or no position.")
                        }
                    }
                }

                Section {
                    Toggle("GPS check", isOn: $model.gpsCheck)
                } footer: {
                    Text("Only GPS that agrees with this phone's motion is shared. Applies at the next start.")
                }

                Section {
                    if let positioning = model.ghost.positioning {
                        NavigationLink("Bluetooth distance calibration") {
                            PositioningCalibrationView(
                                service: positioning,
                                peers: model.bluetooth.neighbors.map { ($0.deviceId, $0.label ?? shortID($0.deviceId)) })
                        }
                    } else {
                        LabeledContent("Bluetooth distance calibration", value: "Start the mesh first")
                    }
                } footer: {
                    Text("Two phones at the same height and a tape measure: fits this phone's RSSI-to-distance model (field test T2).")
                }

                uwbSection

                Section(model.positionChoice == .fused ? "Start point" : "Coordinates") {
                    Picker("Height", selection: $model.positionMode) {
                        Text("Floor (assumed)").tag("floor")
                        Text(model.positionChoice == .fused ? "Barometer 3D" : "Estimated 3D").tag("3d")
                    }
                    coordinateField("x (\(axes.x))", value: $model.manualX)
                    coordinateField("y (up)", value: $model.manualY)
                        .disabled(model.positionMode == "floor")
                    coordinateField("z (\(axes.z))", value: $model.manualZ)
                    if model.positionChoice != .fused {
                        Toggle("Accuracy known", isOn: $model.accuracyKnown)
                        if model.accuracyKnown {
                            coordinateField("Accuracy, 95 % (m)", value: $model.accuracyMeters)
                        } else {
                            LabeledContent("Accuracy", value: "Unknown")
                        }
                    }
                }

                if model.positionChoice == .fused {
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

    @ViewBuilder private var uwbSection: some View {
        Section {
            Toggle("UWB distances", isOn: Binding(
                get: { model.uwbRangingEnabled },
                set: { model.setUWBRanging($0) }
            ))
            .disabled(!UWBRanging.supportsDistance)
            Toggle("UWB positioning", isOn: Binding(
                get: { model.uwbEnabled },
                set: { model.setUWB($0) }
            ))
            .disabled(!model.isRunning)
            LabeledContent("This iPhone", value: UWBRanging.supportsDirection ? "Distance + direction"
                           : UWBRanging.supportsDistance ? "Distance only" : "No UWB")
            if model.role == .anchor {
                coordinateField("Back faces (°)", value: $model.anchorHeading)
            }
            if model.isRunning, model.uwbRangingEnabled || (model.role == .anchor && model.uwbEnabled) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if uwb.measurements.isEmpty { Text("Measuring no phones yet").foregroundStyle(.secondary) }
                    ForEach(uwb.measurements.keys.sorted(), id: \.self) { id in
                        if let measurement = uwb.measurements[id] {
                            HStack {
                                Text(model.displayName(id))
                                Spacer()
                                Text(measurementText(measurement, now: context.date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if uwb.sessionBudget < UWBSessionPolicy.initialBudget {
                        Text("iOS allows at most \(uwb.sessionBudget) UWB sessions right now").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.role != .anchor, model.uwbEnabled {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let current = model.currentFix {
                        let p = current.fix.position
                        LabeledContent("Fix from", value: model.displayName(current.fix.anchorId))
                        Text(String(format: "x %.2f  z %.2f m · ±%.2f m · %.1f m away", p.x, p.z,
                                    current.fix.accuracyMeters, current.fix.distanceMeters))
                            .font(.caption.monospaced())
                        Text("updated " + ageText(since: current.receivedAt, now: context.date)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No fresh fix: not publishing. Face the anchor's back within about 8 m, in line of sight.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            if let error = uwb.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("UWB")
        } footer: {
            Text(uwbFooter)
        }
    }

    private var uwbFooter: String {
        let distances = "UWB distances: measures the distance to up to four linked UWB phones and shares it in this phone's reports, so the Track tab and the dashboard use it instead of the Bluetooth signal strength."
        let positioning: String
        if model.role == .anchor {
            let forward = GeoFrame.forwardName(frameId: model.frameID)
            positioning = "UWB positioning: mount this phone upright with the screen facing you and enter the direction its back faces, measured on the floor plan from +z towards +x (0 = \(forward), 90 = +x). Its manual coordinates are the known anchor position. Phones are measured only inside a cone behind it, up to about 8 m."
        } else {
            positioning = "UWB positioning: a mounted anchor with known coordinates measures this phone's distance and direction. Both need iPhone 11 or newer (not SE) and line of sight."
        }
        return distances + " " + positioning
    }

    private func measurementText(_ measurement: UWBMeasurement, now: Date) -> String {
        let distance = measurement.distance.map { String(format: "%.2f m", $0) } ?? "no distance"
        return "\(distance) · \(measurement.direction == nil ? "no direction" : "direction ✓") · \(ageText(since: measurement.updatedAt, now: now))"
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
    /// The frame's +z direction: dead reckoning's heading is aligned to it.
    private var forward: String { GeoFrame.forwardName(frameId: model.frameID) }

    var body: some View {
        Section {
            if status.tracking {
                Button("Re-align heading (facing \(forward) now)") { model.alignHeading() }
                Menu("I'm next to an anchor…") {
                    ForEach(model.anchors, id: \.id) { anchor in
                        Button(anchor.label ?? shortID(anchor.id)) { model.markNear(anchor: anchor.id) }
                    }
                }
                .disabled(model.anchors.isEmpty)
                Button("Stop tracking", role: .destructive) { model.stopTracking() }
            } else {
                Button("Start here, facing \(forward)") { model.startTracking() }
                Button("Start at RSSI fix, facing \(forward)") { model.startTrackingFromFix() }
                    .disabled(status.fix == nil)
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("Hold the phone in front of you the same way while walking. Heading is relative, so face \(forward) when starting or re-aligning.")
        }
        .disabled(!model.isRunning)

        Section("Estimate") {
            if let x = status.x, let z = status.z {
                LabeledContent("Position", value: String(format: "x %.2f  z %.2f m", x, z))
                LabeledContent("Accuracy (95 %)", value: status.accuracy.map { String(format: "±%.1f m", $0) } ?? "Unknown")
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
                LabeledContent("Accuracy (95 %)", value: String(format: "±%.1f m · %ld anchors · %.1f dB residual",
                                                                fix.accuracy * SignalMap.r95PerSigma / 2.squareRoot(),
                                                                fix.anchorCount, fix.residualDB))
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
