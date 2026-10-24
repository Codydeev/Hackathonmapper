import MeshCore
import SwiftUI

/// RSSI calibration at marked distances (ARCHITECTURE.md T2): two phones at the same height, a tape
/// measure, one minute per distance. The fit replaces the default path-loss model for that channel
/// on this phone only; it is valid for this pair of phone models and this kind of place.
struct PositioningCalibrationView: View {
    @ObservedObject var service: PositioningService
    /// Peers currently linked, as (id, label).
    let peers: [(id: String, label: String)]

    @State private var peerId = ""
    @State private var channel: Positioning.RSSIChannel = .connection
    @State private var environment = "outdoors, in hand"
    @State private var activeDistance: Double?
    @State private var result: Positioning.CalibrationResult?
    @State private var error: String?

    static let distances: [Double] = [2, 5, 10, 20]

    var body: some View {
        Form {
            if let session = service.calibration {
                Section("Recording \(label(session.peerId)), \(session.channel.rawValue)") {
                    ForEach(Self.distances, id: \.self) { d in
                        HStack {
                            Text("\(Int(d)) m")
                            Spacer()
                            Text("\(samples(session, at: d)) samples").foregroundStyle(.secondary).monospacedDigit()
                            if activeDistance == d {
                                Button("Stop") {
                                    service.calibrationStep(distance: nil)
                                    activeDistance = nil
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button("Record") {
                                    service.calibrationStep(distance: d, label: environment)
                                    activeDistance = d
                                }
                                .disabled(activeDistance != nil)
                            }
                        }
                    }
                    if session.isStepComplete { Text("Enough for this distance: stop and move on.").foregroundStyle(.green) }
                }
                Section {
                    Button("Fit and use on this phone") { fit(apply: true) }.disabled(activeDistance != nil)
                    Button("Fit only") { fit(apply: false) }.disabled(activeDistance != nil)
                    Button("Cancel", role: .destructive) {
                        service.cancelCalibration()
                        activeDistance = nil
                        result = nil
                    }
                }
            } else {
                Section("Peer and link") {
                    Picker("Peer", selection: $peerId) {
                        Text("Choose").tag("")
                        ForEach(peers, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("RSSI", selection: $channel) {
                        Text("Connection").tag(Positioning.RSSIChannel.connection)
                        Text("Advertisement").tag(Positioning.RSSIChannel.advertisement)
                    }
                    TextField("Where and how held", text: $environment)
                    Button("Start calibration") {
                        service.beginCalibration(peerId: peerId, channel: channel, peerModel: "", environment: environment)
                        result = nil
                        error = nil
                    }
                    .disabled(peerId.isEmpty)
                }
                Section {
                    Text("Same height, phones held as they will be carried, nobody between them. One minute per distance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let result {
                Section("Fit") {
                    Text(String(format: "RSSI at 1 m %.1f dBm, exponent %.2f", result.model.p0, result.model.n))
                    Text(String(format: "Spread %.1f dB fast, %.1f dB spot to spot", result.model.sigmaFast, result.model.sigmaShadow))
                    Text(String(format: "Held-out range error %.0f %%", 100 * result.leaveOneOutRangeError))
                    ForEach(result.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("RSSI calibration")
    }

    private func label(_ id: String) -> String { peers.first { $0.id == id }?.label ?? id }

    private func samples(_ session: Positioning.CalibrationSession, at d: Double) -> Int {
        session.steps.filter { $0.distance == d }.reduce(0) { $0 + $1.samples.count }
    }

    private func fit(apply: Bool) {
        do {
            result = try service.finishCalibration(apply: apply)
            error = nil
        } catch let e as Positioning.CalibrationError {
            error = "Not enough to fit: \(e)"
        } catch {
            self.error = "\(error)"
        }
    }
}
