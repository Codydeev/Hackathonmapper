import Foundation

/// A linked neighbor this phone could run a UWB session with.
public struct UWBPeerCandidate: Equatable {
    public let id: String
    /// Mean RSSI of the pair, from both ends where known.
    public let rssi: Double?
    /// One end of the link is a mounted direction anchor.
    public let isDirectionAnchor: Bool
    /// One end of the link reports `positionSource == none`.
    public let touchesUnplaced: Bool
    /// When the current session started measuring, or was opened while it still swaps tokens; nil
    /// without a session. A session younger than `minHold` keeps its slot.
    public let measuringSince: Date?

    public init(id: String, rssi: Double? = nil, isDirectionAnchor: Bool = false,
                touchesUnplaced: Bool = false, measuringSince: Date? = nil) {
        self.id = id
        self.rssi = rssi
        self.isDirectionAnchor = isDirectionAnchor
        self.touchesUnplaced = touchesUnplaced
        self.measuringSince = measuringSince
    }

    /// Lower is more important: direction anchor, then a link to an unplaced phone, then the rest.
    var rankClass: Int { isDirectionAnchor ? 0 : touchesUnplaced ? 1 : 2 }
}

/// Chooses which neighbors get one of the phone's few concurrent Nearby Interaction sessions.
/// Both ends rank from the same shared mesh reports, so they usually choose each other.
public enum UWBSessionPolicy {
    /// Sessions per phone until iOS refuses one.
    public static let initialBudget = 4

    /// The budget after `activeSessionsLimitExceeded` with `active` sessions running (counting the refused one).
    public static func reducedBudget(active: Int) -> Int { max(1, active - 1) }

    /// Keeps the best `budget` candidates by rank class, then stronger RSSI (ties by ID). A session
    /// that started measuring less than `minHold` ago keeps its slot, displacing the lowest-ranked
    /// newcomer of the same or a lower class; only a higher-class candidate can push it out.
    public static func select(_ c: [UWBPeerCandidate], budget: Int, now: Date, minHold: TimeInterval = 20) -> Set<String> {
        var seen = Set<String>()
        let unique = c.filter { seen.insert($0.id).inserted }
        let ranked = unique.sorted { a, b in
            if a.rankClass != b.rankClass { return a.rankClass < b.rankClass }
            let ra = a.rssi ?? -.infinity, rb = b.rssi ?? -.infinity
            if ra != rb { return ra > rb }
            return a.id < b.id
        }
        let isHeld = { (candidate: UWBPeerCandidate) -> Bool in
            guard let since = candidate.measuringSince else { return false }
            return now.timeIntervalSince(since) < minHold
        }
        var chosen = Array(ranked.prefix(max(0, budget)))
        for held in ranked where isHeld(held) && !chosen.contains(where: { $0.id == held.id }) {
            guard let index = chosen.lastIndex(where: { !isHeld($0) && $0.rankClass >= held.rankClass }) else { continue }
            chosen.remove(at: index)
            chosen.append(held)
        }
        return Set(chosen.map(\.id))
    }
}
