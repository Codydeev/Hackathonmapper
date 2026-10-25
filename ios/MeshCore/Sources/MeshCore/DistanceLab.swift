import Foundation

/// The ways this app can turn what two phones measure into a distance, compared side by side on
/// the Track tab. The map uses `signalMap`; the others are there to test it, and each other, against
/// a tape measure.
public enum DistanceMethod: String, CaseIterable, Codable, Identifiable {
    /// Nearby Interaction distance this phone measured (iPhone 11 or newer on both ends, not SE).
    case uwb
    /// The distance on the signal map: every link and position solved together. What the map draws.
    case signalMap
    /// Both ends' smoothed RSSI averaged, through the radio model the signal map calibrated from UWB
    /// distances and placed phones.
    case rssiCalibrated
    /// This phone's smoothed RSSI through the default radio model (-59 dBm at 1 m, n 2.5).
    case rssiDefault
    /// GhostCore's filter: a 4 s median of this phone's raw RSSI after Hampel outlier removal,
    /// through its outdoor path-loss model.
    case rssiMedian
    /// The distance between both phones' GPS positions: an outdoor reference, good to their accuracy.
    case gps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .uwb: return "UWB"
        case .signalMap: return "Signal map"
        case .rssiCalibrated: return "RSSI, calibrated, both ends"
        case .rssiDefault: return "RSSI, default model"
        case .rssiMedian: return "RSSI, median filter"
        case .gps: return "GPS"
        }
    }
}

/// One method's distance for one link, with the 95 % interval where the method has one.
public struct DistanceReading: Equatable {
    public let method: DistanceMethod
    public let meters: Double
    public let low: Double?
    public let high: Double?

    public init(method: DistanceMethod, meters: Double, low: Double? = nil, high: Double? = nil) {
        self.method = method
        self.meters = meters
        self.low = low
        self.high = high
    }

    /// Whether `distance` lies inside the 95 % interval; nil when the method has none.
    public func covers(_ distance: Double) -> Bool? {
        guard let low, let high else { return nil }
        return distance >= low && distance <= high
    }
}

/// What this phone knows this second about its link to one neighbor.
public struct DistanceInputs: Equatable {
    /// Fresh UWB distance this phone measured, m.
    public var uwb: Double?
    /// This phone's smoothed RSSI of the neighbor (connection where it is the central, else advertisements).
    public var smoothedRSSI: Double?
    /// The neighbor's own reading of the link, from its latest report.
    public var peerRSSI: Double?
    /// The distance between the two on the signal map, m.
    public var signalMap: Double?
    /// This phone's and the neighbor's GPS positions with their 95 % radii.
    public var ownGPS: FloorPoint?
    public var ownGPSR95: Double?
    public var peerGPS: FloorPoint?
    public var peerGPSR95: Double?

    public init(uwb: Double? = nil, smoothedRSSI: Double? = nil, peerRSSI: Double? = nil, signalMap: Double? = nil,
                ownGPS: FloorPoint? = nil, ownGPSR95: Double? = nil, peerGPS: FloorPoint? = nil, peerGPSR95: Double? = nil) {
        self.uwb = uwb
        self.smoothedRSSI = smoothedRSSI
        self.peerRSSI = peerRSSI
        self.signalMap = signalMap
        self.ownGPS = ownGPS
        self.ownGPSR95 = ownGPSR95
        self.peerGPS = peerGPS
        self.peerGPSR95 = peerGPSR95
    }
}

/// Computes every method's distance for a link. Holds the raw-RSSI median filter, so feed it this
/// phone's raw samples of each neighbor as they arrive (`add`), then ask for `readings`.
public struct DistanceLab {
    public var defaultRadio: RadioModel
    /// The radio model the signal map calibrated this second.
    public var calibratedRadio: RadioModel
    public var medianModel: Positioning.PathLossModel
    private var filter = Positioning.RSSIMedianFilter()
    /// Newest raw sample time already added per neighbor, so resent sample lists add nothing twice.
    private var newest: [String: TimeInterval] = [:]

    public init(defaultRadio: RadioModel = .standard, medianModel: Positioning.PathLossModel = .defaultOutdoor) {
        self.defaultRadio = defaultRadio
        calibratedRadio = defaultRadio
        self.medianModel = medianModel
    }

    /// Adds this phone's raw RSSI readings of `peerId` (times in seconds), skipping ones already added.
    public mutating func add(rawRSSI samples: [(rssi: Double, t: TimeInterval)], from peerId: String) {
        var latest = newest[peerId] ?? -Double.infinity
        for sample in samples.sorted(by: { $0.t < $1.t }) where sample.t > latest {
            filter.add(Positioning.RSSISample(peerId: peerId, rssi: sample.rssi, t: sample.t, channel: .connection))
            latest = sample.t
        }
        newest[peerId] = latest
    }

    /// Forgets neighbors with nothing newer than a minute.
    public mutating func prune(now: TimeInterval) {
        filter.prune(now: now)
        newest = newest.filter { $0.value >= now - 60 }
    }

    /// Every method that has what it needs this second, in `DistanceMethod` order.
    public func readings(for peerId: String, inputs: DistanceInputs, now: TimeInterval) -> [DistanceReading] {
        var out: [DistanceReading] = []
        if let uwb = inputs.uwb, uwb.isFinite, uwb >= 0 {
            let spread = 1.96 * SignalMap.uwbSigma
            out.append(DistanceReading(method: .uwb, meters: uwb, low: max(0, uwb - spread), high: uwb + spread))
        }
        if let map = inputs.signalMap, map.isFinite {
            out.append(DistanceReading(method: .signalMap, meters: map))
        }
        let ends = [inputs.smoothedRSSI, inputs.peerRSSI].compactMap { $0 }.filter(\.isFinite)
        if !ends.isEmpty {
            out.append(Self.rssiReading(.rssiCalibrated, rssi: ends.reduce(0.0, +) / Double(ends.count), radio: calibratedRadio))
        }
        if let own = inputs.smoothedRSSI, own.isFinite {
            out.append(Self.rssiReading(.rssiDefault, rssi: own, radio: defaultRadio))
        }
        if let window = filter.current(peerId: peerId, channel: .connection, now: now) {
            let interval = medianModel.distanceInterval(rssi: window.median)
            out.append(DistanceReading(method: .rssiMedian, meters: medianModel.medianDistance(rssi: window.median),
                                       low: interval.lowerBound, high: interval.upperBound))
        }
        if let own = inputs.ownGPS, let peer = inputs.peerGPS {
            let d = hypot(own.x - peer.x, own.z - peer.z)
            let spread = ((inputs.ownGPSR95 ?? 0) * (inputs.ownGPSR95 ?? 0) + (inputs.peerGPSR95 ?? 0) * (inputs.peerGPSR95 ?? 0)).squareRoot()
            out.append(DistanceReading(method: .gps, meters: d, low: max(0, d - spread), high: d + spread))
        }
        return out
    }

    /// Log-normal RSSI range: the median distance, and the interval of ±1.96 sigma in dB.
    static func rssiReading(_ method: DistanceMethod, rssi: Double, radio: RadioModel) -> DistanceReading {
        let spread = 1.96 * radio.sigma
        return DistanceReading(method: method, meters: SignalMap.range(forRSSI: rssi, radio: radio),
                               low: SignalMap.range(forRSSI: rssi + spread, radio: radio),
                               high: SignalMap.range(forRSSI: rssi - spread, radio: radio))
    }
}

/// A tape-measure trial: two phones held at a known distance while every method's reading is
/// recorded, then scored. The CSV goes to a spreadsheet for longer comparisons.
public struct DistanceTrial: Equatable {
    public struct Sample: Equatable {
        /// Seconds since the trial started.
        public let t: TimeInterval
        public let meters: [DistanceMethod: Double]
        /// Whether the true distance was inside each method's 95 % interval.
        public let covered: [DistanceMethod: Bool]
    }

    public struct Score: Equatable, Identifiable {
        public let method: DistanceMethod
        public let count: Int
        /// Mean of (reading − true), m: positive reads long.
        public let bias: Double
        public let meanAbsoluteError: Double
        public let rmse: Double
        /// Share of readings whose 95 % interval held the true distance; nil without intervals.
        public let coverage: Double?
        public var id: String { method.rawValue }
    }

    public let peerId: String
    public let peerLabel: String
    public let trueDistance: Double
    public let startedAt: TimeInterval
    public private(set) var samples: [Sample] = []

    public init(peerId: String, peerLabel: String, trueDistance: Double, startedAt: TimeInterval) {
        self.peerId = peerId
        self.peerLabel = peerLabel
        self.trueDistance = trueDistance
        self.startedAt = startedAt
    }

    public mutating func record(_ readings: [DistanceReading], at t: TimeInterval) {
        guard !readings.isEmpty else { return }
        var meters: [DistanceMethod: Double] = [:]
        var covered: [DistanceMethod: Bool] = [:]
        for reading in readings {
            meters[reading.method] = reading.meters
            covered[reading.method] = reading.covers(trueDistance)
        }
        samples.append(Sample(t: t - startedAt, meters: meters, covered: covered))
    }

    /// One score per method with readings, in `DistanceMethod` order.
    public var scores: [Score] {
        DistanceMethod.allCases.compactMap { method in
            let errors = samples.compactMap { $0.meters[method] }.map { $0 - trueDistance }
            guard !errors.isEmpty else { return nil }
            let n = Double(errors.count)
            let hits = samples.compactMap { $0.covered[method] }
            return Score(method: method, count: errors.count,
                         bias: errors.reduce(0.0, +) / n,
                         meanAbsoluteError: errors.map(abs).reduce(0.0, +) / n,
                         rmse: (errors.map { $0 * $0 }.reduce(0.0, +) / n).squareRoot(),
                         coverage: hits.isEmpty ? nil : Double(hits.filter { $0 }.count) / Double(hits.count))
        }
    }

    /// One row per sample: time, neighbor, true distance, then each method's reading (empty when it had none).
    public func csv() -> String {
        var lines = ["t_s,peer,true_m," + DistanceMethod.allCases.map(\.rawValue).joined(separator: ",")]
        let peer = peerLabel.contains(",") ? "\"\(peerLabel.replacingOccurrences(of: "\"", with: "\"\""))\"" : peerLabel
        for sample in samples {
            let values = DistanceMethod.allCases.map { sample.meters[$0].map { String(format: "%.2f", $0) } ?? "" }
            lines.append([String(format: "%.1f", sample.t), peer, String(format: "%.2f", trueDistance)].joined(separator: ",")
                         + "," + values.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
