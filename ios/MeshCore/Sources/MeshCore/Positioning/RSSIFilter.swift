import Foundation

extension Positioning {
    /// How an RSSI value was measured. iPhones read a few dB apart on the two, and relayed values are
    /// already smoothed by the sending phone, so each is calibrated and weighted separately.
    public enum RSSIChannel: String, Codable, CaseIterable {
        /// Advertisement RSSI heard while scanning: irregular rate, three advertising channels.
        case advertisement
        /// `readRSSI` on a connection where this phone is the central, about 1 Hz.
        case connection
        /// The peer's raw readings of our signal, relayed in its `PeerObservation`: the same link
        /// seen from the other end (shared shadowing, independent fading, the peer's radio).
        case reciprocal
        /// A neighbour's reading of its link to us, relayed in its report (`NeighborObservation`):
        /// exponentially smoothed on that phone, so it is one correlated sample, not raw data.
        case relayedSmoothed
    }

    /// One RSSI reading of the link between this phone and `peerId`.
    public struct RSSISample: Equatable, Codable {
        public let peerId: String
        public let rssi: Double
        /// Local monotonic seconds when the radio measured it.
        public let t: TimeInterval
        public let channel: RSSIChannel

        public init(peerId: String, rssi: Double, t: TimeInterval, channel: RSSIChannel) {
            self.peerId = peerId
            self.rssi = rssi
            self.t = t
            self.channel = channel
        }
    }

    /// Robust summary of one window of RSSI from one peer on one channel.
    public struct RSSIWindow: Equatable {
        public let peerId: String
        public let channel: RSSIChannel
        public let median: Double
        /// 1.4826 × median absolute deviation of the kept samples, dB.
        public let spread: Double
        public let count: Int
        /// Samples dropped as Hampel outliers (more than `hampelK` robust sigmas from the median).
        public let rejected: Int
        public let start: TimeInterval
        public let end: TimeInterval
        /// The time the window stands for: the median sample time.
        public let t: TimeInterval
    }

    /// Per-peer RSSI filter: a sliding time window of raw samples, impossible values and Hampel
    /// outliers removed, summarised by the median. A median rather than the mean or the EMA in
    /// `RSSIStatistics`: one deep fade or reflection spike moves a mean by several dB and leaves the
    /// median alone. RSSI stays a noisy proxy for distance; the path-loss model carries its spread.
    public struct RSSIMedianFilter {
        public var window: TimeInterval
        public var maxSamples: Int
        public var minSamples: Int
        public var hampelK: Double

        private struct Key: Hashable {
            let peerId: String
            let channel: RSSIChannel
        }

        private var buffers: [Key: [RSSISample]] = [:]
        /// Newest sample time already handed out by `takeWindow`, so each sample is used once.
        private var consumedUntil: [Key: TimeInterval] = [:]

        public init(window: TimeInterval = 4, maxSamples: Int = 64, minSamples: Int = 3, hampelK: Double = 3) {
            self.window = window
            self.maxSamples = maxSamples
            self.minSamples = minSamples
            self.hampelK = hampelK
        }

        /// iOS reports 127 when it has no reading; real values sit in -127...20 dBm.
        public static func isValid(_ rssi: Double) -> Bool { rssi.isFinite && rssi != 127 && (-127...20).contains(rssi) }

        /// Adds a sample; false if it is invalid or older than samples already handed out.
        @discardableResult
        public mutating func add(_ sample: RSSISample) -> Bool {
            guard Self.isValid(sample.rssi), sample.t.isFinite else { return false }
            let key = Key(peerId: sample.peerId, channel: sample.channel)
            if let done = consumedUntil[key], sample.t <= done { return false }
            var buffer = buffers[key] ?? []
            // Keep time order even if samples arrive slightly out of order.
            let index = buffer.lastIndex { $0.t <= sample.t }.map { $0 + 1 } ?? 0
            buffer.insert(sample, at: index)
            if buffer.count > maxSamples { buffer.removeFirst(buffer.count - maxSamples) }
            buffers[key] = buffer
            return true
        }

        /// The current sliding window (overlapping with earlier calls), for display and calibration.
        public func current(peerId: String, channel: RSSIChannel, now: TimeInterval) -> RSSIWindow? {
            let key = Key(peerId: peerId, channel: channel)
            let samples = (buffers[key] ?? []).filter { $0.t > now - window && $0.t <= now }
            return Self.summarize(samples, peerId: peerId, channel: channel, minSamples: minSamples, hampelK: hampelK)
        }

        /// Non-overlapping windows for the filter: once a peer has `window` seconds (or `maxSamples`)
        /// of unused samples, returns their summary and marks them used. Samples older than two windows
        /// are dropped unused as stale. Returns windows of every peer and channel, oldest first.
        public mutating func takeWindows(now: TimeInterval) -> [RSSIWindow] {
            var out: [RSSIWindow] = []
            for key in buffers.keys.sorted(by: { ($0.peerId, $0.channel.rawValue) < ($1.peerId, $1.channel.rawValue) }) {
                var buffer = buffers[key] ?? []
                buffer.removeAll { $0.t < now - 2 * window }
                let done = consumedUntil[key] ?? -Double.infinity
                let fresh = buffer.filter { $0.t > done && $0.t <= now }
                buffers[key] = buffer
                guard let first = fresh.first, let last = fresh.last else { continue }
                // Relayed values are already averaged on the sender: each one is a window by itself.
                let ready = key.channel == .relayedSmoothed
                    || now - first.t >= window || fresh.count >= maxSamples
                guard ready else { continue }
                consumedUntil[key] = last.t
                let minimum = key.channel == .relayedSmoothed ? 1 : minSamples
                if let w = Self.summarize(fresh, peerId: key.peerId, channel: key.channel, minSamples: minimum, hampelK: hampelK) {
                    out.append(w)
                }
            }
            // Total order, so replays are repeatable whatever the dictionary order.
            return out.sorted { ($0.t, $0.peerId, $0.channel.rawValue) < ($1.t, $1.peerId, $1.channel.rawValue) }
        }

        /// Forgets peers with nothing newer than `maxAge`.
        public mutating func prune(now: TimeInterval, maxAge: TimeInterval = 60) {
            buffers = buffers.filter { ($0.value.last?.t ?? -Double.infinity) >= now - maxAge }
            consumedUntil = consumedUntil.filter { buffers[$0.key] != nil }
        }

        /// Median of a set of samples after dropping Hampel outliers; nil below `minSamples`.
        public static func summarize(_ samples: [RSSISample], peerId: String, channel: RSSIChannel,
                                     minSamples: Int = 3, hampelK: Double = 3) -> RSSIWindow? {
            guard samples.count >= max(1, minSamples), let first = samples.first, let last = samples.last,
                  let center = Stats.median(samples.map(\.rssi)) else { return nil }
            let spread = Stats.robustSpread(samples.map(\.rssi), around: center)
            // Below 1 dB of spread the integer steps of RSSI make the test meaningless.
            let limit = hampelK * max(1, spread)
            let kept = samples.filter { abs($0.rssi - center) <= limit }
            guard kept.count >= max(1, minSamples), let median = Stats.median(kept.map(\.rssi)) else { return nil }
            return RSSIWindow(peerId: peerId, channel: channel, median: median,
                              spread: Stats.robustSpread(kept.map(\.rssi), around: median),
                              count: kept.count, rejected: samples.count - kept.count,
                              start: first.t, end: last.t, t: Stats.median(kept.map(\.t)) ?? last.t)
        }
    }
}

extension Positioning {
    /// Log-distance path loss, RSSI = p0 - 10 n log10(d), with calibrated spreads. The spreads are
    /// the honest part: outdoors one window median still scatters by several dB, which is a factor of
    /// ~1.7 in distance per sigma, so a range from RSSI is an interval, never a number.
    public struct PathLossModel: Equatable, Codable {
        /// Median RSSI at 1 m, dBm.
        public var p0: Double
        /// Path-loss exponent.
        public var n: Double
        /// Spread of window medians at one fixed spot (fading left after the median), dB.
        public var sigmaFast: Double
        /// Spread of the local mean from spot to spot around the fitted line (shadowing, body,
        /// orientation, phone model), dB. It persists while neither phone moves.
        public var sigmaShadow: Double
        /// Distance over which shadowing decorrelates as either phone moves, m.
        public var decorrelationDistance: Double
        /// Closer than this, readings saturate and stop tracking distance, m.
        public var minDistance: Double
        /// Beyond this, phones practically never hear each other outdoors, m.
        public var maxRange: Double
        /// Weakest reading the receiver reports, dBm (nil: -100). Near it only the fades up are
        /// heard, so a median there reads too strong and says "far", not how far.
        public var sensitivity: Double?
        /// Where the numbers came from, e.g. "default-outdoor" or "calibrated 2026-10-24 ...".
        public var source: String

        public init(p0: Double, n: Double, sigmaFast: Double, sigmaShadow: Double,
                    decorrelationDistance: Double = 3, minDistance: Double = 0.5, maxRange: Double = 100,
                    source: String) {
            self.p0 = p0
            self.n = n
            self.sigmaFast = sigmaFast
            self.sigmaShadow = sigmaShadow
            self.decorrelationDistance = decorrelationDistance
            self.minDistance = minDistance
            self.maxRange = maxRange
            self.source = source
        }

        /// Uncalibrated phone-to-phone outdoors, matching `RadioModel.outdoors` (total spread ~5.6 dB).
        /// Replace with a `CalibrationSession` fit for the phones actually used.
        public static let defaultOutdoor = PathLossModel(p0: -59, n: 2.5, sigmaFast: 2.5, sigmaShadow: 5,
                                                         source: "default-outdoor")

        public var totalSigma: Double { (sigmaFast * sigmaFast + sigmaShadow * sigmaShadow).squareRoot() }

        /// Within one total sigma of the sensitivity: the reading is censored, distance only bounded below.
        public func isCensored(rssi: Double) -> Bool { rssi - (sensitivity ?? -100) < totalSigma }

        /// dB of RSSI per natural-log unit of distance.
        var slope: Double { 10 * n / log(10) }

        public func expectedRSSI(distance d: Double) -> Double { p0 - 10 * n * log10(max(minDistance, d)) }

        /// The median distance for a reading (log-normal), m.
        public func medianDistance(rssi: Double) -> Double {
            min(maxRange, max(minDistance, pow(10, (p0 - rssi) / (10 * n))))
        }

        /// Distance interval holding ~`z`-sigma of the belief for a reading, using the total spread
        /// (fading and shadowing) unless told otherwise. z = 1.96 gives 95 %.
        public func distanceInterval(rssi: Double, z: Double = 1.96, sigma: Double? = nil) -> ClosedRange<Double> {
            let s = sigma ?? totalSigma
            let lo = pow(10, (p0 - rssi - z * s) / (10 * n))
            let hi = isCensored(rssi: rssi) ? maxRange : pow(10, (p0 - rssi + z * s) / (10 * n))
            return max(0, min(lo, maxRange))...min(maxRange, max(hi, minDistance))
        }
    }
}
