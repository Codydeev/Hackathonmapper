import Foundation

extension Positioning {
    /// Collects RSSI from one peer while the two phones stand at marked distances, then fits the
    /// path-loss model. Workflow: put the phones at the first marked distance (tape measure, same
    /// height, same way they will be carried), `begin`, wait until `isStepComplete`, `end`, move to
    /// the next distance. At least three distances spanning 4x are required; the suggested set
    /// spans 1-16 m because ranges beyond that are where the demo needs to tell "near" from "far".
    public struct CalibrationSession: Codable, Equatable {
        public struct Step: Codable, Equatable {
            public let distance: Double
            /// Free text: orientation, obstruction, "in hand", "pocket", ...
            public let label: String
            public var samples: [RSSISample]
        }

        public static let suggestedDistances: [Double] = [1, 2, 3, 5, 8, 12, 16]

        public let peerId: String
        public let channel: RSSIChannel
        /// Phone models of this phone and the peer: calibration does not transfer between models.
        public let observerModel: String
        public let peerModel: String
        public let environment: String
        public var minSamplesPerStep = 40
        public var minDurationPerStep: TimeInterval = 20

        public private(set) var steps: [Step] = []
        public private(set) var activeStep: Int?

        public init(peerId: String, channel: RSSIChannel, observerModel: String, peerModel: String, environment: String) {
            self.peerId = peerId
            self.channel = channel
            self.observerModel = observerModel
            self.peerModel = peerModel
            self.environment = environment
        }

        public mutating func begin(distance: Double, label: String = "") {
            guard distance.isFinite, distance > 0 else { return }
            steps.append(Step(distance: distance, label: label, samples: []))
            activeStep = steps.count - 1
        }

        /// Records a sample if a step is active and it comes from the calibrated peer and channel.
        @discardableResult
        public mutating func record(_ sample: RSSISample) -> Bool {
            guard let i = activeStep, sample.peerId == peerId, sample.channel == channel,
                  RSSIMedianFilter.isValid(sample.rssi) else { return false }
            steps[i].samples.append(sample)
            return true
        }

        public mutating func end() { activeStep = nil }

        /// Drops the last step, e.g. after someone walked between the phones.
        public mutating func discardLastStep() {
            if !steps.isEmpty { steps.removeLast() }
            activeStep = nil
        }

        public var isStepComplete: Bool {
            guard let i = activeStep, let first = steps[i].samples.first, let last = steps[i].samples.last else { return false }
            return steps[i].samples.count >= minSamplesPerStep && last.t - first.t >= minDurationPerStep
        }

        /// Fits the model. `window` must match the engine's median window, since the fitted spread
        /// describes window medians, not raw samples.
        public func fit(window: TimeInterval = 4, date: String = "") throws -> CalibrationResult {
            try CalibrationFit.fit(steps: steps.filter { !$0.samples.isEmpty }, window: window, channel: channel,
                                   source: "calibrated \(date) \(observerModel)->\(peerModel) \(channel.rawValue) \(environment)")
        }
    }

    public enum CalibrationError: Error, Equatable {
        case tooFewDistances(found: Int)
        case distanceSpanTooSmall(ratio: Double)
        case tooFewWindows(distance: Double)
        case nonPhysicalFit(n: Double)
    }

    public struct CalibrationResult: Codable, Equatable {
        public struct DistanceSummary: Codable, Equatable {
            public let distance: Double
            /// Median of the window medians at this distance, dBm.
            public let rssi: Double
            public let windows: Int
            /// Robust spread of the window medians at this distance, dB.
            public let spread: Double
            /// Measured minus fitted, dB.
            public let residual: Double
        }

        public let model: PathLossModel
        public let distances: [DistanceSummary]
        public let rSquared: Double
        /// RMS of distance medians around the line, dB.
        public let residualRMS: Double
        /// Leave-one-distance-out: each distance predicted by a fit to the others.
        public let leaveOneOutRMS: Double
        /// Median of |predicted / true - 1| for the held-out distances' median range.
        public let leaveOneOutRangeError: Double
        public let warnings: [String]
    }

    enum CalibrationFit {
        /// Splits a step's samples into consecutive windows and returns the window medians.
        static func windowMedians(_ samples: [RSSISample], window: TimeInterval, channel: RSSIChannel) -> [Double] {
            let sorted = samples.sorted { $0.t < $1.t }
            guard let start = sorted.first?.t else { return [] }
            var groups: [Int: [RSSISample]] = [:]
            for s in sorted { groups[Int((s.t - start) / window), default: []].append(s) }
            return groups.keys.sorted().compactMap { k in
                RSSIMedianFilter.summarize(groups[k]!, peerId: "", channel: channel, minSamples: 2)?.median
            }
        }

        /// Huber-weighted least squares for y = p0 + n * x with x = -10 log10(d).
        static func line(_ points: [(x: Double, y: Double)]) -> (p0: Double, n: Double)? {
            guard points.count >= 2 else { return nil }
            var weights = Array(repeating: 1.0, count: points.count)
            var result: (p0: Double, n: Double)?
            for _ in 0..<10 {
                let sw = weights.reduce(0, +)
                let mx = zip(points, weights).reduce(0) { $0 + $1.0.x * $1.1 } / sw
                let my = zip(points, weights).reduce(0) { $0 + $1.0.y * $1.1 } / sw
                var sxx = 0.0
                var sxy = 0.0
                for (p, w) in zip(points, weights) {
                    sxx += w * (p.x - mx) * (p.x - mx)
                    sxy += w * (p.x - mx) * (p.y - my)
                }
                guard sxx > 1e-9 else { return nil }
                let n = sxy / sxx
                let p0 = my - n * mx
                result = (p0, n)
                let residuals = points.map { $0.y - (p0 + n * $0.x) }
                let scale = max(1, Stats.robustSpread(residuals, around: 0))
                let k = 1.345 * scale
                weights = residuals.map { abs($0) <= k ? 1 : k / abs($0) }
            }
            return result
        }

        static func fit(steps: [CalibrationSession.Step], window: TimeInterval, channel: RSSIChannel,
                        source: String) throws -> CalibrationResult {
            // Repeated steps at one distance (e.g. two orientations) pool their windows.
            var byDistance: [Double: [Double]] = [:]
            for step in steps {
                let medians = windowMedians(step.samples, window: window, channel: channel)
                byDistance[step.distance, default: []].append(contentsOf: medians)
            }
            let distances = byDistance.keys.sorted()
            guard distances.count >= 3 else { throw CalibrationError.tooFewDistances(found: distances.count) }
            let ratio = distances.last! / distances.first!
            guard ratio >= 4 else { throw CalibrationError.distanceSpanTooSmall(ratio: ratio) }
            for d in distances where (byDistance[d]?.count ?? 0) < 2 { throw CalibrationError.tooFewWindows(distance: d) }

            let centers = distances.map { Stats.median(byDistance[$0]!)! }
            let points = zip(distances, centers).map { (x: -10 * log10($0.0), y: $0.1) }
            guard let (p0, n) = line(points) else { throw CalibrationError.distanceSpanTooSmall(ratio: ratio) }
            guard n > 0.5, n < 6 else { throw CalibrationError.nonPhysicalFit(n: n) }

            let residuals = points.map { $0.y - (p0 + n * $0.x) }
            let residualRMS = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
            let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
            let ssTot = points.map { ($0.y - meanY) * ($0.y - meanY) }.reduce(0, +)
            let rSquared = ssTot > 0 ? 1 - residuals.map { $0 * $0 }.reduce(0, +) / ssTot : 0

            // Spread of window medians around their own distance's median: fading after the filter.
            var deviations: [Double] = []
            for (d, c) in zip(distances, centers) { deviations += byDistance[d]!.map { $0 - c } }
            let sigmaFast = max(1, Stats.robustSpread(deviations, around: 0))

            var looResiduals: [Double] = []
            var looRangeErrors: [Double] = []
            for i in points.indices where points.count > 3 {
                var rest = points
                rest.remove(at: i)
                guard let (p, k) = line(rest), k > 0 else { continue }
                looResiduals.append(points[i].y - (p + k * points[i].x))
                let predicted = pow(10, (p - centers[i]) / (10 * k))
                looRangeErrors.append(abs(predicted / distances[i] - 1))
            }
            let looRMS = looResiduals.isEmpty ? residualRMS
                : (looResiduals.map { $0 * $0 }.reduce(0, +) / Double(looResiduals.count)).squareRoot()

            var warnings: [String] = []
            // One calibration walk sees one spot per distance, so it underestimates spot-to-spot
            // shadowing; outdoors 4-8 dB is typical. Never let a lucky fit claim less than 3 dB.
            // Each distance's centre is a median over many windows, so fading barely reaches it.
            let sigmaShadow = max(3, residualRMS)
            if residualRMS < 3 { warnings.append("Shadowing floored at 3 dB: one calibration walk cannot measure spot-to-spot variation.") }
            if n < 1.6 || n > 4.5 { warnings.append(String(format: "Path-loss exponent %.2f is outside the usual 1.6-4.5.", n)) }
            if p0 > -35 || p0 < -85 { warnings.append(String(format: "RSSI at 1 m of %.1f dBm is unusual for phones.", p0)) }
            if distances.count < 5 { warnings.append("Fewer than 5 distances: the leave-one-out check is weak.") }
            if rSquared < 0.8 { warnings.append(String(format: "R² %.2f: RSSI barely follows distance here; ranges will be wide.", rSquared)) }

            let model = PathLossModel(p0: p0, n: n, sigmaFast: sigmaFast, sigmaShadow: sigmaShadow, source: source)
            let summaries = distances.indices.map { i in
                CalibrationResult.DistanceSummary(distance: distances[i], rssi: centers[i], windows: byDistance[distances[i]]!.count,
                                                  spread: Stats.robustSpread(byDistance[distances[i]]!, around: centers[i]),
                                                  residual: residuals[i])
            }
            return CalibrationResult(model: model, distances: summaries, rSquared: rSquared, residualRMS: residualRMS,
                                     leaveOneOutRMS: looRMS, leaveOneOutRangeError: Stats.median(looRangeErrors) ?? .nan,
                                     warnings: warnings)
        }
    }
}
