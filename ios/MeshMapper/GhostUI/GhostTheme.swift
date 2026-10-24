import SwiftUI

// Design tokens for the GhostCore map. Every colour, size and gap in GhostUI comes from here.
//
// The map is dark and muted so the position colours carry the meaning from two metres away:
//   confirmed  green   GPS that passed the trust checks
//   unchecked  white   GPS with no trust verdict (never shown green)
//   bluetooth  sky     placed from Bluetooth peers (always drawn with its ±r95 circle)
//   predicted  grey    nothing measured right now; dashed, with an age, never looks live
//   rejected   red     raw GPS the trust engine refused
//   suspect    amber   GPS in use with doubts, or checks still running
//   declared   violet  a spot someone typed or pinned
// Signature: the evidence strip, one segment per integrity check, under the verdict headline.
enum GhostTheme {
    static let surface = Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.92)
    static let surfaceRaised = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let border = Color.white.opacity(0.10)
    static let text = Color(red: 0.95, green: 0.96, blue: 0.97)
    static let muted = Color(red: 0.62, green: 0.65, blue: 0.70)

    static let confirmed = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let unchecked = Color(red: 0.88, green: 0.90, blue: 0.93)
    static let bluetooth = Color(red: 0.31, green: 0.76, blue: 0.97)
    static let predicted = Color(red: 0.56, green: 0.59, blue: 0.64)
    static let rejected = Color(red: 1.00, green: 0.35, blue: 0.37)
    static let suspect = Color(red: 1.00, green: 0.69, blue: 0.13)
    static let declared = Color(red: 0.72, green: 0.58, blue: 0.96)
    static let route = Color(red: 0.98, green: 0.84, blue: 0.40)
    static let simulation = Color(red: 1.00, green: 0.69, blue: 0.13)

    // 4 pt rhythm.
    static let gap1: CGFloat = 4
    static let gap2: CGFloat = 8
    static let gap3: CGFloat = 12
    static let gap4: CGFloat = 16
    static let gap6: CGFloat = 24
    static let radius: CGFloat = 16

    // Type scale: 13 / 15 / 17 / 22 / 30. Numbers are monospaced so they do not jitter each second.
    static let caption = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 15)
    static let body = Font.system(size: 17)
    static let title = Font.system(size: 22, weight: .bold)
    static let headline = Font.system(size: 30, weight: .heavy)
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// Card surface used by every panel on the map.
struct GhostCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(GhostTheme.gap4)
            .background(GhostTheme.surface, in: RoundedRectangle(cornerRadius: GhostTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: GhostTheme.radius).stroke(GhostTheme.border))
    }
}

extension View {
    func ghostCard() -> some View { modifier(GhostCard()) }
}

/// Diagonal amber/black stripes: marks anything driven by injected (simulated) inputs.
struct HazardStripes: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 14
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + step / 2, y: 0))
                path.addLine(to: CGPoint(x: x + step / 2, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(.black.opacity(0.55)))
                x += step
            }
        }
        .background(GhostTheme.simulation)
    }
}
