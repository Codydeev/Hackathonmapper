package com.hackathonmapper.meshcore

import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One phone's Bluetooth LE view of a nearby phone at one moment, taken about once per second
 * for the shared `PeerObservation` contract.
 *
 * RSSI here describes link quality only. It swings by 10 dB or more with body position, phone
 * model, orientation and surroundings, so nothing in this layer turns it into a distance; a
 * positioning engine that wants a range must calibrate its own model and own that uncertainty.
 *
 * Dates are Unix seconds (Swift `Date`); `transportHandle` is a string (Swift `UUID`).
 */
data class PeerSighting(
    val observerId: String,
    /** App device ID, learned from the link Hello. Null for a phone only seen advertising. */
    val peerId: String?,
    /**
     * Transport identifier on this phone only (a BLE address on Android, a Core Bluetooth
     * identifier on iOS). It differs per observer and rotates, so it is for debugging and never
     * leaves the phone as an identity.
     */
    val transportHandle: String?,
    val label: String?,
    val channel: Channel,
    val linkState: LinkState,
    /** Raw samples since the previous snapshot of this peer and channel, oldest first. */
    val samples: List<RSSISample>,
    /** Raw samples since the previous snapshot that did not fit in `samples`. */
    val droppedSamples: Int,
    /** Exponential average with a 3 s time constant. */
    val smoothedRSSI: Double?,
    /** Population deviation over the last `deviationSampleCount` samples. */
    val rssiStandardDeviation: Double?,
    val deviationSampleCount: Int,
    /** Samples accepted since this phone started tracking the peer on this channel. */
    val sampleCount: Int,
    val lastSampleAt: Double?,
    /** Last mesh frame received from the peer; ready links only. */
    val lastHeardAt: Double?,
    /** Advertised transmit power, when the advertisement carries it. iPhones normally don't. */
    val txPower: Int?,
    /** When the snapshot was taken, on this phone's clock. */
    val timestamp: Double,
) {
    @Serializable
    enum class Channel(val rawValue: String) {
        /** `readRSSI` on a connection where this phone is the central, about 1 Hz. */
        @SerialName("connection") connection("connection"),
        /** Scan callbacks from advertising packets: irregular, and coalesced in the background. */
        @SerialName("advertisement") advertisement("advertisement"),
    }

    @Serializable
    enum class LinkState(val rawValue: String) {
        /** Seen advertising, no mesh link. */
        @SerialName("advertised") advertised("advertised"),
        /** Connecting, discovering or waiting for the Hello. */
        @SerialName("linking") linking("linking"),
        /** Subscribed with a valid Hello: `peerId` is the app device ID. */
        @SerialName("ready") ready("ready"),
        /** The link just closed; the samples are the last ones heard on it. */
        @SerialName("lost") lost("lost"),
    }

    companion object {
        /** Default `maxAge` of an observation: RSSI older than this says little about the link now. */
        const val observationMaxAge: TimeInterval = 6.0
        const val algorithm = "ble-sighting@1"

        /**
         * Takes a snapshot and clears the raw samples it reports, so the next snapshot carries only
         * newer ones. Null when the statistics never accepted a sample. Swift's `inout` statistics:
         * the instance passed in is mutated.
         */
        fun take(
            from: RSSIStatistics,
            observerId: String,
            peerId: String?,
            transportHandle: String?,
            label: String? = null,
            channel: Channel,
            linkState: LinkState,
            lastHeardAt: Double? = null,
            txPower: Int? = null,
            now: Double = currentTime(),
        ): PeerSighting? {
            val statistics = from
            if (statistics.sampleCount <= 0) return null
            val recent = statistics.takeRecentSamples()
            return PeerSighting(
                observerId = observerId, peerId = peerId, transportHandle = transportHandle, label = label,
                channel = channel, linkState = linkState, samples = recent.samples, droppedSamples = recent.dropped,
                smoothedRSSI = statistics.smoothed, rssiStandardDeviation = statistics.standardDeviation,
                deviationSampleCount = statistics.deviationSampleCount, sampleCount = statistics.sampleCount,
                lastSampleAt = statistics.lastSampleAt, lastHeardAt = lastHeardAt, txPower = txPower, timestamp = now,
            )
        }
    }

    /** Seconds since the latest RSSI sample, or null without one. */
    fun sampleAge(now: Double = currentTime()): TimeInterval? = lastSampleAt?.let { max(0.0, now - it) }

    /**
     * The shared-contract record for this snapshot, or null when it has no sample or would not
     * validate. `timestamp` is the newest sample; the age at handoff is the time since then.
     */
    fun observation(
        frameId: String,
        peerModel: String? = null,
        maxAge: TimeInterval = observationMaxAge,
    ): PeerObservation? {
        val lastSampleAt = lastSampleAt ?: return null
        val lower = DashboardContract.rssiRange.first.toDouble()
        val upper = DashboardContract.rssiRange.last.toDouble()
        val first = samples.firstOrNull()
        val last = samples.lastOrNull()
        val span = if (first != null && last != null) last.at - first.at else 0.0
        val observation = PeerObservation(
            observerId = observerId,
            peerId = peerId,
            timestamp = lastSampleAt,
            frameId = frameId,
            channel = if (channel == Channel.connection) PeerObservation.Channel.connection else PeerObservation.Channel.advertisement,
            linkState = when (linkState) {
                LinkState.advertised -> PeerObservation.LinkState.advertisementOnly
                LinkState.linking -> PeerObservation.LinkState.connecting
                LinkState.ready -> PeerObservation.LinkState.ready
                LinkState.lost -> PeerObservation.LinkState.lost
            },
            rawRSSI = samples.map { it.rssi.toDouble() },
            window = min(60.0, max(0.0, span)),
            smoothedRSSI = smoothedRSSI?.let { min(upper, max(lower, it)) },
            uncertainty = PeerObservation.Uncertainty(
                stdDevDb = if (deviationSampleCount >= 2) rssiStandardDeviation?.let { min(60.0, it) } else null,
                sampleCount = max(deviationSampleCount, samples.size),
            ),
            txPower = txPower,
            peerModel = peerModel,
            freshness = Freshness(ageAtHandoff = max(0.0, timestamp - lastSampleAt), maxAge = maxAge),
            provenance = Provenance(producerId = observerId, algorithm = algorithm, gnssDependent = false),
        )
        return try {
            observation.validate()
            observation
        } catch (e: Exception) {
            null
        }
    }
}
