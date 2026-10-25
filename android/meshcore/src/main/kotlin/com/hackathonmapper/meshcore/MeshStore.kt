package com.hackathonmapper.meshcore

/**
 * All access, including reading latest, belongs on the main thread. (Swift asserts this with a
 * precondition; MeshCore is plain JVM, so the Android caller keeps to the main looper.)
 *
 * `latest`, `relayPackets` and `receivedAt` are immutable snapshots replaced on every change, so a
 * caller holding one sees a value copy as with Swift dictionaries.
 *
 * `selfId` is this phone's device ID. Relays of other phones' reports append it to the path.
 */
class MeshStore(frameId: String, private val selfId: String) {
    var latest: Map<String, DeviceUpdate> = emptyMap()
        private set
    var relayPackets: Map<String, MeshPacket> = emptyMap()
        private set
    /** Local receive time of each origin's latest accepted report. */
    var receivedAt: Map<String, Double> = emptyMap()
        private set

    private var frameId: String = frameId
    /** Canonical (uppercase) epoch UUIDs per device. */
    private val epochs: MutableMap<String, MutableSet<String>> = HashMap()

    private companion object {
        const val maximumDevices = 100
        // Includes the current epoch. Never evict retired epochs to admit another one.
        const val maximumEpochsPerDevice = 100
    }

    fun ingest(packet: MeshPacket, now: Double = currentTime()): MeshPacket? {
        packet.validate()
        if (packet.frameId != frameId) throw MeshCoreError.frameMismatch
        // This copy already passed through this phone.
        if (packet.path.contains(selfId)) return null

        val update = packet.update
        // Validation above guarantees both UUID conversions succeed.
        val epoch = canonicalUUID(update.epochId) ?: throw MeshCoreError.invalidUpdate
        val knownEpochs = epochs[update.id] ?: HashSet()
        val previous = latest[update.id]
        if (previous != null) {
            if (canonicalUUID(previous.epochId) == epoch) {
                if (update.sequence <= previous.sequence) return null
            } else {
                if (knownEpochs.contains(epoch)) return null
                if (knownEpochs.size >= maximumEpochsPerDevice) throw MeshCoreError.epochCapacityReached
            }
        } else {
            if (latest.size >= maximumDevices) throw MeshCoreError.deviceCapacityReached
        }

        knownEpochs.add(epoch)
        epochs[update.id] = knownEpochs
        latest = latest + (update.id to update)
        receivedAt = receivedAt + (update.id to now)
        // This phone's own reports leave with an empty path; relays add themselves.
        val path = if (update.id == selfId) packet.path else packet.path + selfId
        if (!(packet.hopsRemaining > 0 && path.size <= MeshProtocol.maxPathLength)) {
            relayPackets = relayPackets - update.id
            return null
        }
        val relay = MeshPacket(
            frameId = frameId,
            hopsRemaining = packet.hopsRemaining - 1,
            update = update,
            path = path,
        )
        relayPackets = relayPackets + (update.id to relay)
        return relay
    }

    /**
     * Whether the origin's latest report arrived within `maxAge`. Stale reports are kept so
     * retired epochs stay retired, but should no longer be resent or uploaded.
     */
    fun isFresh(id: String, maxAge: TimeInterval, now: Double = currentTime()): Boolean {
        val receivedAt = receivedAt[id] ?: return false
        return now - receivedAt <= maxAge
    }

    fun reset(frameId: String) {
        this.frameId = frameId
        latest = emptyMap()
        relayPackets = emptyMap()
        receivedAt = emptyMap()
        epochs.clear()
    }
}
