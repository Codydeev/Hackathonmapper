import Foundation

/// Log-distance path loss: `rssi = referenceRSSI - 10·n·log10(d / 1 m)` plus device offsets.
/// Indoors the spread around it (`sigmaDB`) is several dB, so a single RSSI value is a rough
/// range at best; the estimator only uses it together with motion.
public struct PathLossModel: Equatable {
    /// Median RSSI at 1 m, dBm.
    public var referenceRSSI: Double
    public var exponent: Double
    /// Shadowing and multipath spread around the model, dB (log-normal fading).
    public var sigmaDB: Double

    /// The shared radio model (`RadioModel.standard`), so fusion and the signal map read RSSI alike.
    public static let `default` = PathLossModel(referenceRSSI: RadioModel.standard.p0, exponent: RadioModel.standard.n,
                                                sigmaDB: RadioModel.standard.sigma)
    /// Closer than this the model is meaningless (near field, antenna pattern).
    public static let minDistance = 0.5

    public init(referenceRSSI: Double, exponent: Double, sigmaDB: Double) {
        self.referenceRSSI = referenceRSSI
        self.exponent = exponent
        self.sigmaDB = sigmaDB
    }

    public func predictedRSSI(at distance: Double) -> Double {
        referenceRSSI - 10 * exponent * log10(max(distance, Self.minDistance))
    }

    /// Median distance for an RSSI value, meters.
    public func distance(for rssi: Double) -> Double {
        max(Self.minDistance, pow(10, (referenceRSSI - rssi) / (10 * exponent)))
    }

    /// dB per unit of ln(distance): an RSSI error of `e` dB scales distance by exp(e / dBPerLog).
    public var dBPerLogDistance: Double { 10 * exponent / log(10) }
}

/// RSSI an anchor reported for its direct link to another anchor; both positions are known.
public struct AnchorLinkObservation: Equatable {
    public let observer: String
    public let target: String
    public let distance: Double
    public let rssi: Double

    public init(observer: String, target: String, distance: Double, rssi: Double) {
        self.observer = observer
        self.target = target
        self.distance = distance
        self.rssi = rssi
    }
}

/// The room's path-loss model plus a per-device radio offset, fitted from anchor-to-anchor links
/// whose true distances are known. Phone models, cases and grips differ by several dB; a link
/// a→b sees about half of each end's combined TX+RX offset, `rssi_ab ≈ model(d) + (o_a + o_b) / 2`.
/// Priors keep the fit sane with few links: offsets shrink toward 0 dB and the model toward
/// `PathLossModel.default`.
public struct PathLossCalibration: Equatable {
    public var model: PathLossModel
    public var deviceOffsets: [String: Double]
    public var linkCount: Int

    public static let uncalibrated = PathLossCalibration(model: .default, deviceOffsets: [:], linkCount: 0)

    public init(model: PathLossModel, deviceOffsets: [String: Double], linkCount: Int) {
        self.model = model
        self.deviceOffsets = deviceOffsets
        self.linkCount = linkCount
    }

    /// The part of every link RSSI contributed by this device's radio (half its offset), dB.
    public func linkOffset(of id: String) -> Double { (deviceOffsets[id] ?? 0) / 2 }

    public static func fit(
        _ links: [AnchorLinkObservation],
        prior: PathLossModel = .default,
        referenceSigmaDB: Double = 6,
        exponentSigma: Double = 0.6,
        offsetSigmaDB: Double = 4
    ) -> PathLossCalibration {
        let usable = links.filter {
            $0.observer != $0.target && $0.distance >= PathLossModel.minDistance && $0.distance.isFinite
                && (-127.0...20.0).contains($0.rssi)
        }
        guard !usable.isEmpty else { return PathLossCalibration(model: prior, deviceOffsets: [:], linkCount: 0) }

        // Unknowns: referenceRSSI, exponent, then one offset per device. Ridge priors make the
        // normal equations well posed even when offsets and the reference level are confounded.
        let devices = Array(Set(usable.flatMap { [$0.observer, $0.target] })).sorted()
        let index = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1, $0 + 2) })
        let count = devices.count + 2
        var normal = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)
        let weight = 1 / (prior.sigmaDB * prior.sigmaDB)

        for link in usable {
            var row = [Double](repeating: 0, count: count)
            row[0] = 1
            row[1] = -10 * log10(link.distance)
            row[index[link.observer]!] += 0.5
            row[index[link.target]!] += 0.5
            for i in 0..<count where row[i] != 0 {
                for j in 0..<count where row[j] != 0 { normal[i][j] += weight * row[i] * row[j] }
                rhs[i] += weight * row[i] * link.rssi
            }
        }
        let priorWeights = [1 / (referenceSigmaDB * referenceSigmaDB), 1 / (exponentSigma * exponentSigma)]
            + [Double](repeating: 1 / (offsetSigmaDB * offsetSigmaDB), count: devices.count)
        let priorMeans = [prior.referenceRSSI, prior.exponent] + [Double](repeating: 0, count: devices.count)
        for i in 0..<count {
            normal[i][i] += priorWeights[i]
            rhs[i] += priorWeights[i] * priorMeans[i]
        }
        guard let solution = solveLinearSystem(normal, rhs) else {
            return PathLossCalibration(model: prior, deviceOffsets: [:], linkCount: 0)
        }

        var model = PathLossModel(
            referenceRSSI: min(-20, max(-100, solution[0])),
            exponent: min(5, max(1.5, solution[1])),
            sigmaDB: prior.sigmaDB
        )
        var offsets: [String: Double] = [:]
        for device in devices { offsets[device] = solution[index[device]!] }
        // With enough links the residual spread replaces the assumed one; never below 3 dB.
        if usable.count >= 6 {
            let squares = usable.map { link -> Double in
                let predicted = model.predictedRSSI(at: link.distance)
                    + (offsets[link.observer]! + offsets[link.target]!) / 2
                return (link.rssi - predicted) * (link.rssi - predicted)
            }
            let rms = (squares.reduce(0, +) / Double(usable.count)).squareRoot()
            model.sigmaDB = min(12, max(3, rms))
        }
        return PathLossCalibration(model: model, deviceOffsets: offsets, linkCount: usable.count)
    }
}

/// Per-anchor RSSI smoothing driven by the accelerometer, which bounds how much the range to an
/// anchor can really have changed:
/// - Standing still, every sample since the phone stopped is averaged, so fast fading averages
///   out (down to `staticFloorDB`, shadowing that does not change without movement).
/// - A sample that jumps further than the walked distance can explain is fading or a body in
///   the way, and is dropped, unless `maxConsecutiveOutliers` in a row agree (the room changed).
/// - Walking, a short window keeps the lag small and the remaining lag is reported as
///   extra uncertainty.
public struct MotionAwareRSSI {
    /// Smoothing time constant while walking, seconds.
    public static let walkingTimeConstant: TimeInterval = 1.5
    /// Shadowing that averaging cannot remove while standing still, dB.
    public static let staticFloorDB = 4.0
    /// Typical spread of single samples, dB.
    public static let sampleSigmaDB = 5.0
    /// Samples older than this are not a current measurement.
    public static let maxSampleAge: TimeInterval = 5
    public static let maxConsecutiveOutliers = 3

    public private(set) var value: Double?
    public private(set) var lastSampleTime: TimeInterval?
    public private(set) var droppedSamples = 0
    private var stillSum = 0.0
    private var stillCount = 0
    private var consecutiveOutliers = 0

    public init() {}

    /// Samples averaged since the phone stopped; 0 while walking.
    public var stillSampleCount: Int { stillCount }

    /// Largest RSSI change, dB, that `walked` meters of movement plus sample noise can explain
    /// at about `distance` meters from the anchor.
    public static func allowedChange(walked: Double, distance: Double, model: PathLossModel) -> Double {
        let near = max(distance - walked, PathLossModel.minDistance)
        let far = max(distance + walked, near)
        return 2.5 * sampleSigmaDB + model.dBPerLogDistance * log(far / near)
    }

    /// Records a sample taken at `time`; repeated calls with the same sample are ignored.
    /// `walked` is the distance stepped since the previous sample, `distance` the current range
    /// estimate. Returns false if the sample was dropped as an outlier.
    @discardableResult
    public mutating func record(_ rssi: Double, at time: TimeInterval, moving: Bool,
                                walked: Double = 0, distance: Double = 1, model: PathLossModel = .default) -> Bool {
        guard rssi.isFinite, time > (lastSampleTime ?? -.infinity) else { return false }
        if let value, abs(rssi - value) > Self.allowedChange(walked: walked, distance: distance, model: model) {
            consecutiveOutliers += 1
            guard consecutiveOutliers >= Self.maxConsecutiveOutliers else {
                droppedSamples += 1
                lastSampleTime = time
                return false
            }
            // The environment changed for good: start over from the new level.
            self.value = nil
            stillSum = 0
            stillCount = 0
        }
        consecutiveOutliers = 0
        if moving {
            stillSum = 0
            stillCount = 0
            if let value, let lastSampleTime {
                let alpha = 1 - exp(-(time - lastSampleTime) / Self.walkingTimeConstant)
                self.value = value + alpha * (rssi - value)
            } else {
                value = rssi
            }
        } else {
            stillSum += rssi
            stillCount += 1
            value = stillSum / Double(stillCount)
        }
        lastSampleTime = time
        return true
    }

    /// Smoothed RSSI and its spread, or nil when there is no recent sample.
    public func estimate(at time: TimeInterval, speed: Double, distance: Double, model: PathLossModel)
        -> (rssi: Double, sigmaDB: Double)? {
        guard let value, let lastSampleTime, time - lastSampleTime <= Self.maxSampleAge else { return nil }
        if stillCount > 0 {
            let averaged = Self.sampleSigmaDB / Double(stillCount).squareRoot()
            let floor = min(Self.staticFloorDB, model.sigmaDB)
            return (value, (averaged * averaged + floor * floor).squareRoot())
        }
        // The smoothed value trails a walking phone by about one time constant of travel.
        let lag = speed * Self.walkingTimeConstant + speed * (time - lastSampleTime)
        let lagDB = model.dBPerLogDistance * lag / max(distance, 1)
        return (value, (model.sigmaDB * model.sigmaDB + lagDB * lagDB).squareRoot())
    }
}
