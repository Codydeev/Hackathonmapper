import MeshCore
import SwiftUI

/// Every feature switch in one place, so combinations can be tried on the phones without a new build.
/// Each takes effect at once and is remembered (`MeshModel.features`), except the GPS check, which
/// applies when the mesh starts.
@MainActor
struct FeaturesView: View {
    @EnvironmentObject private var model: MeshModel

    var body: some View {
        Form {
            Section {
                Toggle("Motion (accelerometer, gyroscope)", isOn: $model.features.motion)
                Toggle("Compass", isOn: $model.features.compass)
                Toggle("UWB distances", isOn: Binding(get: { model.uwbRangingEnabled }, set: { model.setUWBRanging($0) }))
                    .disabled(!UWBRanging.supportsDistance)
                Toggle("UWB positioning (anchor fixes)", isOn: Binding(get: { model.uwbEnabled }, set: { model.setUWB($0) }))
                    .disabled(!model.isRunning)
                Toggle("GPS check", isOn: $model.gpsCheck)
                Toggle("Simulate losing GPS", isOn: $model.simulateGPSLoss)
                    .disabled(model.positionChoice == .manual)
            } header: {
                Text("Sensors")
            } footer: {
                Text("Motion feeds dead reckoning on the map, the GPS check's independent evidence and fused tracking's steps; without it the GPS check cannot reach \"trusted\". Compass gives dead reckoning its heading. The GPS check applies when the mesh restarts (below).")
            }

            Section {
                Picker("Placed by", selection: $model.features.peerPlacement) {
                    ForEach(PeerPlacement.allCases) { Text($0.title).tag($0) }
                }
                Picker("Ranges", selection: $model.features.mainMapRanges) {
                    ForEach(SignalRanges.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.features.peerPlacement != .signalMap)
                Toggle("Calibrate radio model", isOn: $model.features.calibrateRadio)
            } header: {
                Text("Main map: phones without a position")
            } footer: {
                Text("Signal map: the dashboard's solver, UWB where measured and Bluetooth otherwise (Ranges picks one kind). Peer locator: GhostCore's per-phone engine. Particle filter: build 7's. The latter two use Bluetooth only. Calibration fits the radio model from UWB distances and placed phones (also on the Track tab). The Track tab compares the distance methods themselves.")
            }

            Section {
                Picker("Predicted area", selection: $model.features.prediction) {
                    ForEach(PredictionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Likely paths (route model)", isOn: $model.features.likelyPaths)
            } header: {
                Text("Phones that went silent")
            } footer: {
                Text("Model: GhostCore's movement-model prediction. Circle: the last spot, growing at walking pace. Off: the phone just ages out. Likely paths: the route model's routes with percentages.")
            }

            Section {
                Toggle("Fast updates (0.2 s)", isOn: $model.features.fastUpdates)
                Toggle("Relay GPS check records", isOn: $model.features.relayIntegrity)
                Toggle("Keep screen awake", isOn: $model.keepAwake)
            } header: {
                Text("Mesh")
            } footer: {
                Text("Fast updates publish and upload within 0.2 s of a move; off, once a second, with less Bluetooth traffic and battery. Every phone should use the same setting when comparing.")
            }

            Section {
                Button("Restart the mesh (applies the GPS check)") {
                    model.stop()
                    model.start()
                }
                .disabled(!model.isRunning)
                Button("Reset features to defaults") { model.features = FeatureFlags() }
            }
        }
        .navigationTitle("Features")
    }
}
