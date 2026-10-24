import Foundation

// All access, including reading latest, belongs on the main thread.
public final class MeshStore {
    public private(set) var latest: [String: DeviceUpdate] = [:]
    public private(set) var relayPackets: [String: MeshPacket] = [:]
    /// Local receive time of each origin's latest accepted report.
    public private(set) var receivedAt: [String: Date] = [:]

    private let selfId: String
    private var frameId: String
    private var epochs: [String: Set<UUID>] = [:]
    private static let maximumDevices = 100
    // Includes the current epoch. Never evict retired epochs to admit another one.
    private static let maximumEpochsPerDevice = 100

    /// `selfId` is this phone's device ID. Relays of other phones' reports append it to the path.
    public init(frameId: String, selfId: String) {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        self.frameId = frameId
        self.selfId = selfId
    }

    public func ingest(_ packet: MeshPacket, at now: Date = Date()) throws -> MeshPacket? {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        try packet.validate()
        guard packet.frameId == frameId else {
            throw MeshCoreError.frameMismatch
        }
        // This copy already passed through this phone.
        guard !packet.path.contains(selfId) else { return nil }

        let update = packet.update
        // Validation above guarantees both UUID conversions succeed.
        guard let epoch = UUID(uuidString: update.epochId) else {
            throw MeshCoreError.invalidUpdate
        }
        var knownEpochs = epochs[update.id] ?? []
        if let previous = latest[update.id] {
            if UUID(uuidString: previous.epochId) == epoch {
                guard update.sequence > previous.sequence else { return nil }
            } else {
                guard !knownEpochs.contains(epoch) else { return nil }
                guard knownEpochs.count < Self.maximumEpochsPerDevice else {
                    throw MeshCoreError.epochCapacityReached
                }
            }
        } else {
            guard latest.count < Self.maximumDevices else {
                throw MeshCoreError.deviceCapacityReached
            }
        }

        knownEpochs.insert(epoch)
        epochs[update.id] = knownEpochs
        latest[update.id] = update
        receivedAt[update.id] = now
        // This phone's own reports leave with an empty path; relays add themselves.
        let path = update.id == selfId ? packet.path : packet.path + [selfId]
        guard packet.hopsRemaining > 0, path.count <= MeshProtocol.maxPathLength else {
            relayPackets.removeValue(forKey: update.id)
            return nil
        }
        let relay = MeshPacket(
            frameId: frameId,
            hopsRemaining: packet.hopsRemaining - 1,
            update: update,
            path: path
        )
        relayPackets[update.id] = relay
        return relay
    }

    /// Whether the origin's latest report arrived within `maxAge`. Stale reports are kept so
    /// retired epochs stay retired, but should no longer be resent or uploaded.
    public func isFresh(_ id: String, within maxAge: TimeInterval, at now: Date = Date()) -> Bool {
        guard let receivedAt = receivedAt[id] else { return false }
        return now.timeIntervalSince(receivedAt) <= maxAge
    }

    public func reset(frameId: String) {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        self.frameId = frameId
        latest.removeAll()
        relayPackets.removeAll()
        receivedAt.removeAll()
        epochs.removeAll()
    }
}
