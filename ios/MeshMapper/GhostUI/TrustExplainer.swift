import MeshCore
import SwiftUI

/// Raw GPS next to the GhostCore estimate for one phone, with how far apart they are.
struct CompareCard: View {
    let phone: VizPhone
    let scene: VizScene

    var body: some View {
        if let fix = phone.comparedFix {
            let status = phone.integrity?.status
            let shown = VizPresentation.of(phone, scene: scene)
            let estimate = scene.drawnPoint(phone.id)
            let apart = estimate.map { hypot($0.x - fix.point.x, $0.z - fix.point.z) }
            HStack(alignment: .top, spacing: GhostTheme.gap3) {
                column(title: "RAW GPS", value: "claims ±\(Int(fix.claimedR95.rounded())) m",
                       verdict: Self.verdict(status), tint: Self.tint(status),
                       age: max(0, scene.now.timeIntervalSince(fix.observedAt)), simulated: fix.simulated)
                VStack(spacing: 2) {
                    Image(systemName: "arrow.left.and.right").font(.system(size: 13, weight: .bold))
                    if let apart {
                        Text("\(Int(apart.rounded())) m").font(GhostTheme.number(20, .heavy))
                        if apart >= 10, let estimate {
                            Text(Self.direction(from: estimate, to: fix.point)).font(GhostTheme.caption)
                        }
                    }
                }
                .foregroundStyle(apart.map { $0 > max(fix.claimedR95, phone.r95 ?? 0) ? GhostTheme.rejected : GhostTheme.muted } ?? GhostTheme.muted)
                .frame(minWidth: 64)
                column(title: "GHOSTCORE", value: shown.title,
                       verdict: phone.kind == .unavailable ? "NO POSITION" : (shown.live ? "IN USE" : "NOT LIVE"),
                       tint: GhostMarker.color(shown.tint), age: phone.age(at: scene.now), simulated: phone.simulated)
            }
            .ghostCard()
        }
    }

    private func column(title: String, value: String, verdict: String, tint: Color, age: TimeInterval?,
                        simulated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: GhostTheme.gap1) {
                Text(title).font(GhostTheme.caption).tracking(0.8).foregroundStyle(GhostTheme.muted)
                if simulated { SimBadge(compact: true) }
            }
            Text(verdict).font(.system(size: 17, weight: .heavy)).foregroundStyle(tint)
            Text(value).font(GhostTheme.number(14, .semibold)).foregroundStyle(GhostTheme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(age.map { "\(VizPresentation.ageText($0)) old" } ?? "—").font(GhostTheme.number(13)).foregroundStyle(GhostTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// nil = no trust verdict exists for this fix.
    static func verdict(_ status: VizIntegrityStatus?) -> String {
        switch status {
        case .trusted?: return "TRUSTED"
        case .degraded?: return "DEGRADED"
        case .suspect?: return "SUSPECT"
        case .rejected?: return "REJECTED"
        case .insufficientEvidence?: return "UNCONFIRMED"
        case .unavailable?: return "NO FIX"
        case nil: return "NOT CHECKED"
        }
    }

    static func tint(_ status: VizIntegrityStatus?) -> Color {
        switch status {
        case .trusted?: return GhostTheme.confirmed
        case .degraded?, .suspect?, .insufficientEvidence?: return GhostTheme.suspect
        case .rejected?: return GhostTheme.rejected
        case .unavailable?, nil: return GhostTheme.muted
        }
    }

    /// Compass direction of `b` seen from `a` (x east, z north).
    static func direction(from a: FloorPoint, to b: FloorPoint) -> String {
        let degrees = (atan2(b.x - a.x, b.z - a.z) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((degrees + 22.5) / 45) % 8]
    }
}

/// Everything known about one phone: verdict, why, the evidence and where its position comes from.
struct TrustExplainer: View {
    let phoneId: String
    let scene: VizScene
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                if let phone = scene.phone(phoneId) {
                    content(phone)
                } else {
                    Text("This phone is no longer in reach.")
                        .font(GhostTheme.body).foregroundStyle(GhostTheme.muted).padding(GhostTheme.gap6)
                }
            }
            .background(Color.black)
            .navigationTitle(scene.phone(phoneId)?.label ?? "Phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .preferredColorScheme(.dark)
    }

    private func content(_ phone: VizPhone) -> some View {
        let shown = VizPresentation.of(phone, scene: scene)
        // GPS refused and something else (or nothing) places the phone: lead with the refusal.
        let refused = phone.kind != .measured && [.rejected, .suspect].contains(phone.integrity?.status)
        let headline = refused ? (phone.integrity?.status == .rejected ? "GPS rejected" : "GPS suspect") : shown.title
        let headlineTint = refused ? (phone.integrity?.status == .rejected ? GhostTheme.rejected : GhostTheme.suspect)
            : GhostMarker.color(shown.tint)
        return VStack(alignment: .leading, spacing: GhostTheme.gap4) {
            VStack(alignment: .leading, spacing: GhostTheme.gap1) {
                HStack {
                    Text(headline).font(GhostTheme.headline).foregroundStyle(headlineTint)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    if phone.simulated || phone.integrity?.simulated == true || phone.prediction?.simulated == true {
                        SimBadge()
                    }
                }
                if refused {
                    Text("Position from: \(shown.title)").font(GhostTheme.body).foregroundStyle(GhostMarker.color(shown.tint))
                } else if let detail = shown.detail {
                    Text(detail).font(GhostTheme.body).foregroundStyle(GhostTheme.text)
                }
            }

            CompareCard(phone: phone, scene: scene)

            section("Why") {
                if let summary = phone.integrity?.summary {
                    Text(summary).font(GhostTheme.body.weight(.semibold)).foregroundStyle(GhostTheme.text)
                }
                if let integrity = phone.integrity, !integrity.reasons.isEmpty {
                    ForEach(integrity.reasons) { reason in
                        Label(reason.text, systemImage: "exclamationmark.triangle.fill")
                            .font(GhostTheme.body)
                            .foregroundStyle(GhostTheme.text)
                    }
                } else if let integrity = phone.integrity, integrity.status == .trusted {
                    Text("Every check passed.").font(GhostTheme.body).foregroundStyle(GhostTheme.text)
                } else if phone.method != .gnss, phone.integrity == nil {
                    Text("No GPS to judge: this phone is placed by \(phone.method.title).")
                        .font(GhostTheme.body).foregroundStyle(GhostTheme.text)
                } else {
                    Text(scene.integrityConnected ? "No trust verdict for this fix yet." : "Trust checks are not connected on this build; GPS is shown as not checked.")
                        .font(GhostTheme.body).foregroundStyle(GhostTheme.muted)
                }
            }

            if let evidence = phone.integrity?.evidence, !evidence.isEmpty {
                section("Evidence") {
                    if let score = phone.integrity?.trustScore {
                        HStack {
                            Text("Trust score").foregroundStyle(GhostTheme.muted)
                            Spacer()
                            Text(Self.scoreText(score, lower: phone.integrity?.trustLower)).font(GhostTheme.number(17, .bold))
                                .foregroundStyle(EvidenceStrip.color(score))
                        }
                        .font(GhostTheme.small)
                    }
                    if let integrity = phone.integrity {
                        Text(Self.offsetText(integrity.minimumDetectableOffset))
                            .font(GhostTheme.small)
                            .foregroundStyle(integrity.minimumDetectableOffset == nil ? GhostTheme.suspect : GhostTheme.text)
                    }
                    ForEach(evidence) { item in evidenceRow(item) }
                }
            }

            if let paths = phone.likelyPaths {
                section("Likely paths (prediction)") {
                    ForEach(paths.options) { option in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Int((option.probability * 100).rounded())) %").font(GhostTheme.number(15, .bold))
                                .frame(width: 48, alignment: .leading)
                            Text(option.text).font(GhostTheme.small)
                        }
                        .foregroundStyle(GhostTheme.text)
                    }
                    if paths.offPath >= 0.01 {
                        Text("\(Int((paths.offPath * 100).rounded())) % chance they left the paths")
                            .font(.system(size: 13)).foregroundStyle(GhostTheme.muted)
                    }
                    Text("From the route model trained on walking tracks around Hervanta; it walks the bundled path graph from the last placed spot.")
                        .font(.system(size: 13)).foregroundStyle(GhostTheme.muted)
                }
            }

            if !phone.inputs.isEmpty {
                section("Inputs") {
                    ForEach(phone.inputs) { item in
                        HStack(alignment: .firstTextBaseline, spacing: GhostTheme.gap2) {
                            Image(systemName: item.used ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.used ? GhostTheme.confirmed : GhostTheme.rejected)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inputTitle(item)).font(GhostTheme.small.weight(.semibold)).foregroundStyle(GhostTheme.text)
                                if let reason = item.reason {
                                    Text((item.used ? "" : "not used: ") + VizReason.sentence(code: reason, evidence: nil))
                                        .font(.system(size: 13)).foregroundStyle(GhostTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            if let age = item.age {
                                Text("\(VizPresentation.ageText(age))").font(GhostTheme.number(13)).foregroundStyle(GhostTheme.muted)
                            }
                        }
                    }
                }
            }

            section("Where the position comes from") {
                fact("Kind", phone.kind.rawValue)
                fact("Method", phone.method.title)
                if let r95 = phone.r95 { fact("95% radius", "±\(Int(r95.rounded())) m") }
                if phone.ambiguous { fact("Ambiguous", "\(max(phone.candidates.count, 2)) candidate spots") }
                if let age = phone.age(at: scene.now) { fact("Last measured", "\(VizPresentation.ageText(age)) ago") }
                if let hops = phone.hops { fact("From GPS", VizPresentation.hopText(hops)) }
                if let route = scene.routes.first(where: { $0.origin == phone.id }) {
                    fact("Report travelled", routeText(route))
                }
                if let prediction = phone.prediction {
                    fact("Predicting for", VizPresentation.ageText(prediction.horizon))
                    if let r = prediction.r95 { fact("Predicted radius", "±\(Int(r.rounded())) m") }
                }
            }

            Text(Self.honesty)
                .font(.system(size: 13))
                .foregroundStyle(GhostTheme.muted)
        }
        .padding(GhostTheme.gap4)
    }

    private func evidenceRow(_ item: VizEvidence) -> some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap1) {
            HStack {
                Text(EvidenceStrip.shortName(item.check).capitalized).font(GhostTheme.small.weight(.semibold))
                if !item.independent {
                    Text("uses GPS").font(.system(size: 11, weight: .semibold)).foregroundStyle(GhostTheme.muted)
                        .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).stroke(GhostTheme.border))
                }
                Spacer()
                Text(Self.measure(item)).font(GhostTheme.number(15)).foregroundStyle(GhostTheme.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(GhostTheme.surfaceRaised)
                    Capsule().fill(EvidenceStrip.color(item.score)).frame(width: geo.size.width * max(0.03, min(1, item.score)))
                }
            }
            .frame(height: 6)
        }
        .foregroundStyle(GhostTheme.text)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap2) {
            Text(title.uppercased()).font(GhostTheme.caption).tracking(0.8).foregroundStyle(GhostTheme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostCard()
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(GhostTheme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(GhostTheme.text)
        }
        .font(GhostTheme.number(15))
    }

    private func inputTitle(_ item: VizInput) -> String {
        let who = item.deviceId.map { $0 == scene.selfId ? "This phone" : (scene.phone($0)?.label ?? shortID($0)) }
        let what = item.source == "gnss" ? "GPS" : item.source.capitalized
        return [who, what].compactMap { $0 }.joined(separator: " · ")
    }

    static func scoreText(_ score: Double, lower: Double?) -> String {
        let upper = Int((score * 100).rounded())
        guard let lower, lower < score - 0.005 else { return "\(upper) / 100" }
        return "\(Int((lower * 100).rounded()))–\(upper) / 100"
    }

    /// The honest bound: how far GPS could move this phone before any independent check would notice.
    static func offsetText(_ meters: Double?) -> String {
        guard let meters else { return "No independent check active: a slow GPS offset would go unnoticed." }
        return "GPS could move this phone by up to \(Int(meters.rounded())) m unnoticed."
    }

    private func routeText(_ route: VizRoute) -> String {
        let names = ([route.origin] + route.relays).map { scene.phone($0)?.label ?? String($0.prefix(6)) }
        return (names + ["you"]).joined(separator: " → ")
    }

    static func measure(_ item: VizEvidence) -> String {
        func number(_ v: Double) -> String { v >= 100 ? "\(Int(v.rounded()))" : String(format: "%.1f", v) }
        let unit = item.unit.isEmpty ? "" : " \(item.unit)"
        switch (item.observed, item.threshold) {
        case let (o?, t?): return "\(number(o))\(unit) vs limit \(number(t))\(unit)"
        case let (o?, nil): return "\(number(o))\(unit)"
        case let (nil, t?): return "limit \(number(t))\(unit)"
        default: return "—"
        }
    }

    static let honesty = "Estimates (Bluetooth, dead reckoning, fused) and predictions are computed, not measured, and carry their 95% radius. "
        + "Predicted positions are model output and grey out with age. Items marked SIMULATED come from injected raw "
        + "inputs; the pipeline's response to them is computed live."
}
