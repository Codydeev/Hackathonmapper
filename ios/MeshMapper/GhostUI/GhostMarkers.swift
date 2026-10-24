import SwiftUI

/// A phone on the map: a dot whose fill says how it is placed, and a label with its honest kind.
/// Predicted phones are hollow, dashed and grey with their age, so they never pass for live.
struct GhostMarker: View {
    let phone: GhostPhone
    let presentation: GhostPresentation
    let selected: Bool
    let now: Date

    private var size: CGFloat { phone.isSelf ? 26 : 18 }

    var body: some View {
        let tint = Self.color(presentation.tint)
        ZStack {
            if selected {
                Circle().stroke(GhostTheme.text, lineWidth: 2).frame(width: size + 12, height: size + 12)
            }
            if presentation.live {
                Circle().fill(tint).frame(width: size, height: size)
                Circle().stroke(.white, lineWidth: phone.isSelf ? 3 : 2).frame(width: size, height: size)
            } else {
                Circle().fill(GhostTheme.surface).frame(width: size, height: size)
                Circle().stroke(tint, style: StrokeStyle(lineWidth: 2.5, dash: [3, 3])).frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .overlay(alignment: .top) {
            label.fixedSize().offset(y: size / 2 + 14)
        }
        .contentShape(Circle().inset(by: -10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phone.label), \(presentation.title)\(presentation.detail.map { ", \($0)" } ?? "")")
    }

    private var label: some View {
        let tint = Self.color(presentation.tint)
        return VStack(alignment: .center, spacing: 1) {
            HStack(spacing: GhostTheme.gap1) {
                Text(phone.label)
                    .font(.system(size: phone.isSelf ? 15 : 13, weight: .bold))
                    .foregroundStyle(GhostTheme.text)
                if phone.integrity?.status == .rejected, phone.kind != .measured {
                    StatusChip(text: "GPS ✕", tint: GhostTheme.rejected)
                }
                if phone.simulated || phone.integrity?.simulated == true || phone.prediction?.simulated == true {
                    SimBadge(compact: true)
                }
            }
            Text(shortTitle)
                .font(GhostTheme.number(12, .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, GhostTheme.gap2)
        .padding(.vertical, GhostTheme.gap1)
        .background(GhostTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.5)))
    }

    /// The marker label stays short; the full sentence lives on the status card and explainer.
    private var shortTitle: String {
        switch phone.kind {
        case .predicted:
            return "Predicted · \(phone.age(at: now).map(GhostPresentation.ageText) ?? "?")"
        case .estimated:
            let r = phone.r95.map { " ±\(Int($0.rounded())) m" } ?? ""
            return phone.ambiguous ? "Bluetooth · 2+ spots" : "Bluetooth\(r)"
        default:
            return presentation.title
        }
    }

    static func color(_ tint: GhostPresentation.GhostTint) -> Color {
        switch tint {
        case .confirmed: return GhostTheme.confirmed
        case .unchecked: return GhostTheme.unchecked
        case .bluetooth: return GhostTheme.bluetooth
        case .predicted: return GhostTheme.predicted
        case .rejected: return GhostTheme.rejected
        case .suspect: return GhostTheme.suspect
        case .declared: return GhostTheme.declared
        case .unknown: return GhostTheme.muted
        }
    }
}

/// The raw GPS fix that was refused or doubted: a red cross where the receiver claimed to be.
struct RawFixMarker: View {
    let label: String
    let status: GhostIntegrityStatus
    let simulated: Bool

    var body: some View {
        let tint = status == .rejected ? GhostTheme.rejected : GhostTheme.suspect
        Image(systemName: "xmark")
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(GhostTheme.surface, in: Circle())
            .overlay(Circle().stroke(tint, lineWidth: 2))
            .overlay(alignment: .top) {
                HStack(spacing: GhostTheme.gap1) {
                    Text(status == .rejected ? "\(label) · rejected" : "\(label) · in doubt")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    if simulated { SimBadge(compact: true) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(GhostTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .offset(y: 30)
            }
            .accessibilityLabel("\(label), \(status == .rejected ? "rejected" : "in doubt")")
    }
}

struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Marks a record that came from injected inputs.
struct SimBadge: View {
    var compact = false

    var body: some View {
        Text(compact ? "SIM" : "SIMULATED")
            .font(.system(size: compact ? 10 : 12, weight: .black))
            .tracking(0.5)
            .foregroundStyle(.black)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 1)
            .background(GhostTheme.simulation, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Simulated input")
    }
}
