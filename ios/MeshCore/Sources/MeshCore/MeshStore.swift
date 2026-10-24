import Foundation

// All access, including reading latest, belongs on the main thread.
public final class MeshStore {
    public private(set) var latest: [String: DeviceUpdate] = [:]
    public private(set) var relayPackets: [String: MeshPacket] = [:]

    private var frameId: String
    private var epochs: [String: Set<UUID>] = [:]
    private static let maximumDevices = 100
    // Includes the current epoch. Never evict retired epochs to admit another one.
    private static let maximumEpochsPerDevice = 100

    public init(frameId: String) {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        self.frameId = frameId
    }

    public func ingest(_ packet: MeshPacket) throws -> MeshPacket? {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        try packet.validate()
        guard packet.frameId == frameId else {
            throw MeshCoreError.frameMismatch
        }

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
        guard packet.hopsRemaining > 0 else {
            relayPackets.removeValue(forKey: update.id)
            return nil
        }
        let relay = MeshPacket(
            frameId: frameId,
            hopsRemaining: packet.hopsRemaining - 1,
            update: update
        )
        relayPackets[update.id] = relay
        return relay
    }

    public func reset(frameId: String) {
        precondition(Thread.isMainThread, "MeshStore requires the main thread")
        self.frameId = frameId
        latest.removeAll()
        relayPackets.removeAll()
        epochs.removeAll()
    }
}
