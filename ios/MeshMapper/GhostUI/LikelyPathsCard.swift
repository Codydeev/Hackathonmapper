import SwiftUI

/// Which way a lost phone probably went, in words, from the route model. Headed PREDICTED with the
/// time since the phone was last placed, so nobody reads it as a live position.
struct LikelyPathsCard: View {
    let phone: VizPhone
    let paths: VizLikelyPaths
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: GhostTheme.gap1) {
            HStack(spacing: GhostTheme.gap2) {
                Text("PREDICTED")
                    .font(GhostTheme.caption).tracking(0.8)
                    .foregroundStyle(GhostTheme.predicted)
                Text("\(phone.label) out of reach\(phone.age(at: now).map { " \(VizPresentation.ageText($0))" } ?? "") · probably")
                    .font(GhostTheme.caption)
                    .foregroundStyle(GhostTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if phone.simulated { SimBadge(compact: true) }
            }
            ForEach(paths.options.prefix(3)) { option in
                HStack(alignment: .firstTextBaseline, spacing: GhostTheme.gap2) {
                    Text("\(Int((option.probability * 100).rounded())) %")
                        .font(GhostTheme.number(17, .heavy))
                        .foregroundStyle(GhostTheme.text.opacity(GhostMapContent.pathOpacity(option.rank) + 0.05))
                        .frame(width: 52, alignment: .leading)
                    Text(option.text)
                        .font(GhostTheme.small)
                        .foregroundStyle(GhostTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if paths.offPath >= 0.05 {
                Text("\(Int((paths.offPath * 100).rounded())) % chance they left the paths")
                    .font(.system(size: 13))
                    .foregroundStyle(GhostTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ghostCard()
        .overlay(RoundedRectangle(cornerRadius: GhostTheme.radius)
            .stroke(GhostTheme.predicted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
