import Foundation

/// One phone's Bluetooth LE view of a nearby phone at one moment, taken about once per second
/// for the shared `PeerObservation` contract.
///
/// RSSI here describes link quality only. It swings by 10 dB or more with body position, phone
/// model, orientation and surroundings, so nothing in this layer turns it into a distance; a
/// positioning engine that wants a range must calibrate its own model and own that uncertainty.
public struct PeerSighting: Equatable {
    public enum Channel: String, Codable {
        /// `readRSSI` on a connection where this phone is the central, about 1 Hz.
        case connection
        /// Scan callbacks from advertising packets: irregular, and coalesced in the background.
        case advertisement
    }

    public enum LinkState: String, Codable {
        /// Seen advertising, no mesh link.
        case advertised
        /// Connecting, discovering or waiting for the Hello.
        case linking
        /// Subscribed with a valid Hello: `peerId` is the app device ID.
        case ready
        /// The link just closed; the samples are the last ones heard on it.
        case lost
    }

    public let observerId: String
    /// App device ID, learned from the link Hello. Nil for a phone only seen advertising.
    public let peerId: String?
    /// Core Bluetooth identifier on this phone only. It differs per observer and rotates, so it is
    /// for debugging and never leaves the phone as an identity.
    public let transportHandle: UUID?
    public let label: String?
    public let channel: Channel
    public let linkState: LinkState
    /// Raw samples since the previous snapshot of this peer and channel, oldest first.
    public let samples: [RSSISample]
    /// Raw samples since the previous snapshot that did not fit in `samples`.
    public let droppedSamples: Int
    /// Exponential average with a 3 s time constant.
    public let smoothedRSSI: Double?
    /// Population deviation over the last `deviationSampleCount` samples.
    public let rssiStandardDeviation: Double?
    public let deviationSampleCount: Int
    /// Samples accepted since this phone started tracking the peer on this channel.
    public let sampleCount: Int
    public let lastSampleAt: Date?
    /// Last mesh frame received from the peer; ready links only.
    public let lastHeardAt: Date?
    /// Advertised transmit power, when the advertisement carries it. iPhones normally don't.
    public let txPower: Int?
    /// When the snapshot was taken, on this phone's clock.
    public let timestamp: Date

    public init(
        observerId: String,
        peerId: String?,
        transportHandle: UUID?,
        label: String?,
        channel: Channel,
        linkState: LinkState,
        samples: [RSSISample],
        droppedSamples: Int,
        smoothedRSSI: Double?,
        rssiStandardDeviation: Double?,
        deviationSampleCount: Int,
        sampleCount: Int,
        lastSampleAt: Date?,
        lastHeardAt: Date?,
        txPower: Int?,
        timestamp: Date
    ) {
        self.observerId = observerId
        self.peerId = peerId
        self.transportHandle = transportHandle
        self.label = label
        self.channel = channel
        self.linkState = linkState
        self.samples = samples
        self.droppedSamples = droppedSamples
        self.smoothedRSSI = smoothedRSSI
        self.rssiStandardDeviation = rssiStandardDeviation
        self.deviationSampleCount = deviationSampleCount
        self.sampleCount = sampleCount
        self.lastSampleAt = lastSampleAt
        self.lastHeardAt = lastHeardAt
        self.txPower = txPower
        self.timestamp = timestamp
    }

    /// Takes a snapshot and clears the raw samples it reports, so the next snapshot carries only
    /// newer ones. Nil when the statistics never accepted a sample.
    public static func take(
        from statistics: inout RSSIStatistics,
        observerId: String,
        peerId: String?,
        transportHandle: UUID?,
        label: String? = nil,
        channel: Channel,
        linkState: LinkState,
        lastHeardAt: Date? = nil,
        txPower: Int? = nil,
        now: Date = Date()
    ) -> PeerSighting? {
        guard statistics.sampleCount > 0 else { return nil }
        let recent = statistics.takeRecentSamples()
        return PeerSighting(
            observerId: observerId, peerId: peerId, transportHandle: transportHandle, label: label,
            channel: channel, linkState: linkState, samples: recent.samples, droppedSamples: recent.dropped,
            smoothedRSSI: statistics.smoothed, rssiStandardDeviation: statistics.standardDeviation,
            deviationSampleCount: statistics.deviationSampleCount, sampleCount: statistics.sampleCount, lastSampleAt: statistics.lastSampleAt,
            lastHeardAt: lastHeardAt, txPower: txPower, timestamp: now
        )
    }

    /// Seconds since the latest RSSI sample, or nil without one.
    public func sampleAge(at now: Date = Date()) -> TimeInterval? {
        lastSampleAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Default `maxAge` of an observation: RSSI older than this says little about the link now.
    public static let observationMaxAge: TimeInterval = 6
    public static let algorithm = "ble-sighting@1"

    /// The shared-contract record for this snapshot, or nil when it has no sample or would not
    /// validate. `timestamp` is the newest sample; the age at handoff is the time since then.
    public func observation(frameId: String, peerModel: String? = nil,
                            maxAge: TimeInterval = observationMaxAge) -> PeerObservation? {
        guard let lastSampleAt else { return nil }
        let rssiRange = Double(DashboardContract.rssiRange.lowerBound)...Double(DashboardContract.rssiRange.upperBound)
        let span = (samples.first?.at).flatMap { first in samples.last.map { $0.at.timeIntervalSince(first) } } ?? 0
        let observation = PeerObservation(
            observerId: observerId,
            peerId: peerId,
            timestamp: lastSampleAt.timeIntervalSince1970,
            frameId: frameId,
            channel: channel == .connection ? .connection : .advertisement,
            linkState: {
                switch linkState {
                case .advertised: return .advertisementOnly
                case .linking: return .connecting
                case .ready: return .ready
                case .lost: return .lost
                }
            }(),
            rawRSSI: samples.map { Double($0.rssi) },
            window: min(60, max(0, span)),
            smoothedRSSI: smoothedRSSI.map { min(rssiRange.upperBound, max(rssiRange.lowerBound, $0)) },
            uncertainty: .init(
                stdDevDb: deviationSampleCount >= 2 ? rssiStandardDeviation.map { min(60, $0) } : nil,
                sampleCount: max(deviationSampleCount, samples.count)),
            txPower: txPower,
            peerModel: peerModel,
            freshness: Freshness(ageAtHandoff: max(0, timestamp.timeIntervalSince(lastSampleAt)), maxAge: maxAge),
            provenance: Provenance(producerId: observerId, algorithm: Self.algorithm, gnssDependent: false)
        )
        return (try? observation.validate()) == nil ? nil : observation
    }
}
