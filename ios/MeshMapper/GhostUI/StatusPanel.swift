import MeshCore
import SwiftUI

/// The top card: this phone's verdict in one word-sized headline, why in one sentence, and where
/// its position comes from right now. Built to be read from two metres away.
struct StatusPanel: View {
    let scene: GhostScene
    let name: String
    let fallback: (title: String, detail: String)?
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap2) {
            HStack(spacing: GhostTheme.gap2) {
                Text(name.uppercased())
                    .font(GhostTheme.caption)
                    .tracking(0.8)
                    .foregroundStyle(GhostTheme.muted)
                Spacer(minLength: 0)
                if let me = scene.me, let age = me.age(at: scene.now), me.kind == .predicted || age >= 5 {
                    Text("\(GhostPresentation.ageText(age)) old")
                        .font(GhostTheme.number(13, .bold))
                        .foregroundStyle(me.kind == .predicted ? GhostTheme.predicted : GhostTheme.muted)
                }
                if scene.anySimulated { SimBadge() }
            }

            if let me = scene.me {
                verdict(me)
            } else if let fallback {
                Text(fallback.title).font(GhostTheme.title).foregroundStyle(GhostTheme.muted)
                if !fallback.detail.isEmpty {
                    Text(fallback.detail).font(GhostTheme.small).foregroundStyle(GhostTheme.text)
                }
            }

            if let caption = scene.scenario?.caption {
                Label(caption, systemImage: "film")
                    .font(GhostTheme.small.weight(.semibold))
                    .foregroundStyle(GhostTheme.simulation)
            }
            if let hint {
                Label(hint, systemImage: "hand.tap")
                    .font(GhostTheme.small.weight(.semibold))
                    .foregroundStyle(GhostTheme.suspect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostCard()
    }

    @ViewBuilder
    private func verdict(_ me: GhostPhone) -> some View {
        let shown = GhostPresentation.of(me, scene: scene)
        let gpsRefused = me.integrity.map { [.rejected, .suspect, .degraded].contains($0.status) } ?? false
        if gpsRefused, me.kind != .measured, let integrity = me.integrity {
            // GPS was refused and something else places this phone: lead with the refusal.
            let tint = integrity.status == .rejected ? GhostTheme.rejected : GhostTheme.suspect
            Text(integrity.status == .rejected ? "GPS REJECTED" : "GPS IN DOUBT")
                .font(GhostTheme.headline)
                .foregroundStyle(tint)
            if let reason = integrity.reasons.first {
                Text(reason.text).font(GhostTheme.body.weight(.semibold)).foregroundStyle(GhostTheme.text)
            }
            sourceLine(me, shown)
        } else {
            Text(shown.title.uppercased())
                .font(GhostTheme.headline)
                .foregroundStyle(GhostMarker.color(shown.tint))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail = detailLine(me, shown) {
                Text(detail).font(GhostTheme.body.weight(.semibold)).foregroundStyle(GhostTheme.text)
            }
        }
        if let evidence = me.integrity?.evidence, !evidence.isEmpty {
            EvidenceStrip(evidence: evidence)
        }
    }

    private func sourceLine(_ me: GhostPhone, _ shown: GhostPresentation) -> some View {
        HStack(spacing: GhostTheme.gap1) {
            Text("Position from:").foregroundStyle(GhostTheme.muted)
            Text(shown.title).foregroundStyle(GhostMarker.color(shown.tint))
            if me.kind == .predicted, let age = me.age(at: scene.now) {
                Text("· \(GhostPresentation.ageText(age))").foregroundStyle(GhostTheme.muted)
            }
        }
        .font(GhostTheme.number(15, .semibold))
    }

    private func detailLine(_ me: GhostPhone, _ shown: GhostPresentation) -> String? {
        switch me.kind {
        case .estimated:
            let via = Self.strongestPlacedPeer(of: me.id, in: scene).map { "via \($0)" }
            return [via, me.hops.map(GhostPresentation.hopText)].compactMap { $0 }.joined(separator: " · ")
        case .predicted:
            let r = me.prediction?.r95.map { "±\(Int($0.rounded())) m and growing" } ?? "movement model cloud"
            return [shown.detail, r].compactMap { $0 }.joined(separator: " · ")
        case .measured where !scene.integrityConnected:
            return [shown.detail, "trust checks not connected"].compactMap { $0 }.joined(separator: " · ")
        default:
            return shown.detail
        }
    }

    /// The live, placed peer with the strongest link to `id`: who this phone is located from.
    static func strongestPlacedPeer(of id: String, in scene: GhostScene) -> String? {
        let placed = Set(scene.phones.filter { $0.kind == .measured || $0.kind == .declared || $0.kind == .estimated }.map(\.id))
        return scene.links
            .filter { ($0.a == id && placed.contains($0.b)) || ($0.b == id && placed.contains($0.a)) }
            .max { $0.rssi < $1.rssi }
            .flatMap { scene.phone($0.a == id ? $0.b : $0.a)?.label }
    }
}

/// One segment per integrity check, coloured by its score: the lie-detector strip.
struct EvidenceStrip: View {
    let evidence: [GhostEvidence]

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(evidence) { item in
                VStack(alignment: .leading, spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(item.score))
                        .frame(height: 6)
                    Text(Self.shortName(item.check))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GhostTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(evidence.map { "\(Self.shortName($0.check)) \(Int($0.score * 100))%" }.joined(separator: ", "))
    }

    static func color(_ score: Double) -> Color {
        score >= 0.7 ? GhostTheme.confirmed : score >= 0.4 ? GhostTheme.suspect : GhostTheme.rejected
    }

    /// "impossibleSpeed" -> "speed"; keeps the strip one line on a phone.
    static func shortName(_ check: String) -> String {
        let known = ["impossibleSpeed": "speed", "positionJump": "jump", "inertialDisagreement": "motion",
                     "peerDisagreement": "peers", "slowDrift": "drift", "staleFix": "age", "claimedAccuracy": "accuracy"]
        if let name = known[check] { return name }
        let spaced = check.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased()
    }
}

/// Colour key, one line above the controls.
struct GhostLegend: View {
    /// Without trust checks no GPS is ever trusted, so the key shows what is on the map instead.
    let integrityConnected: Bool

    var body: some View {
        HStack(spacing: GhostTheme.gap3) {
            if integrityConnected {
                item(GhostTheme.confirmed, "GPS trusted", filled: true)
            } else {
                item(GhostTheme.unchecked, "GPS unchecked", filled: true)
            }
            item(GhostTheme.bluetooth, "Bluetooth", filled: true)
            item(GhostTheme.predicted, "Predicted", filled: false)
            HStack(spacing: GhostTheme.gap1) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .black)).foregroundStyle(GhostTheme.rejected)
                Text("Rejected")
            }
            HStack(spacing: GhostTheme.gap1) {
                Rectangle().fill(GhostTheme.route).frame(width: 12, height: 3)
                Text("Relay")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(GhostTheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, GhostTheme.gap3)
        .padding(.vertical, 6)
        .background(GhostTheme.surface, in: Capsule())
    }

    private func item(_ color: Color, _ text: String, filled: Bool) -> some View {
        HStack(spacing: GhostTheme.gap1) {
            if filled {
                Circle().fill(color).frame(width: 9, height: 9)
            } else {
                Circle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 9, height: 9)
            }
            Text(text)
        }
    }
}
