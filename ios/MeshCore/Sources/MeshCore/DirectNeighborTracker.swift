import Foundation

/// Learns direct BLE neighbors by app device ID, without a handshake.
///
/// An origin sends its own report with `originHops - 1` hops remaining and every relay
/// decrements the count, so only a report arriving with exactly that count came straight
/// from its origin, over the link it arrived on. Relayed reports never create a neighbor.
public struct DirectNeighborTracker {
    /// A neighbor is dropped once it has not been heard directly for this long.
    public static let window: TimeInterval = 6

    private let directHops: Int
    private var links: [String: (link: String, heardAt: Date)] = [:]

    public init(originHops: Int) {
        directHops = originHops - 1
    }

    public mutating func record(_ packet: MeshPacket, link: String, selfId: String, at now: Date = Date()) {
        guard packet.hopsRemaining == directHops, packet.update.id != selfId else { return }
        links[packet.update.id] = (link, now)
    }

    /// Neighbors heard directly within the window over links that are still open.
    public mutating func neighbors(
        at now: Date = Date(),
        isLinkOpen: (String) -> Bool,
        rssi: (String) -> Int?
    ) -> [NeighborObservation] {
        links = links.filter { now.timeIntervalSince($0.value.heardAt) <= Self.window && isLinkOpen($0.value.link) }
        return links.keys.sorted().prefix(DashboardContract.maxNeighbors).compactMap { id in
            guard let entry = links[id] else { return nil }
            let strength = rssi(entry.link).flatMap { DashboardContract.rssiRange.contains($0) ? $0 : nil }
            let age = max(0, Int((now.timeIntervalSince(entry.heardAt) * 1000).rounded()))
            return NeighborObservation(id: id, rssi: strength, ageMs: age)
        }
    }

    public mutating func reset() {
        links.removeAll()
    }
}
