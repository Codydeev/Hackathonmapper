import Foundation

/// The latest raw RSSI sample of an anchor this phone hears directly.
public struct AnchorSighting: Equatable {
    public let anchorId: String
    public let position: Position
    /// The anchor's own reported accuracy; nil means unknown.
    public let positionAccuracy: Double?
    public let rssi: Double
    /// When the sample was taken, on the same monotonic clock as the motion samples.
    public let sampleTime: TimeInterval

    public init(anchorId: String, position: Position, positionAccuracy: Double?, rssi: Double, sampleTime: TimeInterval) {
        self.anchorId = anchorId
        self.position = position
        self.positionAccuracy = positionAccuracy
        self.rssi = rssi
        self.sampleTime = sampleTime
    }
}

/// How one anchor's BLE range looks before and after motion filtering.
public struct AnchorRange: Equatable {
    public let anchorId: String
    /// Range read from the motion-filtered RSSI alone, meters.
    public let rssiDistance: Double
    /// Range from the fused position, meters; nil while not tracking.
    public let fusedDistance: Double?
    /// Remaining RSSI spread after motion filtering, dB.
    public let sigmaDB: Double
    /// Samples averaged since the phone stopped; 0 while walking.
    public let stillSamples: Int
    /// Samples dropped as jumps the walked distance cannot explain.
    public let droppedSamples: Int
    public let lastResult: PositionFilter.UpdateResult?
}

/// Fuses pedestrian dead reckoning (smooth, but drifts) with BLE RSSI to anchors (bounded, but
/// noisy). Motion data limits the BLE range errors in four ways: it averages RSSI while the phone
/// stands still, drops samples implying a range change the steps cannot explain, accounts for
/// smoothing lag while walking, and spaces filter updates so correlated shadowing isn't counted
/// twice. In turn the anchors bound the dead-reckoning drift, including slow gyro heading drift.
/// Each phone's radio offset is estimated, and anchors' offsets come from `calibration`.
public struct FusionEngine {
    /// Assumed accuracy of an anchor's position when it reports none, meters.
    public static let defaultAnchorSigma = 0.5
    /// Random heading error per step, radians.
    public static let headingSigmaPerStep = 0.08
    /// Gyro heading drift per step, radians.
    public static let headingDriftPerStep = 0.03
    /// Heading uncertainty right after the user aligned with the frame, radians.
    public static let alignedHeadingSigma = 0.2
    /// Shadowing decorrelates over roughly this much movement, meters.
    public static let decorrelationDistance = 2.0
    /// Least RSSI spread trusted in one update, dB: static shadowing and path-loss model error are
    /// biases that averaging does not remove. Lower values made simulated walks overconfident.
    public static let minUpdateSigmaDB = 8.0
    /// Seconds in a row in which every anchor disagrees before restarting at the RSSI fix.
    public static let recoveryEpochs = 5
    public static let walkingTimeout: TimeInterval = 2

    private struct AnchorTrack {
        var rssi = MotionAwareRSSI()
        var walkedAtSample: Double
        var walkedAtFeed: Double?
        var fedStillCount = 0
        var lastResult: PositionFilter.UpdateResult?
    }

    public private(set) var deadReckoning = PedestrianDeadReckoning()
    public private(set) var filter: PositionFilter?
    public private(set) var calibration = PathLossCalibration.uncalibrated
    /// RSSI-only fix; shown separately, never published as a measurement.
    public private(set) var lastFix: RangeFix?
    public private(set) var ranges: [AnchorRange] = []
    public private(set) var acceptedUpdates = 0
    public private(set) var rejectedUpdates = 0
    public private(set) var recoveries = 0
    public private(set) var walkedDistance = 0.0
    /// This phone's height in the frame, for the vertical part of anchor ranges.
    public var ownHeight = 0.0
    private var receiverOffsetDB = 0.0
    private var lastStep: Step?
    private var lastStepInterval: TimeInterval?
    private var tracks: [String: AnchorTrack] = [:]
    private var lastUpdateTime: TimeInterval?
    private var rejectedEpochs = 0

    public init() {}

    public var isTracking: Bool { filter != nil }

    /// Starts tracking at a known point, facing `heading` (0 faces +z).
    public mutating func start(x: Double, z: Double, heading: Double, positionSigma: Double = 0.5) {
        deadReckoning.alignHeading(heading)
        filter = PositionFilter(x: x, z: z, positionSigma: positionSigma, receiverOffsetDB: receiverOffsetDB,
                                headingSigma: Self.alignedHeadingSigma)
        rejectedEpochs = 0
    }

    /// Frame heading of the last step direction: dead reckoning plus the estimated offset.
    public var heading: Double {
        normalizedAngle(deadReckoning.heading + (filter?.headingOffset ?? 0))
    }

    /// Starts tracking at the RSSI-only fix; false if there is none.
    @discardableResult
    public mutating func startFromFix(heading: Double) -> Bool {
        guard let lastFix else { return false }
        start(x: lastFix.x, z: lastFix.z, heading: heading, positionSigma: max(lastFix.accuracy, 1.5))
        return true
    }

    public mutating func alignHeading(_ heading: Double) {
        deadReckoning.alignHeading(heading)
        filter?.resetHeading(sigma: Self.alignedHeadingSigma)
    }

    public mutating func stop() {
        if let filter { receiverOffsetDB = filter.receiverOffsetDB }
        filter = nil
    }

    /// Corrects with a known position, such as standing next to an anchor.
    public mutating func observePosition(x: Double, z: Double, sigma: Double) {
        filter?.observePosition(x: x, z: z, sigma: sigma)
        rejectedEpochs = 0
    }

    public mutating func setCalibration(_ calibration: PathLossCalibration) {
        self.calibration = calibration
    }

    public func isWalking(at time: TimeInterval) -> Bool {
        lastStep.map { time - $0.time <= Self.walkingTimeout } ?? false
    }

    public func speed(at time: TimeInterval) -> Double {
        guard isWalking(at: time), let lastStep, let lastStepInterval else { return 0 }
        return lastStep.length / max(lastStepInterval, 0.3)
    }

    /// Feeds a motion sample; returns the step it completed, if any.
    @discardableResult
    public mutating func process(_ sample: MotionSample) -> Step? {
        guard let step = deadReckoning.process(sample) else { return nil }
        apply(step)
        return step
    }

    /// Moves the estimate by a step.
    public mutating func apply(_ step: Step) {
        if let lastStep {
            let interval = step.time - lastStep.time
            lastStepInterval = interval <= Self.walkingTimeout ? interval : nil
        }
        lastStep = step
        walkedDistance += step.length
        filter?.predict(length: step.length, heading: step.heading, alongSigma: 0.05 + 0.1 * step.length,
                        crossSigma: step.length * Self.headingSigmaPerStep, headingDrift: Self.headingDriftPerStep)
    }

    /// Feeds the latest RSSI sample of every anchor heard directly; call about once per second.
    public mutating func update(with sightings: [AnchorSighting], at time: TimeInterval) {
        let elapsed = lastUpdateTime.map { max(0, time - $0) } ?? 0
        lastUpdateTime = time
        filter?.addProcessNoise(seconds: elapsed, positionVariancePerSecond: isWalking(at: time) ? 0.02 : 0.005,
                                offsetVariancePerSecond: 0.01)

        let model = calibration.model
        let currentSpeed = speed(at: time)
        let heard = Set(sightings.map(\.anchorId))
        tracks = tracks.filter { heard.contains($0.key) }
        var inputs: [RangeInput] = []
        var newRanges: [AnchorRange] = []
        var accepted = 0
        var rejected = 0

        // Strongest first: near anchors constrain the position best.
        for sighting in sightings.sorted(by: { $0.rssi > $1.rssi }) {
            let id = sighting.anchorId
            let anchorOffset = calibration.linkOffset(of: id)
            let receiverOffset = filter?.receiverOffsetDB ?? receiverOffsetDB
            let vertical = sighting.position.y - ownHeight
            let current = filter?.distance(toX: sighting.position.x, z: sighting.position.z, verticalOffset: vertical)
                ?? model.distance(for: sighting.rssi - anchorOffset - receiverOffset)

            var track = tracks[id] ?? AnchorTrack(walkedAtSample: walkedDistance)
            if sighting.sampleTime > (track.rssi.lastSampleTime ?? -.infinity) {
                track.rssi.record(sighting.rssi, at: sighting.sampleTime, moving: isWalking(at: sighting.sampleTime),
                                  walked: walkedDistance - track.walkedAtSample, distance: current, model: model)
                track.walkedAtSample = walkedDistance
            }
            guard let estimate = track.rssi.estimate(at: time, speed: currentSpeed, distance: current, model: model) else {
                tracks[id] = track
                continue
            }
            let corrected = estimate.rssi - anchorOffset
            let sigmaDB = max(estimate.sigmaDB, Self.minUpdateSigmaDB)
            let anchorSigma = sighting.positionAccuracy ?? Self.defaultAnchorSigma

            // Shadowing stays correlated until the phone moves a meter or two. Feeding the same
            // averaged value every second would count it as new evidence, so while still feed
            // again only each time the number of averaged samples doubles.
            let still = track.rssi.stillSampleCount
            let due: Bool
            if still > 0 {
                due = still >= max(1, track.fedStillCount * 2)
                if due { track.fedStillCount = still }
            } else {
                due = track.walkedAtFeed.map { walkedDistance - $0 >= Self.decorrelationDistance } ?? true
                track.fedStillCount = 0
            }
            if due, filter != nil {
                let result = filter!.update(rssi: corrected, sigmaDB: sigmaDB, anchorX: sighting.position.x,
                                            anchorZ: sighting.position.z, verticalOffset: vertical,
                                            anchorSigma: anchorSigma, model: model)
                track.lastResult = result
                track.walkedAtFeed = walkedDistance
                if result == .accepted { accepted += 1 }
                if result == .rejected { rejected += 1 }
            }
            tracks[id] = track

            let anchorDB = model.dBPerLogDistance * anchorSigma / max(current, PathLossModel.minDistance)
            inputs.append(RangeInput(anchorX: sighting.position.x, anchorZ: sighting.position.z, verticalOffset: vertical,
                                     rssi: corrected - receiverOffset,
                                     sigmaDB: (sigmaDB * sigmaDB + anchorDB * anchorDB).squareRoot()))
            newRanges.append(AnchorRange(
                anchorId: id,
                rssiDistance: model.distance(for: corrected - receiverOffset),
                fusedDistance: filter?.distance(toX: sighting.position.x, z: sighting.position.z, verticalOffset: vertical),
                sigmaDB: estimate.sigmaDB,
                stillSamples: still,
                droppedSamples: track.rssi.droppedSamples,
                lastResult: track.lastResult
            ))
        }

        ranges = newRanges
        acceptedUpdates += accepted
        rejectedUpdates += rejected
        lastFix = RangeSolver.solve(inputs, model: model)

        guard filter != nil else { return }
        if accepted > 0 {
            rejectedEpochs = 0
        } else if rejected >= 2 {
            rejectedEpochs += 1
        }
        // Every anchor has disagreed for several seconds: the estimate has drifted away
        // (for example a missed turn). Restart at the RSSI fix, keeping the radio offset.
        if rejectedEpochs >= Self.recoveryEpochs, let fix = lastFix {
            filter?.reset(x: fix.x, z: fix.z, positionSigma: max(fix.accuracy, 1.5))
            recoveries += 1
            rejectedEpochs = 0
        }
    }
}
