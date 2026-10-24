import MeshCore
import SwiftUI
import UIKit

// The three screens from app.md: network, position and gateway.
struct ContentView: View {
    @ObservedObject var model: MeshModel
    @ObservedObject var bluetooth: BluetoothMesh
    @ObservedObject var gateway: GatewayClient

    var body: some View {
        TabView {
            NetworkView(model: model, bluetooth: bluetooth)
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
            PositionView(model: model)
                .tabItem { Label("Position", systemImage: "location") }
            GatewayView(model: model, gateway: gateway)
                .tabItem { Label("Gateway", systemImage: "wifi.router") }
        }
        // Demo mode: keep the screen awake while the mesh runs, restore on stop.
        .onChange(of: model.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
    }
}

struct NetworkView: View {
    @ObservedObject var model: MeshModel
    @ObservedObject var bluetooth: BluetoothMesh

    var body: some View {
        NavigationStack {
            Form {
                Section("This phone") {
                    TextField("Label", text: $model.label)
                    TextField("Frame ID", text: $model.frameID)
                        .disabled(model.isRunning)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    LabeledContent("Device ID", value: String(model.deviceID.prefix(8)))
                }
                Section {
                    Button(model.isRunning ? "Stop network" : "Start network") {
                        model.isRunning ? model.stop() : model.start()
                    }
                    LabeledContent("Bluetooth", value: bluetooth.status)
                    if model.isRunning {
                        Label("Demo mode: keep this app open", systemImage: "sun.max")
                            .foregroundStyle(.orange)
                    }
                    if let error = model.lastError ?? bluetooth.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("Neighbours") {
                    if bluetooth.peers.isEmpty {
                        Text("None in range").foregroundStyle(.secondary)
                    }
                    ForEach(bluetooth.peers.values.sorted { $0.name < $1.name }) { peer in
                        PeerRow(peer: peer)
                    }
                }
                Section("Known devices") {
                    if model.positions.isEmpty {
                        Text("No position reports yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.positions, id: \.id) { update in
                        DeviceRow(update: update, isSelf: update.id == model.deviceID)
                    }
                }
            }
            .navigationTitle("Network")
        }
    }
}

struct PeerRow: View {
    let peer: RadioPeer

    var body: some View {
        HStack {
            Image(systemName: peer.connected ? "link" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(peer.connected ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(peer.name)
                Text(peer.id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                if let rssi = peer.rssi.smoothed {
                    Text("\(Int(rssi.rounded())) dBm").monospacedDigit()
                }
                if let sd = peer.rssi.standardDeviation {
                    Text("±\(sd, specifier: "%.1f") dB · \(peer.rssi.sampleCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DeviceRow: View {
    let update: DeviceUpdate
    let isSelf: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(update.label ?? String(update.id.prefix(8))).bold()
                if isSelf { Text("this phone").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("#\(update.sequence)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("x \(update.position.x, specifier: "%.1f")  y \(update.position.y, specifier: "%.1f")  z \(update.position.z, specifier: "%.1f") m")
                .font(.callout).monospacedDigit()
            Text(update.accuracyMeters.map { "\(update.positionMode) · ±\(String(format: "%.1f", $0)) m" } ?? "\(update.positionMode) · accuracy unknown")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PositionView: View {
    @ObservedObject var model: MeshModel
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var z = 0.0
    @State private var floorMode = true
    @State private var repeating = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Manual / demo coordinates, not measured", systemImage: "hand.point.up.left")
                        .foregroundStyle(.orange)
                    LabeledContent("Frame", value: model.frameID)
                }
                Section("Coordinates (m)") {
                    Toggle("Floor mode (height assumed 0)", isOn: $floorMode)
                    coordinate("x  right", value: $x)
                    if !floorMode { coordinate("y  up", value: $y) }
                    coordinate("z  forward", value: $z)
                }
                Section {
                    Button("Publish once") { publish() }
                        .disabled(!model.isRunning)
                    Toggle("Publish every second", isOn: $repeating)
                        .disabled(!model.isRunning)
                    if !model.isRunning {
                        Text("Start the network first.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Position")
            .onReceive(ticker) { _ in
                if repeating && model.isRunning { publish() }
            }
        }
    }

    private func coordinate(_ name: String, value: Binding<Double>) -> some View {
        HStack {
            Text(name)
            Spacer()
            TextField(name, value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }

    private func publish() {
        model.publish(position: Position(x: x, y: floorMode ? 0 : y, z: z), mode: floorMode ? "floor" : "3d")
    }
}

struct GatewayView: View {
    @ObservedObject var model: MeshModel
    @ObservedObject var gateway: GatewayClient

    var body: some View {
        NavigationStack {
            Form {
                Section("Laptop dashboard") {
                    TextField("http://192.168.1.20:3000", text: $model.serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Check connection") { gateway.checkConnection(origin: model.serverURL) }
                    LabeledContent("Status", value: gateway.connectionStatus)
                    Text("Use the laptop's Wi-Fi IP address. localhost would mean this phone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Upload") {
                    Toggle("This phone is the gateway", isOn: Binding(
                        get: { gateway.enabled },
                        set: { model.setGateway($0) }
                    ))
                    .disabled(!model.isRunning)
                    LabeledContent("Pending devices", value: "\(gateway.pendingCount)")
                    LabeledContent("Last upload", value: gateway.lastSuccess.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                    if let error = gateway.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Gateway")
        }
    }
}
