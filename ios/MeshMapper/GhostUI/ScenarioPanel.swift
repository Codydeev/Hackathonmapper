import SwiftUI

/// What the simulation panel can do. Every action injects RAW inputs (GNSS fixes, which Bluetooth
/// links are up) into the pipeline; the panel never sets an output. An action this build cannot
/// perform is shown disabled with the reason, not faked.
struct VizScenarioControls {
    struct Option: Identifiable {
        let id: String
        let title: String
        let summary: String
    }

    struct Peer: Identifiable {
        let id: String
        let label: String
        let linkUp: Bool
    }

    enum GNSSFault: CaseIterable, Hashable {
        case jump, drift, outage, restore

        var title: String {
            switch self {
            case .jump: return "Jump 390 m"
            case .drift: return "Slow drift"
            case .outage: return "Outage"
            case .restore: return "Restore GPS"
            }
        }

        var detail: String {
            switch self {
            case .jump: return "fix teleports, claims ±4 m"
            case .drift: return "pulled east at 0.8 m/s"
            case .outage: return "no fixes at all"
            case .restore: return "clean receiver again"
            }
        }

        var icon: String {
            switch self {
            case .jump: return "arrow.up.right.circle.fill"
            case .drift: return "arrow.right.to.line.compact"
            case .outage: return "location.slash.fill"
            case .restore: return "location.fill"
            }
        }
    }

    var scenarios: [Option] = []
    var run: ((String) -> Void)?
    var stop: (() -> Void)?
    var supportedGNSS: Set<GNSSFault> = []
    var gnss: ((GNSSFault) -> Void)?
    var peers: [Peer] = []
    var setPeerLink: ((String, Bool) -> Void)?
    /// Shown under any disabled section.
    var unavailableReason = "Needs the GhostCore hub on this build."
}

struct ScenarioPanel: View {
    let controls: VizScenarioControls
    let scenario: VizScenarioState?
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GhostTheme.gap4) {
                    header
                    if let scenario { activeCard(scenario) }
                    scripted
                    gnssSection
                    peerSection
                }
                .padding(GhostTheme.gap4)
            }
            .background(Color.black)
            .navigationTitle("Simulation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap2) {
            HazardStripes().frame(height: 8).clipShape(Capsule())
            Text("SIMULATED INPUTS")
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(GhostTheme.simulation)
            Text("These controls change only what the sensors report: GPS fixes and which Bluetooth peers are on the air. "
                 + "Trust checks, relay, Bluetooth placement and prediction run unchanged, and everything they show is "
                 + "computed live. Injected items carry a SIMULATED badge.")
                .font(GhostTheme.small)
                .foregroundStyle(GhostTheme.text)
        }
    }

    private func activeCard(_ scenario: VizScenarioState) -> some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap2) {
            HStack {
                Text(scenario.isRunning ? "RUNNING" : "FINISHED").font(GhostTheme.caption).tracking(0.8)
                    .foregroundStyle(scenario.isRunning ? GhostTheme.simulation : GhostTheme.muted)
                Spacer()
                Text(Self.clock(scenario.elapsed)).font(GhostTheme.number(17, .bold)).foregroundStyle(GhostTheme.text)
            }
            Text(scenario.name).font(GhostTheme.title).foregroundStyle(GhostTheme.text)
            if let caption = scenario.caption {
                Text(caption).font(GhostTheme.body).foregroundStyle(GhostTheme.simulation)
            }
            if let stop = controls.stop, scenario.isRunning {
                Button(role: .destructive, action: stop) {
                    Label("Stop and restore real inputs", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(GhostTheme.rejected)
            }
        }
        .ghostCard()
    }

    private var scripted: some View {
        section("Scripted scenarios", footer: controls.run == nil ? controls.unavailableReason
                : "Deterministic: the same script replays the same inputs every time.") {
            if controls.scenarios.isEmpty {
                Text("No scripts on this build.").font(GhostTheme.small).foregroundStyle(GhostTheme.muted)
            }
            ForEach(controls.scenarios) { option in
                Button {
                    controls.run?(option.id)
                } label: {
                    HStack(spacing: GhostTheme.gap3) {
                        Image(systemName: "play.circle.fill").font(.system(size: 28))
                            .foregroundStyle(GhostTheme.simulation)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(GhostTheme.body.weight(.semibold)).foregroundStyle(GhostTheme.text)
                            Text(option.summary).font(GhostTheme.small).foregroundStyle(GhostTheme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controls.run == nil)
            }
        }
    }

    private var gnssSection: some View {
        section("This phone's GPS", footer: controls.supportedGNSS.count < VizScenarioControls.GNSSFault.allCases.count
                ? "Greyed out: \(controls.unavailableReason)" : nil) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: GhostTheme.gap2), GridItem(.flexible())],
                      spacing: GhostTheme.gap2) {
                ForEach(VizScenarioControls.GNSSFault.allCases, id: \.self) { fault in
                    let enabled = controls.supportedGNSS.contains(fault) && controls.gnss != nil
                    Button { controls.gnss?(fault) } label: {
                        VStack(alignment: .leading, spacing: GhostTheme.gap1) {
                            Image(systemName: fault.icon).font(.system(size: 20, weight: .bold))
                            Text(fault.title).font(GhostTheme.small.weight(.bold))
                            Text(fault.detail).font(.system(size: 12)).foregroundStyle(GhostTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(GhostTheme.gap3)
                        .background(GhostTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(fault == .restore ? GhostTheme.confirmed : GhostTheme.simulation)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
                }
            }
        }
    }

    private var peerSection: some View {
        section("Peers (Bluetooth links)", footer: controls.setPeerLink == nil ? controls.unavailableReason
                : "Off = this phone stops hearing that peer, as if it walked out of range.") {
            if controls.peers.isEmpty {
                Text("No peers in reach.").font(GhostTheme.small).foregroundStyle(GhostTheme.muted)
            }
            ForEach(controls.peers) { peer in
                Toggle(isOn: Binding(get: { peer.linkUp }, set: { controls.setPeerLink?(peer.id, $0) })) {
                    HStack(spacing: GhostTheme.gap2) {
                        Image(systemName: peer.linkUp ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(peer.linkUp ? GhostTheme.bluetooth : GhostTheme.muted)
                        Text(peer.label).font(GhostTheme.body).foregroundStyle(GhostTheme.text)
                    }
                }
                .tint(GhostTheme.bluetooth)
                .disabled(controls.setPeerLink == nil)
            }
        }
    }

    private func section<Content: View>(_ title: String, footer: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap2) {
            Text(title.uppercased()).font(GhostTheme.caption).tracking(0.8).foregroundStyle(GhostTheme.muted)
            content()
            if let footer { Text(footer).font(.system(size: 12)).foregroundStyle(GhostTheme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostCard()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Full-width stripe over the map whenever injected inputs are in play.
struct SimulationBanner: View {
    let scenario: VizScenarioState?
    let stop: (() -> Void)?

    var body: some View {
        HStack(spacing: GhostTheme.gap2) {
            Text("SIMULATED INPUT")
                .font(.system(size: 13, weight: .black))
                .tracking(0.8)
            if let scenario {
                Text("· \(scenario.name)").font(.system(size: 13, weight: .bold)).lineLimit(1)
                if scenario.elapsed > 0 {
                    Text(ScenarioPanel.clock(scenario.elapsed)).font(GhostTheme.number(13, .bold))
                }
            }
            Spacer(minLength: 0)
            if let stop {
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.system(size: 12, weight: .black))
                        .padding(6)
                        .background(.black.opacity(0.75), in: Circle())
                        .foregroundStyle(GhostTheme.simulation)
                }
                .accessibilityLabel("Stop simulation")
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, GhostTheme.gap3)
        .padding(.vertical, 6)
        .background(GhostTheme.simulation)
        .overlay(alignment: .bottom) { HazardStripes().frame(height: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
