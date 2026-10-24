import MeshCore
import SwiftUI

/// Settings section for Luotsi's GPS check: on/off, a demo attack on this phone's GPS, and what
/// each of the six witnesses says right now.
@MainActor
struct GPSCheckSection: View {
    @ObservedObject var gpsGuard: GPSGuard

    var body: some View {
        Section {
            Toggle("Check GPS against steps and compass", isOn: $gpsGuard.enabled)
            Picker("Demo attack", selection: Binding(get: { gpsGuard.attack }, set: { gpsGuard.setAttack($0) })) {
                Text("None").tag(GPSAttack?.none)
                ForEach(GPSAttack.allCases, id: \.self) { attack in
                    Text(GPSGuard.label(attack)).tag(GPSAttack?.some(attack))
                }
            }
            if let summary = gpsGuard.summary {
                Label(summary.text, systemImage: GPSCheckStyle.icon(summary.level))
                    .foregroundStyle(GPSCheckStyle.color(summary.level))
                    .font(.subheadline)
            }
            if gpsGuard.enabled, let state = gpsGuard.state {
                ForEach(state.witnesses, id: \.id) { witness in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(witness.label)
                            Spacer()
                            Text(witness.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
                                .monospacedDigit()
                                .foregroundStyle(witness.score.map { $0 >= 0.75 ? Color.green : ($0 >= 0.4 ? .orange : .red) } ?? .secondary)
                        }
                        Text(witness.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Steps detected", value: gpsGuard.motionAvailable ? "\(gpsGuard.stepCount)" : "no motion sensor")
                if let dr = state.deadReckoning {
                    LabeledContent("On steps + compass", value: "\(Int(dr.meters.rounded())) m in \(Int(dr.seconds.rounded())) s")
                }
            }
        } header: {
            Text("GPS check")
        } footer: {
            Text("Six witnesses compare GPS with this phone's own steps, compass and stillness. If GPS jumps, drifts away from your steps or disappears, the phone stops sharing it and the others place it over Bluetooth. Demo attacks change only this phone's GPS. Long-press the GPS button on the map for the same attacks.")
        }
    }
}

enum GPSCheckStyle {
    static func icon(_ level: GPSGuard.Level) -> String {
        switch level {
        case .good: return "checkmark.shield.fill"
        case .info: return "shield"
        case .warn: return "exclamationmark.shield.fill"
        case .bad: return "xmark.shield.fill"
        }
    }

    static func color(_ level: GPSGuard.Level) -> Color {
        switch level {
        case .good: return .green
        case .info: return .secondary
        case .warn: return .orange
        case .bad: return .red
        }
    }
}
