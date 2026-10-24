import Foundation

extension Positioning {
    /// A GNSS fix in the shared frame.
    public struct GNSSFix: Equatable, Codable {
        /// Local monotonic time of the fix (Core Location's timestamp converted on entry).
        public let t: TimeInterval
        public let position: Vec2
        /// Core Location `horizontalAccuracy`: radius of ~68 % confidence, m.
        public let horizontalAccuracy: Double
        /// Course over ground, radians clockwise from true north, and its 1-sigma.
        public let course: Double?
        public let courseSigma: Double?
        public let speed: Double?
        /// The integrity check accepted this fix as trusted. Untrusted fixes are recorded in the
        /// provenance and never used as a position constraint.
        public let trusted: Bool

        public init(t: TimeInterval, position: Vec2, horizontalAccuracy: Double, course: Double? = nil,
                    courseSigma: Double? = nil, speed: Double? = nil, trusted: Bool) {
            self.t = t
            self.position = position
            self.horizontalAccuracy = horizontalAccuracy
            self.course = course
            self.courseSigma = courseSigma
            self.speed = speed
            self.trusted = trusted
        }

        /// From latitude/longitude through the shared `GeoFrame`; nil outside the frame.
        public static func make(frameId: String, t: TimeInterval, latitude: Double, longitude: Double,
                                horizontalAccuracy: Double, courseDegrees: Double? = nil, courseAccuracyDegrees: Double? = nil,
                                speed: Double? = nil, trusted: Bool) -> GNSSFix? {
            guard horizontalAccuracy.isFinite, horizontalAccuracy > 0,
                  let p = GeoFrame.position(frameId: frameId, latitude: latitude, longitude: longitude) else { return nil }
            let course = courseDegrees.flatMap { $0 >= 0 ? Positioning.degrees($0) : nil }
            let sigma = courseAccuracyDegrees.flatMap { $0 > 0 ? Positioning.degrees($0) : nil }
            return GNSSFix(t: t, position: Vec2(x: p.x, z: p.z), horizontalAccuracy: horizontalAccuracy,
                           course: course, courseSigma: course == nil ? nil : sigma,
                           speed: speed.flatMap { $0 >= 0 ? $0 : nil }, trusted: trusted)
        }
    }

    /// One piece of evidence the engine considered, kept for provenance.
    public struct Contribution: Equatable, Codable {
        public enum Source: String, Codable {
            case gnss, gnssCourse, compass, steps, stationary
            case bleRange, bleProximity, bleMultilateration, bleAmbiguous
            case declared
        }

        public let source: Source
        public let peerId: String?
        /// Local monotonic time the evidence describes.
        public let t: TimeInterval
        public let used: Bool
        public let reason: String?
    }

    /// The engine's answer. `position` is set only for point estimates; proximity and ambiguous
    /// results give a region (`regionCenter`, `r95`, `candidates`) that must be drawn as a region.
    public struct Estimate: Equatable {
        public enum Method: String, Codable {
            /// Trusted GNSS fix within the last few seconds.
            case gnss
            /// Steps and heading from the last absolute constraint, nothing newer.
            case deadReckoning
            /// Dead reckoning corrected by Bluetooth ranges to known anchors.
            case fused
            /// Three or more anchors with good geometry, no history needed.
            case multilateration
            /// Only "within r95 of this anchor" is known.
            case proximity
            /// Two (or mirror) candidate spots; neither may be shown as the position.
            case ambiguous
            /// Hand-entered or surveyed spot.
            case declared
            case unavailable
        }

        public enum Flag: String, Codable {
            /// Walking direction is unknown or worse than 45°: steps only widen the circle.
            case headingUnreliable
            /// No motion data recently: uncertainty grows at walking pace in every direction.
            case motionUnavailable
            /// The compass is being rejected as disturbed or inconsistent.
            case compassRejected
            /// The latest trusted GNSS fix was rejected by the innovation gate.
            case gnssRejected
            /// Bluetooth evidence and dead reckoning disagreed and the engine restarted from Bluetooth.
            case restartedFromBluetooth
            /// Residuals ran larger than the model predicts, so the uncertainty was widened.
            case widenedByResiduals
        }

        public let method: Method
        public let frameId: String
        /// Local monotonic time the estimate describes.
        public let t: TimeInterval
        public let position: Vec2?
        public let regionCenter: Vec2?
        public let covariance: Covariance2?
        public let r95: Double?
        public let candidates: [Vec2]
        /// Walking direction, radians clockwise from north, and its 1-sigma.
        public let heading: Double?
        public let headingSigma: Double?
        /// Last time any absolute evidence (trusted GNSS, a Bluetooth range, a declared spot) was used.
        public let lastAbsoluteAt: TimeInterval?
        public let lastTrustedGNSS: GNSSFix?
        public let anchorIds: [String]
        /// The estimate rests on GNSS somewhere (own fix or a GNSS anchor).
        public let gnssDependent: Bool
        public let provenance: [Contribution]
        public let flags: [Flag]

        /// Seconds since the last absolute evidence.
        public var age: TimeInterval? { lastAbsoluteAt.map { max(0, t - $0) } }
    }

    /// The local motion summary the trust engine and predictor consume (contract `MotionObservation`).
    public struct MotionSummary: Equatable {
        public let t: TimeInterval
        public let stationary: Bool
        /// Steps in the last `window` seconds, their scaled length and the dead-reckoned
        /// displacement over the window (x east, z north) with its 95 % radius.
        public let steps: Int
        public let distance: Double
        public let displacement: Vec2
        public let displacementR95: Double
        public let window: TimeInterval
        public let heading: Double?
        public let headingSigma: Double?
        public let strideScale: Double
    }
}

extension Positioning {
    /// Self-positioning for one phone: an extended Kalman filter over [x, z, device heading, gyro
    /// bias, carry offset, stride scale, compass bias, GNSS error x/z, pace change, one shadowing bias
    /// per anchor].
    ///
    /// - Trusted GNSS fixes and course over ground anchor it; the last trusted fix stays the origin
    ///   of dead reckoning after GNSS is lost.
    /// - The gyro carries heading between compass readings; the compass and GNSS course correct it;
    ///   the bias is learned from them and whenever the phone is still. The carry offset (walking
    ///   direction minus device heading) is learned from GNSS course.
    /// - Local magnetic disturbance is a compass-bias state that decorrelates with distance walked, so
    ///   a steel railing bends the compass state, not the heading. The correlated part of GNSS error
    ///   (multipath) is a state too, so averaging many fixes cannot claim more than GNSS supports.
    /// - Steps move the position along the walking direction; the stride scale is learned from GNSS,
    ///   and a fast pace-change state covers speeding up and slowing down that the accelerometer
    ///   amplitude does not show.
    /// - Bluetooth: with a tight prior each median RSSI window against a known anchor is a range
    ///   update (iterated EKF) with that link's shadowing as a state, so a static link cannot shrink
    ///   the uncertainty forever. With a broad prior the windows go through `RangeGeometry`
    ///   (proximity disc / ambiguous / multilateration) and only tighten the estimate.
    /// - Unknown heading or missing motion data grow the circle at the distance that may have been
    ///   walked, not as a random walk, so a straight walk away stays covered.
    /// - Self-check: the normalized innovations of range updates and GNSS fixes are tracked; when the
    ///   residuals run larger than the filter predicted, its noise is widened (and flagged) instead of
    ///   keeping a confident r95 the evidence contradicts.
    public final class Engine {
        public struct Config {
            public var models: [RSSIChannel: PathLossModel] = [
                .advertisement: .defaultOutdoor,
                .connection: .defaultOutdoor,
                .reciprocal: .defaultOutdoor,
                .relayedSmoothed: PathLossModel(p0: -59, n: 2.5, sigmaFast: 3.5, sigmaShadow: 5, source: "default-outdoor-relayed"),
            ]
            public var useBluetooth = true
            public var useMotion = true
            public var useCompass = true
            public var medianWindow: TimeInterval = 4

            /// A trusted fix counts as "gnss" for this long.
            public var gnssFreshFor: TimeInterval = 3
            /// Measurements later than this behind the filter clock are dropped as stale.
            public var maxLag: TimeInterval = 2
            /// RSSI windows (median time) older than this are stale.
            public var maxWindowAge: TimeInterval = 8
            public var anchorMaxAge: TimeInterval = 30
            public var anchorMaxSigma = 50.0
            public var maxAnchorDepth = 3

            /// Gyro angle random walk, rad/√s, and bias random walk, rad/s/√s.
            public var gyroNoise = 0.004
            public var gyroBiasWalk = 0.0002
            public var initialBiasSigma = Positioning.degrees(0.5)
            /// Heading random walk when no gyro is available, rad/√s.
            public var headingWalkWithoutGyro = Positioning.degrees(15)
            public var carryOffsetSigma = Positioning.degrees(20)
            public var strideScaleSigma = 0.15
            public var strideScaleWalk = 0.001
            /// Pace changes the step model misses: relative 1-sigma and time constant.
            public var paceChangeSigma = 0.12
            public var paceChangeTime: TimeInterval = 30
            /// Local magnetic disturbance: 1-sigma, and the distance and time over which it changes.
            public var compassBiasSigma = Positioning.degrees(8)
            public var compassBiasDistance = 15.0
            public var compassBiasTime: TimeInterval = 300
            /// Share of a fix's sigma that varies slowly (multipath, atmosphere), and its time constant.
            public var gnssCorrelatedFraction = 0.7
            public var gnssCorrelationTime: TimeInterval = 30
            /// Per-step along/cross-track noise as a fraction of the step.
            public var stepAlongNoise = 0.10
            public var stepCrossNoise = 0.06
            /// Motion the steps do not explain (shuffling, swaying), m/s random walk.
            public var unexplainedSpeed = 0.12
            public var stationarySpeed = 0.01
            /// Assumed pace when motion data is missing, m/s.
            public var walkingSpeed = 1.4
            public var headingUnknownAbove = Positioning.degrees(45)

            /// Range updates need sigma below this fraction of the anchor distance, and below `tightPriorMax`.
            public var tightPriorRatio = 0.6
            public var tightPriorMax = 15.0
            public var forgetAnchorBiasAfter: TimeInterval = 60
            /// Shadowing also decorrelates slowly with time (people, doors), s.
            public var shadowTimeConstant: TimeInterval = 300
            /// Consecutive mutually consistent trusted fixes rejected before the filter is reset to GNSS.
            public var gnssResetAfter = 10
            /// Consecutive disagreements before dead reckoning is abandoned for the Bluetooth solution.
            public var bluetoothResetAfter = 3
            /// Self-check: ceiling of the noise widening, and the averaging weight per update.
            public var maxWidening = 6.0
            public var residualAveraging = 0.1
            /// Above this the estimate is reported unavailable rather than as a giant circle.
            public var maxUsefulR95 = 500.0

            public init() {}
        }

        static let X = 0, Z = 1, PSI = 2, BIAS = 3, CARRY = 4, SCALE = 5, MAG = 6, GX = 7, GZ = 8, PACE = 9, BASE = 10
        static let version = "ghostcore-positioning@0.1"

        public let selfId: String
        public let frameId: String
        public private(set) var config: Config

        private var x: [Double] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        private var P = Matrix(rows: 10, cols: 10)
        /// Sigma of the latest trusted fix, which sets the level of the GNSS error states.
        private var gnssSigma = 3.0
        private var biasIndex: [String: Int] = [:]
        private var biasLink: [String: (walked: Double, anchor: Vec2, t: TimeInterval)] = [:]

        private var positionReady = false
        private var headingReady = false
        private var filterTime: TimeInterval?
        private var headingTime: TimeInterval?
        private var lastMotionT: TimeInterval?
        private var stationary = false
        private var lastZeroRateUpdate: TimeInterval = -Double.infinity
        /// Distance that may have been walked in an unknown direction since the heading was lost.
        private var unknownHeadingDistance = 0.0
        private var noMotionDistance = 0.0

        private var stepDetector = StepDetector()
        private var stillness = StationarityDetector()
        private var rssi: RSSIMedianFilter
        private var anchors: [String: Anchor] = [:]
        private var latestWindows: [String: RSSIWindow] = [:]
        private var geometry: GeometrySolution?

        /// Cumulative dead-reckoned displacement, to move late measurements to their own time.
        private var displacement = Vec2.zero
        private var trail: [(t: TimeInterval, d: Vec2)] = []
        private var walked = 0.0
        private var recentSteps: [(t: TimeInterval, length: Double)] = []

        private var initSource: Estimate.Method?
        /// False while the point only rests on a disc it started from (shown as that region).
        private var pointConfirmed = true
        private var lastAbsoluteAt: TimeInterval?
        private var lastGNSSUpdate: TimeInterval?
        private var lastBluetoothUpdate: TimeInterval?
        private var lastTrustedFix: GNSSFix?
        private var gnssDependent = false
        private var usedAnchors: [String: TimeInterval] = [:]
        private var gnssRejections: [GNSSFix] = []
        private var bluetoothConflicts = 0
        private var compassRejectedSince: TimeInterval?
        private var restartedFromBluetoothAt: TimeInterval?
        private var contributions: [Contribution] = []
        /// Moving averages of normalized innovation squared per dimension (1 when consistent).
        private var rangeNIS = 1.0
        private var gnssNIS = 1.0
        private var lastNIS = 0.0

        public private(set) var diagnostics = Diagnostics()

        /// Current gyro heading-rate bias estimate, rad/s.
        public var gyroBiasEstimate: Double { x[Self.BIAS] }

        public struct Diagnostics: Equatable {
            public var staleDropped = 0
            public var outOfOrderDropped = 0
            public var gnssUntrusted = 0
            public var gnssRejected = 0
            public var compassRejected = 0
            public var rangeUpdates = 0
            public var rangeRejected = 0
            public var geometryUpdates = 0
            public var anchorsRefused = 0
            public var steps = 0
        }

        public init(selfId: String, frameId: String, config: Config = Config()) {
            self.selfId = selfId
            self.frameId = frameId
            self.config = config
            rssi = RSSIMedianFilter(window: config.medianWindow)
            P[Self.PSI, Self.PSI] = Double.pi * Double.pi
            P[Self.BIAS, Self.BIAS] = config.initialBiasSigma * config.initialBiasSigma
            P[Self.CARRY, Self.CARRY] = config.carryOffsetSigma * config.carryOffsetSigma
            P[Self.SCALE, Self.SCALE] = config.strideScaleSigma * config.strideScaleSigma
            P[Self.MAG, Self.MAG] = config.compassBiasSigma * config.compassBiasSigma
            P[Self.PACE, Self.PACE] = config.paceChangeSigma * config.paceChangeSigma
            P[Self.GX, Self.GX] = pow(config.gnssCorrelatedFraction * gnssSigma, 2)
            P[Self.GZ, Self.GZ] = pow(config.gnssCorrelatedFraction * gnssSigma, 2)
            P[Self.X, Self.X] = 1e6
            P[Self.Z, Self.Z] = 1e6
        }

        // MARK: - Inputs

        /// A surveyed or hand-entered position (e.g. "I am at the marked start point").
        public func declare(position: Vec2, sigma: Double, at t: TimeInterval) {
            advance(to: max(filterTime ?? t, t))
            pointConfirmed = true
            if positionReady {
                _ = positionUpdate(position, Covariance2.isotropic(sigma: sigma))
            } else {
                initializePosition(position, Covariance2.isotropic(sigma: sigma), source: .declared)
            }
            lastAbsoluteAt = t
            record(.declared, nil, t, used: true, nil)
        }

        public func ingest(gnss fix: GNSSFix) {
            guard fix.trusted else {
                diagnostics.gnssUntrusted += 1
                record(.gnss, nil, fix.t, used: false, "integrity check did not trust the fix")
                return
            }
            let now = filterTime ?? fix.t
            let late = max(0, now - fix.t)
            let sigma = fix.horizontalAccuracy * Stats.radius68ToSigma
            if !positionReady {
                // Also how a remembered last fix seeds the filter after a restart: it widens at
                // walking pace for its age, since nobody counted the steps in between.
                let grown = (sigma * sigma + pow(config.walkingSpeed * late, 2)).squareRoot()
                advance(to: max(now, fix.t))
                initializePosition(fix.position, .isotropic(sigma: grown), source: .gnss)
                seedGNSSError(sigma: sigma, fresh: late < 1)
                acceptFix(fix)
                courseUpdate(fix)
                return
            }
            guard late <= config.maxLag else {
                diagnostics.staleDropped += 1
                record(.gnss, nil, fix.t, used: false, String(format: "stale by %.1f s", late))
                return
            }
            advance(to: max(now, fix.t))
            // Where the fix would put us now: add the steps walked since its timestamp.
            let shifted = fix.position + displacementSince(fix.t)
            gnssSigma = sigma * gnssWidening.squareRoot()
            // The fix = position + slowly varying GNSS error + white noise.
            let white = (1 - pow(config.gnssCorrelatedFraction, 2)) * sigma * sigma * gnssWidening
                + pow(0.1 * displacementSince(fix.t).length, 2)
            let applied = update2([(Self.X, 1), (Self.GX, 1)], [(Self.Z, 1), (Self.GZ, 1)],
                                  shifted.x - x[Self.X] - x[Self.GX], shifted.z - x[Self.Z] - x[Self.GZ],
                                  Covariance2(xx: white, xz: 0, zz: white), gate: Stats.chi2_2dof_999)
            noteResidual(lastNIS, dimensions: 2, into: &gnssNIS)
            if applied {
                gnssRejections = []
                acceptFix(fix)
                courseUpdate(fix)
            } else {
                diagnostics.gnssRejected += 1
                gnssRejections.append(fix)
                // A run of trusted fixes that agree with each other but not with us means we are wrong.
                let recent = gnssRejections.suffix(config.gnssResetAfter)
                if recent.count >= config.gnssResetAfter,
                   let first = recent.first, recent.allSatisfy({ $0.position.distance(to: first.position) < 3 * first.horizontalAccuracy + config.walkingSpeed * ($0.t - first.t) }) {
                    initializePosition(fix.position, .isotropic(sigma: sigma), source: .gnss)
                    seedGNSSError(sigma: sigma, fresh: true)
                    acceptFix(fix)
                    gnssRejections = []
                    record(.gnss, nil, fix.t, used: true, "filter reset: \(config.gnssResetAfter) consistent trusted fixes disagreed with it")
                } else {
                    record(.gnss, nil, fix.t, used: false, "innovation gate: fix inconsistent with the filter")
                }
            }
        }

        public func ingest(motion s: MotionSample) {
            guard config.useMotion else { return }
            if let ht = headingTime, s.t <= ht {
                diagnostics.outOfOrderDropped += 1
                return
            }
            if let rate = DeviceAxes.headingRate(s) {
                let dt = headingTime.map { s.t - $0 } ?? 0
                if dt > 0 {
                    if dt <= 0.25 {
                        predictHeading(rate: rate, dt: dt)
                    } else {
                        // A gap in the gyro stream: heading may have changed by anything a person does.
                        headingWalk(dt: dt, sigma: config.headingWalkWithoutGyro)
                    }
                }
            }
            headingTime = s.t
            lastMotionT = s.t
            noMotionDistance = 0

            if let meanRate = stillness.add(s) {
                stationary = true
                if s.t - lastZeroRateUpdate >= 1 {
                    // Still phone: the true heading rate is zero, so the measured mean is the bias.
                    let h = row([Self.BIAS: 1])
                    let innovation = meanRate - x[Self.BIAS]
                    if !scalarUpdate(h, innovation: innovation, r: 0.002 * 0.002, gate: Stats.chi2_1dof_997) {
                        // The bias estimate went wrong (e.g. a disturbed compass leaked into it):
                        // admit it and take the still phone's word.
                        P[Self.BIAS, Self.BIAS] += innovation * innovation
                        scalarUpdate(h, innovation: innovation, r: 0.002 * 0.002, gate: .infinity)
                    }
                    lastZeroRateUpdate = s.t
                }
            } else {
                stationary = false
            }
            if let step = stepDetector.add(s) { applyStep(step) }
        }

        /// Steps from another source (e.g. `CMPedometer`); don't also let the built-in detector run.
        public func ingest(step: StepEvent) { applyStep(step) }

        public func ingest(compass c: CompassSample) {
            guard config.useCompass else { return }
            guard !c.disturbed, c.sigma.isFinite, c.sigma > 0 else {
                compassRejected(c.t, "magnetic disturbance")
                return
            }
            if let ht = headingTime, c.t < ht - 0.5 {
                diagnostics.staleDropped += 1
                return
            }
            guard headingReady else {
                setHeading(c.heading - x[Self.MAG], sigma: (c.sigma * c.sigma + P[Self.MAG, Self.MAG]).squareRoot())
                record(.compass, nil, c.t, used: true, "initial heading")
                return
            }
            let h = row([Self.PSI: 1, Self.MAG: 1])
            if scalarUpdate(h, innovation: Positioning.wrap(c.heading - x[Self.PSI] - x[Self.MAG]), r: c.sigma * c.sigma,
                            gate: Stats.chi2_1dof_997) {
                compassRejectedSince = nil
            } else {
                compassRejected(c.t, "inconsistent with gyro heading")
            }
        }

        /// A neighbour whose position is known (its trusted GNSS fix, a surveyed spot, or its own
        /// estimate). Estimated anchors that depend on this phone are refused, which breaks cycles.
        public func ingest(anchor a: Anchor) {
            guard a.id != selfId, a.position.x.isFinite, a.position.z.isFinite, a.sigma.isFinite, a.sigma >= 0,
                  a.sigma <= config.anchorMaxSigma else {
                diagnostics.anchorsRefused += 1
                return
            }
            if a.kind == .estimated && (a.dependsOn.contains(selfId) || a.dependsOn.count > config.maxAnchorDepth) {
                diagnostics.anchorsRefused += 1
                record(.bleRange, a.id, a.measuredAt, used: false, "anchor estimate depends on this phone or is too many hops deep")
                return
            }
            if let old = anchors[a.id], old.measuredAt > a.measuredAt { return }
            anchors[a.id] = a
        }

        /// Withdraws an anchor at once, e.g. when the integrity check stops trusting its GNSS. Its
        /// earlier contributions leave the provenance, replaced by the withdrawal and its reason.
        public func removeAnchor(_ id: String, at t: TimeInterval? = nil, reason: String = "anchor withdrawn") {
            let known = anchors[id] != nil || usedAnchors[id] != nil
            anchors[id] = nil
            latestWindows[id] = nil
            usedAnchors[id] = nil
            removeBias(id)
            if let g = geometry, g.anchorIds.contains(id) { geometry = nil }
            guard known else { return }
            contributions.removeAll { $0.peerId == id }
            record(.bleRange, id, t ?? filterTime ?? 0, used: false, reason)
        }

        public func ingest(rssi sample: RSSISample) {
            guard config.useBluetooth, sample.peerId != selfId else { return }
            rssi.add(sample)
        }

        public func setModel(_ model: PathLossModel, for channel: RSSIChannel) { config.models[channel] = model }

        // MARK: - Output

        public func estimate(at t: TimeInterval) -> Estimate {
            processBluetooth(now: t)
            advance(to: max(filterTime ?? t, t))
            pruneAnchors(now: t)

            var flags: [Estimate.Flag] = []
            let headingSigma = walkingHeadingSigma
            if !headingReady || headingSigma > config.headingUnknownAbove { flags.append(.headingUnreliable) }
            if config.useMotion && (lastMotionT.map { t - $0 > 1.5 } ?? true) { flags.append(.motionUnavailable) }
            if compassRejectedSince.map({ t - $0 > 5 }) ?? false { flags.append(.compassRejected) }
            if !gnssRejections.isEmpty { flags.append(.gnssRejected) }
            if restartedFromBluetoothAt.map({ t - $0 < 30 }) ?? false { flags.append(.restartedFromBluetooth) }
            if widening > 1.5 || gnssWidening > 1.5 { flags.append(.widenedByResiduals) }

            let heading = headingReady ? Positioning.wrap(x[Self.PSI] + x[Self.CARRY]) : nil
            let anchorIds = usedAnchors.filter { t - $0.value <= 30 }.keys.sorted()
            let provenance = summarizedProvenance(now: t)

            func make(_ method: Estimate.Method, position: Vec2?, center: Vec2?, cov: Covariance2?, r95: Double?,
                      candidates: [Vec2] = [], anchorIds: [String], gnssDependent: Bool) -> Estimate {
                Estimate(method: method, frameId: frameId, t: t, position: position, regionCenter: center, covariance: cov,
                         r95: r95, candidates: candidates, heading: heading, headingSigma: headingReady ? headingSigma : nil,
                         lastAbsoluteAt: lastAbsoluteAt, lastTrustedGNSS: lastTrustedFix, anchorIds: anchorIds,
                         gnssDependent: gnssDependent, provenance: provenance, flags: flags)
            }

            func region(_ g: GeometrySolution) -> Estimate {
                let method: Estimate.Method = g.kind == .ambiguous ? .ambiguous : .proximity
                let dependent = g.anchorIds.contains { anchors[$0]?.gnssDependent ?? false }
                return make(method, position: nil, center: g.center, cov: g.covariance, r95: g.r95, candidates: g.candidates,
                            anchorIds: g.anchorIds, gnssDependent: dependent)
            }
            let freshRegion = geometry.flatMap { g in t - g.t <= 10 && g.kind != .multilateration ? g : nil }

            if positionReady {
                let cov = Covariance2(xx: P[Self.X, Self.X], xz: P[Self.X, Self.Z], zz: P[Self.Z, Self.Z])
                let p = Vec2(x: x[Self.X], z: x[Self.Z])
                let r95 = cov.r95
                let gnssFresh = lastGNSSUpdate.map { t - $0 <= config.gnssFreshFor } ?? false
                // A disc or an unresolved pair is never fused into the point (its centre is not a
                // place the phone is likely to be); when it says more than the point, show it instead.
                if !gnssFresh, let g = freshRegion, g.r95 < r95 {
                    // A point that says less than half of what Bluetooth says is obsolete: let it go
                    // rather than flick between it and the region.
                    if g.r95 < 0.5 * r95 { positionReady = false }
                    return region(g)
                }
                if r95 > config.maxUsefulR95 {
                    return make(.unavailable, position: nil, center: nil, cov: nil, r95: nil, anchorIds: [], gnssDependent: gnssDependent)
                }
                if !pointConfirmed {
                    return make(.proximity, position: nil, center: p, cov: cov, r95: r95, anchorIds: anchorIds, gnssDependent: gnssDependent)
                }
                let method: Estimate.Method
                if gnssFresh {
                    method = .gnss
                } else if let b = lastBluetoothUpdate, t - b <= 10 {
                    method = initSource == .multilateration && diagnostics.steps == 0 ? .multilateration : .fused
                } else if initSource == .declared && diagnostics.steps == 0 {
                    method = .declared
                } else {
                    method = .deadReckoning
                }
                return make(method, position: p, center: p, cov: cov, r95: r95, anchorIds: anchorIds, gnssDependent: gnssDependent)
            }
            if let g = freshRegion { return region(g) }
            return make(.unavailable, position: nil, center: nil, cov: nil, r95: nil, anchorIds: [], gnssDependent: false)
        }

        public func motionSummary(at t: TimeInterval, window: TimeInterval = 5) -> MotionSummary {
            let steps = recentSteps.filter { $0.t > t - window }
            let distance = steps.reduce(0) { $0 + $1.length }
            let moved = displacementSince(t - window)
            // Step noise, heading and stride-scale uncertainty over this short interval.
            let sigma = (steps.map { pow(config.stepAlongNoise * $0.length, 2) }.reduce(0, +)
                         + pow(distance * walkingHeadingSigma, 2) + pow(distance * strideSigma, 2))
                .squareRoot()
            return MotionSummary(t: t, stationary: stationary && steps.isEmpty, steps: steps.count, distance: distance,
                                 displacement: moved, displacementR95: Stats.r95PerSigma * sigma, window: window,
                                 heading: headingReady ? Positioning.wrap(x[Self.PSI] + x[Self.CARRY]) : nil,
                                 headingSigma: headingReady ? walkingHeadingSigma : nil, strideScale: x[Self.SCALE] + x[Self.PACE])
        }

        /// Raw sliding-window RSSI summary for one peer, for display and calibration screens.
        public func rssiWindow(peerId: String, channel: RSSIChannel, now: TimeInterval) -> RSSIWindow? {
            rssi.current(peerId: peerId, channel: channel, now: now)
        }

        // MARK: - Filter mechanics

        private var dim: Int { x.count }

        /// Process-noise multiplier from the range residuals, and fix-noise multiplier from GNSS's.
        private var widening: Double { min(config.maxWidening, max(1, rangeNIS)) }
        private var gnssWidening: Double { min(config.maxWidening, max(1, gnssNIS)) }

        private func noteResidual(_ nis: Double, dimensions: Double, into average: inout Double) {
            let a = config.residualAveraging
            average = (1 - a) * average + a * min(25, nis / dimensions)
        }

        private var strideSigma: Double {
            max(0, P[Self.SCALE, Self.SCALE] + P[Self.PACE, Self.PACE] + 2 * P[Self.SCALE, Self.PACE]).squareRoot()
        }

        private var walkingHeadingSigma: Double {
            max(0, P[Self.PSI, Self.PSI] + P[Self.CARRY, Self.CARRY] + 2 * P[Self.PSI, Self.CARRY]).squareRoot()
        }

        private func row(_ entries: [Int: Double]) -> [Double] {
            var h = Array(repeating: 0.0, count: dim)
            for (i, v) in entries { h[i] = v }
            return h
        }

        private func advance(to t: TimeInterval) {
            guard let ft = filterTime else {
                filterTime = t
                return
            }
            let dt = t - ft
            guard dt > 0 else { return }
            filterTime = t
            if !config.useMotion || lastMotionT.map({ t - $0 > 1.5 }) ?? true {
                // No motion data: anyone may have walked off in any direction at walking pace.
                let before = noMotionDistance
                noMotionDistance += config.walkingSpeed * dt
                let q = (noMotionDistance * noMotionDistance - before * before) / 2
                P[Self.X, Self.X] += q
                P[Self.Z, Self.Z] += q
                if headingTime.map({ t - $0 > 0.25 }) ?? true {
                    headingWalk(dt: dt, sigma: config.headingWalkWithoutGyro)
                    headingTime = max(headingTime ?? t, t)
                }
            } else {
                let v = stationary ? config.stationarySpeed : config.unexplainedSpeed
                P[Self.X, Self.X] += v * v * dt * widening
                P[Self.Z, Self.Z] += v * v * dt * widening
            }
            P[Self.BIAS, Self.BIAS] += config.gyroBiasWalk * config.gyroBiasWalk * dt
            P[Self.SCALE, Self.SCALE] += config.strideScaleWalk * config.strideScaleWalk * dt
            decorrelate(Self.MAG, rho: exp(-dt / config.compassBiasTime), sigma: config.compassBiasSigma)
            decorrelate(Self.PACE, rho: exp(-dt / config.paceChangeTime), sigma: config.paceChangeSigma)
            let g = exp(-dt / config.gnssCorrelationTime)
            decorrelate(Self.GX, rho: g, sigma: config.gnssCorrelatedFraction * gnssSigma)
            decorrelate(Self.GZ, rho: g, sigma: config.gnssCorrelatedFraction * gnssSigma)
        }

        /// First-order Gauss-Markov step for one state: shrink towards zero, refill to `sigma`.
        private func decorrelate(_ i: Int, rho: Double, sigma: Double) {
            x[i] *= rho
            for j in 0..<dim where j != i {
                P[i, j] *= rho
                P[j, i] *= rho
            }
            P[i, i] = rho * rho * P[i, i] + (1 - rho * rho) * sigma * sigma
        }

        /// After initializing from a fix: part of its error is the slowly varying GNSS error.
        private func seedGNSSError(sigma: Double, fresh: Bool) {
            gnssSigma = sigma
            let v = pow(config.gnssCorrelatedFraction * sigma, 2)
            for i in [Self.GX, Self.GZ] {
                x[i] = 0
                for j in 0..<dim where j != i {
                    P[i, j] = 0
                    P[j, i] = 0
                }
                P[i, i] = v
            }
            if fresh {
                P[Self.X, Self.GX] = -v; P[Self.GX, Self.X] = -v
                P[Self.Z, Self.GZ] = -v; P[Self.GZ, Self.Z] = -v
            }
        }

        private func predictHeading(rate: Double, dt: Double) {
            x[Self.PSI] = Positioning.wrap(x[Self.PSI] + (rate - x[Self.BIAS]) * dt)
            // F = I with F[psi, bias] = -dt: rows, then columns, gives F P Fᵀ.
            for j in 0..<dim { P[Self.PSI, j] -= dt * P[Self.BIAS, j] }
            for i in 0..<dim { P[i, Self.PSI] -= dt * P[i, Self.BIAS] }
            P[Self.PSI, Self.PSI] += config.gyroNoise * config.gyroNoise * dt
        }

        private func headingWalk(dt: Double, sigma: Double) {
            P[Self.PSI, Self.PSI] += sigma * sigma * dt
        }

        private func setHeading(_ h: Double, sigma: Double) {
            x[Self.PSI] = Positioning.wrap(h)
            for i in 0..<dim where i != Self.PSI {
                P[i, Self.PSI] = 0
                P[Self.PSI, i] = 0
            }
            P[Self.PSI, Self.PSI] = sigma * sigma
            headingReady = true
        }

        private func initializePosition(_ p: Vec2, _ cov: Covariance2, source: Estimate.Method) {
            x[Self.X] = p.x
            x[Self.Z] = p.z
            for i in 0..<dim where i > Self.Z {
                P[Self.X, i] = 0; P[i, Self.X] = 0
                P[Self.Z, i] = 0; P[i, Self.Z] = 0
            }
            P[Self.X, Self.X] = cov.xx
            P[Self.Z, Self.Z] = cov.zz
            P[Self.X, Self.Z] = cov.xz
            P[Self.Z, Self.X] = cov.xz
            positionReady = true
            initSource = source
            pointConfirmed = source != .proximity
            unknownHeadingDistance = 0
            noMotionDistance = 0
            for id in biasIndex.keys.sorted() { removeBias(id) }
        }

        /// Kalman update for one scalar measurement, O(n²). False if gated out.
        @discardableResult
        private func scalarUpdate(_ h: [Double], innovation: Double, r: Double, gate: Double) -> Bool {
            var ph = Array(repeating: 0.0, count: dim)
            for i in 0..<dim {
                var s = 0.0
                for j in 0..<dim where h[j] != 0 { s += P[i, j] * h[j] }
                ph[i] = s
            }
            var s = r
            for j in 0..<dim where h[j] != 0 { s += h[j] * ph[j] }
            lastNIS = s > 0 ? innovation * innovation / s : .infinity
            guard s > 0, innovation * innovation / s <= gate else { return false }
            for i in 0..<dim { x[i] += ph[i] / s * innovation }
            for i in 0..<dim {
                for j in 0..<dim { P[i, j] -= ph[i] * ph[j] / s }
            }
            normalize()
            return true
        }

        /// Kalman update with a direct position measurement. False if gated out.
        @discardableResult
        private func positionUpdate(_ z: Vec2, _ r: Covariance2, gate: Double = .infinity) -> Bool {
            update2([(Self.X, 1)], [(Self.Z, 1)], z.x - x[Self.X], z.z - x[Self.Z], r, gate: gate)
        }

        /// Kalman update for a two-component measurement with sparse rows h1, h2, O(n²). Rows are
        /// ordered pairs, not dictionaries, so the sums run in a fixed order and replays repeat exactly.
        @discardableResult
        private func update2(_ h1: [(Int, Double)], _ h2: [(Int, Double)], _ v1: Double, _ v2: Double, _ r: Covariance2,
                             gate: Double = .infinity) -> Bool {
            let n = dim
            var a = Array(repeating: 0.0, count: n)
            var b = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                for (j, v) in h1 { a[i] += P[i, j] * v }
                for (j, v) in h2 { b[i] += P[i, j] * v }
            }
            var s11 = r.xx, s12 = r.xz, s22 = r.zz
            for (j, v) in h1 {
                s11 += v * a[j]
                s12 += v * b[j]
            }
            for (j, v) in h2 { s22 += v * b[j] }
            let det = s11 * s22 - s12 * s12
            guard det > 1e-12 else { return false }
            let i11 = s22 / det, i12 = -s12 / det, i22 = s11 / det
            let m2 = v1 * (i11 * v1 + i12 * v2) + v2 * (i12 * v1 + i22 * v2)
            lastNIS = m2
            guard m2 <= gate else { return false }
            var k1 = Array(repeating: 0.0, count: n)
            var k2 = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                k1[i] = a[i] * i11 + b[i] * i12
                k2[i] = a[i] * i12 + b[i] * i22
            }
            for i in 0..<n {
                x[i] += k1[i] * v1 + k2[i] * v2
                for j in 0..<n { P[i, j] -= k1[i] * a[j] + k2[i] * b[j] }
            }
            normalize()
            return true
        }

        private func normalize() {
            x[Self.PSI] = Positioning.wrap(x[Self.PSI])
            x[Self.CARRY] = Positioning.wrap(x[Self.CARRY])
            x[Self.MAG] = Positioning.wrap(x[Self.MAG])
            P.symmetrize()
            for i in 0..<dim where P[i, i] < 1e-12 { P[i, i] = 1e-12 }
        }

        private func applyStep(_ step: StepEvent) {
            guard step.length.isFinite, step.length > 0, step.length < 2.5 else { return }
            diagnostics.steps += 1
            advance(to: max(filterTime ?? step.t, step.t))
            let scale = x[Self.SCALE] + x[Self.PACE]
            let length = max(0.2, scale) * step.length
            walked += length
            decorrelate(Self.MAG, rho: exp(-length / config.compassBiasDistance), sigma: config.compassBiasSigma)
            recentSteps.append((step.t, length))
            recentSteps.removeAll { $0.t < step.t - 30 }
            if !headingReady || walkingHeadingSigma > config.headingUnknownAbove {
                // Direction unknown: the step could have gone anywhere, and steps add up in a line
                // as easily as they cancel. Grow the circle by the distance, not a random walk.
                let before = unknownHeadingDistance
                unknownHeadingDistance += length
                let q = (unknownHeadingDistance * unknownHeadingDistance - before * before) / 2
                P[Self.X, Self.X] += q
                P[Self.Z, Self.Z] += q
                recordTrail(step.t)
                return
            }
            unknownHeadingDistance = 0
            let theta = x[Self.PSI] + x[Self.CARRY]
            let sn = sin(theta), cs = cos(theta)
            x[Self.X] += length * sn
            x[Self.Z] += length * cs
            displacement = displacement + Vec2(x: length * sn, z: length * cs)
            recordTrail(step.t)

            var f = Matrix.identity(dim)
            f[Self.X, Self.PSI] = length * cs
            f[Self.X, Self.CARRY] = length * cs
            f[Self.X, Self.SCALE] = step.length * sn
            f[Self.X, Self.PACE] = step.length * sn
            f[Self.Z, Self.PSI] = -length * sn
            f[Self.Z, Self.CARRY] = -length * sn
            f[Self.Z, Self.SCALE] = step.length * cs
            f[Self.Z, Self.PACE] = step.length * cs
            P = f * P * f.transposed
            let along = pow(config.stepAlongNoise * length, 2) * widening
            let cross = pow(config.stepCrossNoise * length, 2) * widening
            P[Self.X, Self.X] += along * sn * sn + cross * cs * cs
            P[Self.Z, Self.Z] += along * cs * cs + cross * sn * sn
            P[Self.X, Self.Z] += (along - cross) * sn * cs
            P[Self.Z, Self.X] += (along - cross) * sn * cs
            P.symmetrize()
        }

        private func recordTrail(_ t: TimeInterval) {
            trail.append((t, displacement))
            trail.removeAll { $0.t < t - 20 }
        }

        /// Dead-reckoned displacement since `t` (zero if older than the trail or no steps since).
        private func displacementSince(_ t: TimeInterval) -> Vec2 {
            guard let before = trail.last(where: { $0.t <= t }) else { return trail.isEmpty ? .zero : displacement - (trail.first?.d ?? displacement) }
            return displacement - before.d
        }

        private func acceptFix(_ fix: GNSSFix) {
            pointConfirmed = true
            lastTrustedFix = fix
            lastGNSSUpdate = fix.t
            lastAbsoluteAt = max(lastAbsoluteAt ?? fix.t, fix.t)
            gnssDependent = true
            record(.gnss, nil, fix.t, used: true, nil)
        }

        private func courseUpdate(_ fix: GNSSFix) {
            guard let course = fix.course, let sigma = fix.courseSigma, let speed = fix.speed,
                  speed >= 1.0, sigma < Positioning.degrees(30) else { return }
            if !headingReady {
                setHeading(course - x[Self.CARRY], sigma: (sigma * sigma + P[Self.CARRY, Self.CARRY]).squareRoot())
                record(.gnssCourse, nil, fix.t, used: true, "initial heading")
                return
            }
            let h = row([Self.PSI: 1, Self.CARRY: 1])
            let used = scalarUpdate(h, innovation: Positioning.wrap(course - x[Self.PSI] - x[Self.CARRY]), r: sigma * sigma,
                                    gate: Stats.chi2_1dof_997)
            record(.gnssCourse, nil, fix.t, used: used, used ? nil : "course inconsistent with heading")
        }

        private func compassRejected(_ t: TimeInterval, _ reason: String) {
            diagnostics.compassRejected += 1
            if compassRejectedSince == nil {
                compassRejectedSince = t
                record(.compass, nil, t, used: false, reason)
            }
        }

        // MARK: - Bluetooth

        private func model(_ channel: RSSIChannel) -> PathLossModel {
            config.models[channel] ?? .defaultOutdoor
        }

        private func processBluetooth(now: TimeInterval) {
            guard config.useBluetooth else { return }
            let windows = rssi.takeWindows(now: now)
            rssi.prune(now: now)
            var broad: [RSSIWindow] = []
            for w in windows {
                guard let anchor = anchors[w.peerId], now - anchor.measuredAt <= config.anchorMaxAge else { continue }
                guard now - w.t <= config.maxWindowAge else {
                    diagnostics.staleDropped += 1
                    record(.bleRange, w.peerId, w.t, used: false, "stale RSSI window")
                    continue
                }
                latestWindows[w.peerId] = w
                // A reading near the receiver's floor only says "far": never a tight range update.
                if positionReady && isTight(for: anchor) && !model(w.channel).isCensored(rssi: w.median) {
                    rangeUpdate(w, anchor, now: now)
                } else {
                    broad.append(w)
                }
            }
            guard !broad.isEmpty else { return }
            let observations = latestWindows.values.compactMap { w -> RangeObservation? in
                guard let a = anchors[w.peerId], now - w.t <= config.maxWindowAge else { return nil }
                return RangeObservation(anchor: a, window: w, model: model(w.channel))
            }
            guard let solution = RangeGeometry.solve(observations) else { return }
            geometry = solution
            applyGeometry(solution, now: now)
        }

        private func isTight(for anchor: Anchor) -> Bool {
            let cov = Covariance2(xx: P[Self.X, Self.X], xz: P[Self.X, Self.Z], zz: P[Self.Z, Self.Z])
            let sigma = cov.eigenvalues.major.squareRoot()
            let d = Vec2(x: x[Self.X], z: x[Self.Z]).distance(to: anchor.position)
            return sigma <= config.tightPriorMax && sigma <= config.tightPriorRatio * max(d, 2)
        }

        private func ensureBias(_ id: String, model m: PathLossModel, anchor: Anchor, t: TimeInterval) -> Int {
            if let i = biasIndex[id], let link = biasLink[id] {
                // Shadowing decorrelates as either phone moves and, slowly, with time.
                // Without step data the phone may have walked off at walking pace.
                let unseen = config.useMotion ? 0 : config.walkingSpeed * max(0, t - link.t)
                let moved = (walked - link.walked) + anchor.position.distance(to: link.anchor) + unseen
                let rho = exp(-moved / m.decorrelationDistance) * exp(-max(0, t - link.t) / config.shadowTimeConstant)
                x[i] *= rho
                for j in 0..<dim where j != i {
                    P[i, j] *= rho
                    P[j, i] *= rho
                }
                P[i, i] = rho * rho * P[i, i] + (1 - rho * rho) * m.sigmaShadow * m.sigmaShadow
                biasLink[id] = (walked, anchor.position, t)
                return i
            }
            let n = dim
            var grown = Matrix(rows: n + 1, cols: n + 1)
            for i in 0..<n { for j in 0..<n { grown[i, j] = P[i, j] } }
            grown[n, n] = m.sigmaShadow * m.sigmaShadow
            P = grown
            x.append(0)
            biasIndex[id] = n
            biasLink[id] = (walked, anchor.position, t)
            return n
        }

        private func removeBias(_ id: String) {
            guard let i = biasIndex[id] else { return }
            let n = dim
            var shrunk = Matrix(rows: n - 1, cols: n - 1)
            for r in 0..<n where r != i {
                for c in 0..<n where c != i { shrunk[r < i ? r : r - 1, c < i ? c : c - 1] = P[r, c] }
            }
            P = shrunk
            x.remove(at: i)
            biasIndex[id] = nil
            biasLink[id] = nil
            for (k, v) in biasIndex where v > i { biasIndex[k] = v - 1 }
        }

        /// Iterated EKF update with one median RSSI window, measured in dB against
        /// p0 - 10 n log10(d) + shadowing. The anchor's uncertainty, the time-smearing of the window
        /// and the late arrival are all added to the noise.
        private func rangeUpdate(_ w: RSSIWindow, _ anchor: Anchor, now: TimeInterval) {
            let m = model(w.channel)
            let bi = ensureBias(anchor.id, model: m, anchor: anchor, t: w.t)
            // Our position at the window's time = now minus the steps walked since.
            let back = displacementSince(w.t)
            let a = anchor.position
            let sa = anchor.sigma(at: w.t)
            let smear = config.walkingSpeed * config.medianWindow / 4
            let fewSamples = w.channel == .relayedSmoothed ? 1 : max(1, Double(rssi.minSamples * 3) / Double(max(1, w.count)))
            let prior = x
            var xi = x
            var h = row([:])
            var r = 0.0
            var innovation = 0.0
            for _ in 0..<3 {
                let px = xi[Self.X] - back.x - a.x
                let pz = xi[Self.Z] - back.z - a.z
                let d = max(m.minDistance, hypot(px, pz))
                let g = hypot(px, pz) > m.minDistance ? -m.slope / (d * d) : 0
                h = row([Self.X: g * px, Self.Z: g * pz, bi: 1])
                let grad2 = m.slope * m.slope / (d * d)
                r = m.sigmaFast * m.sigmaFast * min(4, fewSamples)
                    + grad2 * (sa * sa + smear * smear + pow(0.1 * back.length, 2))
                let predicted = m.expectedRSSI(distance: d) + xi[bi]
                // IEKF: linearize at xi, correct relative to the prior.
                var hd = 0.0
                for j in 0..<dim where h[j] != 0 { hd += h[j] * (prior[j] - xi[j]) }
                innovation = w.median - predicted - hd
                var ph = Array(repeating: 0.0, count: dim)
                var s = r
                for i in 0..<dim {
                    var v = 0.0
                    for j in 0..<dim where h[j] != 0 { v += P[i, j] * h[j] }
                    ph[i] = v
                }
                for j in 0..<dim where h[j] != 0 { s += h[j] * ph[j] }
                for i in 0..<dim { xi[i] = prior[i] + ph[i] / s * innovation }
            }
            // Gate and commit with the final linearization (innovation relative to the prior).
            let applied = scalarUpdate(h, innovation: innovation, r: r, gate: Stats.chi2_1dof_997)
            noteResidual(lastNIS, dimensions: 1, into: &rangeNIS)
            if applied {
                diagnostics.rangeUpdates += 1
                lastBluetoothUpdate = now
                pointConfirmed = true
                lastAbsoluteAt = max(lastAbsoluteAt ?? w.t, w.t)
                usedAnchors[anchor.id] = now
                if anchor.gnssDependent { gnssDependent = true }
                bluetoothConflicts = 0
                record(.bleRange, anchor.id, w.t, used: true, nil)
            } else {
                diagnostics.rangeRejected += 1
                record(.bleRange, anchor.id, w.t, used: false, "range outlier (blocked link or reflection)")
            }
        }

        /// Broad prior. Point evidence (a multilateration, or the candidate of an ambiguous pair that
        /// the prior clearly prefers) is fused when it is tighter than the prior. Region evidence (a disc,
        /// an unresolved pair) is not fused: `estimate` shows the region when it is tighter. If dead
        /// reckoning keeps contradicting Bluetooth, the point is dropped in favour of Bluetooth.
        private func applyGeometry(_ g: GeometrySolution, now: TimeInterval) {
            diagnostics.geometryUpdates += 1
            let source: Contribution.Source
            switch g.kind {
            case .proximity: source = .bleProximity
            case .ambiguous: source = .bleAmbiguous
            case .multilateration: source = .bleMultilateration
            }
            let dependent = g.anchorIds.contains { anchors[$0]?.gnssDependent ?? false }

            guard positionReady else {
                if g.kind == .multilateration {
                    initializePosition(g.center, g.covariance, source: .multilateration)
                    markBluetooth(g, now: now, dependent: dependent, source: source, note: "initialized")
                } else if g.kind == .proximity && config.useMotion {
                    // With steps, a disc is a usable start: motion and later ranges resolve it. It is
                    // shown as the disc until something confirms a point.
                    initializePosition(g.center, g.covariance, source: .proximity)
                    markRegion(g, now: now, source: source)
                } else {
                    markRegion(g, now: now, source: source)
                }
                return
            }

            let prior = Covariance2(xx: P[Self.X, Self.X], xz: P[Self.X, Self.Z], zz: P[Self.Z, Self.Z])
            let p = Vec2(x: x[Self.X], z: x[Self.Z])
            var point: (z: Vec2, r: Covariance2)?
            switch g.kind {
            case .multilateration:
                point = (g.center, g.covariance)
            case .ambiguous:
                let side = g.r95 - g.candidates.map { $0.distance(to: g.center) }.max()!
                let candidateCov = Covariance2.isotropic(sigma: max(1, side) / Stats.r95PerSigma)
                let scored = g.candidates.compactMap { c -> (Vec2, Double)? in
                    let s = Covariance2(xx: prior.xx + candidateCov.xx, xz: prior.xz, zz: prior.zz + candidateCov.zz)
                    return s.mahalanobis2(c - p).map { (c, $0) }
                }.sorted { $0.1 < $1.1 }
                if scored.count == 2, scored[0].1 < Stats.chi2_2dof_999, scored[1].1 - scored[0].1 > 6 {
                    point = (scored[0].0, candidateCov)
                }
            case .proximity:
                break
            }

            if let point {
                // Region-derived evidence may repeat the same windows: only ever tighten.
                guard point.r.eigenvalues.major < prior.eigenvalues.major else { return }
                let consistent = Covariance2(xx: prior.xx + point.r.xx, xz: prior.xz + point.r.xz, zz: prior.zz + point.r.zz)
                    .mahalanobis2(point.z - p).map { $0 <= Stats.chi2_2dof_999 } ?? false
                if consistent, positionUpdate(point.z, point.r) {
                    bluetoothConflicts = 0
                    markBluetooth(g, now: now, dependent: dependent, source: source, note: nil)
                    return
                }
            } else if p.distance(to: g.center) <= g.r95 + prior.r95 {
                bluetoothConflicts = 0
                markRegion(g, now: now, source: source)
                return
            }
            bluetoothConflicts += 1
            guard bluetoothConflicts >= config.bluetoothResetAfter else {
                for id in g.anchorIds { record(source, id, g.t, used: false, "disagrees with dead reckoning") }
                return
            }
            restartedFromBluetoothAt = now
            bluetoothConflicts = 0
            if g.kind == .multilateration {
                initializePosition(g.center, g.covariance, source: .multilateration)
                markBluetooth(g, now: now, dependent: dependent, source: source, note: "restarted: dead reckoning disagreed with Bluetooth")
            } else {
                positionReady = false
                markRegion(g, now: now, source: source)
                for id in g.anchorIds { record(source, id, g.t, used: true, "dead reckoning dropped: it disagreed with Bluetooth") }
            }
        }

        /// Region evidence considered (not fused): kept for the provenance of a region estimate.
        private func markRegion(_ g: GeometrySolution, now: TimeInterval, source: Contribution.Source) {
            for id in g.anchorIds {
                usedAnchors[id] = now
                record(source, id, g.t, used: true, g.kind == .ambiguous ? "two candidate spots" : "within a disc around it")
            }
            if g.anchorIds.contains(where: { anchors[$0]?.gnssDependent ?? false }) { gnssDependent = true }
        }

        private func markBluetooth(_ g: GeometrySolution, now: TimeInterval, dependent: Bool, source: Contribution.Source, note: String?) {
            lastBluetoothUpdate = now
            pointConfirmed = true
            lastAbsoluteAt = max(lastAbsoluteAt ?? g.t, g.t)
            for id in g.anchorIds { usedAnchors[id] = now }
            if dependent { gnssDependent = true }
            for id in g.anchorIds { record(source, id, g.t, used: true, note) }
        }

        private func pruneAnchors(now: TimeInterval) {
            for (id, a) in anchors where now - a.measuredAt > config.anchorMaxAge {
                anchors[id] = nil
                latestWindows[id] = nil
            }
            for id in biasLink.keys.sorted() where now - biasLink[id]!.t > config.forgetAnchorBiasAfter { removeBias(id) }
        }

        // MARK: - Provenance

        private func record(_ source: Contribution.Source, _ peer: String?, _ t: TimeInterval, used: Bool, _ reason: String?) {
            contributions.append(Contribution(source: source, peerId: peer, t: t, used: used, reason: reason))
            if contributions.count > 256 { contributions.removeFirst(contributions.count - 256) }
        }

        /// The latest contribution per (source, peer) from the last 60 s, newest first, at most 16
        /// (the contract's input limit).
        private func summarizedProvenance(now: TimeInterval) -> [Contribution] {
            var seen = Set<String>()
            var out: [Contribution] = []
            for c in contributions.reversed() where now - c.t <= 60 {
                let key = c.source.rawValue + "|" + (c.peerId ?? "")
                if seen.insert(key).inserted { out.append(c) }
                if out.count == 16 { break }
            }
            return out
        }
    }
}
