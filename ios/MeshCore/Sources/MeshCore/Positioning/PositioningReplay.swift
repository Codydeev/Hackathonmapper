import Foundation

extension Positioning {
    /// One recorded engine input or ground-truth sample. A walk recorded on a phone (JSON lines) and
    /// a synthetic track use the same records, so both go through the same replay and metrics.
    public enum LogRecord: Codable, Equatable {
        case header(selfId: String, frameId: String, note: String)
        case gnss(fix: GNSSFix)
        case motion(sample: MotionSample)
        case compass(sample: CompassSample)
        case step(event: StepEvent)
        case rssi(sample: RSSISample)
        case anchor(anchor: Anchor)
        case removeAnchor(id: String, t: TimeInterval)
        case declared(position: Vec2, sigma: Double, t: TimeInterval)
        /// Independent reference position (surveyed marker, RTK, or a simulation's true track).
        case truth(position: Vec2, t: TimeInterval)

        public var t: TimeInterval {
            switch self {
            case .header: return -Double.infinity
            case .gnss(let f): return f.t
            case .motion(let s): return s.t
            case .compass(let s): return s.t
            case .step(let e): return e.t
            case .rssi(let s): return s.t
            case .anchor(let a): return a.measuredAt
            case .removeAnchor(_, let t), .declared(_, _, let t), .truth(_, let t): return t
            }
        }

        public static func encodeLines(_ records: [LogRecord]) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = Data()
            for r in records {
                data.append(try encoder.encode(r))
                data.append(0x0A)
            }
            return data
        }

        public static func decodeLines(_ data: Data) throws -> [LogRecord] {
            let decoder = JSONDecoder()
            return try data.split(separator: 0x0A).filter { !$0.isEmpty }.map { try decoder.decode(LogRecord.self, from: Data($0)) }
        }
    }

    public struct ReplayEpoch: Equatable {
        public let estimate: Estimate
        public let truth: Vec2?
        /// Distance from the point estimate to the truth (nil for region-only estimates).
        public let error: Double?
        /// Truth inside the reported r95 around the position or region centre.
        public let contained: Bool?
        /// For ambiguous estimates: distance from the truth to the nearest candidate.
        public let candidateError: Double?
    }

    public enum Replay {
        public struct Options {
            public var estimateEvery: TimeInterval = 1
            /// Real walks: record with GPS on, then hide the fixes after this time from the engine and
            /// use them as the reference instead (only fixes at least this accurate).
            public var maskGNSSAfter: TimeInterval?
            public var gnssTruthMaxAccuracy = 10.0
            public var start: TimeInterval?
            public var end: TimeInterval?

            public init() {}
        }

        /// Feeds the records to `engine` in time order and asks for an estimate every
        /// `estimateEvery` seconds, scoring each against the interpolated reference.
        public static func run(_ records: [LogRecord], engine: Engine, options: Options = Options()) -> [ReplayEpoch] {
            let sorted = records.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
            var truth: [(t: TimeInterval, p: Vec2)] = []
            for r in sorted {
                switch r {
                case .truth(let p, let t): truth.append((t, p))
                case .gnss(let f) where options.maskGNSSAfter.map({ f.t > $0 }) ?? false && f.horizontalAccuracy <= options.gnssTruthMaxAccuracy:
                    truth.append((f.t, f.position))
                default: break
                }
            }
            truth.sort { $0.t < $1.t }
            let times = sorted.map(\.t).filter(\.isFinite)
            guard let first = times.first, let last = times.last else { return [] }
            var next = options.start ?? (first.rounded(.up))
            let end = options.end ?? last
            var epochs: [ReplayEpoch] = []

            func emit(upTo t: TimeInterval) {
                while next <= t && next <= end {
                    let e = engine.estimate(at: next)
                    epochs.append(score(e, truth: interpolate(truth, at: next)))
                    next += options.estimateEvery
                }
            }

            for r in sorted {
                emit(upTo: r.t)
                switch r {
                case .header, .truth: break
                case .gnss(let f):
                    if options.maskGNSSAfter.map({ f.t > $0 }) ?? false { continue }
                    engine.ingest(gnss: f)
                case .motion(let s): engine.ingest(motion: s)
                case .compass(let c): engine.ingest(compass: c)
                case .step(let e): engine.ingest(step: e)
                case .rssi(let s): engine.ingest(rssi: s)
                case .anchor(let a): engine.ingest(anchor: a)
                case .removeAnchor(let id, let t): engine.removeAnchor(id, at: t)
                case .declared(let p, let s, let t): engine.declare(position: p, sigma: s, at: t)
                }
            }
            emit(upTo: end)
            return epochs
        }

        /// Linear interpolation of the reference; nil if no sample within 2 s on both sides.
        static func interpolate(_ truth: [(t: TimeInterval, p: Vec2)], at t: TimeInterval) -> Vec2? {
            guard let hi = truth.firstIndex(where: { $0.t >= t }) else { return nil }
            if truth[hi].t == t || hi == 0 { return t >= truth[hi].t - 2 ? truth[hi].p : nil }
            let a = truth[hi - 1], b = truth[hi]
            guard t - a.t <= 2, b.t - t <= 2 else { return nil }
            let f = (t - a.t) / (b.t - a.t)
            return a.p + (b.p - a.p) * f
        }

        public static func score(_ e: Estimate, truth: Vec2?) -> ReplayEpoch {
            guard let truth else { return ReplayEpoch(estimate: e, truth: nil, error: nil, contained: nil, candidateError: nil) }
            let error = e.position.map { $0.distance(to: truth) }
            var contained: Bool?
            if let r = e.r95, let c = e.position ?? e.regionCenter { contained = c.distance(to: truth) <= r }
            let candidateError = e.candidates.map { $0.distance(to: truth) }.min()
            return ReplayEpoch(estimate: e, truth: truth, error: error, contained: contained, candidateError: candidateError)
        }
    }

    /// Accuracy against ground truth over a set of epochs.
    public struct AccuracySummary: Codable, Equatable {
        public let epochs: Int
        /// Share of scored epochs with a point estimate (the rest are regions or unavailable).
        public let pointAvailability: Double
        public let medianError: Double?
        public let p95Error: Double?
        public let maxError: Double?
        public let rmse: Double?
        /// Share of epochs with an r95 whose circle held the truth. 0.95 is honest; well below means
        /// overconfident; 1.0 with a huge r95 means honest but uninformative.
        public let containment: Double?
        public let medianR95: Double?
        public let methods: [String: Int]

        public static func of(_ epochs: [ReplayEpoch]) -> AccuracySummary {
            let scored = epochs.filter { $0.truth != nil }
            let errors = scored.compactMap(\.error)
            let contained = scored.compactMap(\.contained)
            let r95s = scored.compactMap(\.estimate.r95)
            var methods: [String: Int] = [:]
            for e in scored { methods[e.estimate.method.rawValue, default: 0] += 1 }
            return AccuracySummary(
                epochs: scored.count,
                pointAvailability: scored.isEmpty ? 0 : Double(errors.count) / Double(scored.count),
                medianError: Stats.median(errors), p95Error: Stats.percentile(errors, 0.95), maxError: errors.max(),
                rmse: errors.isEmpty ? nil : (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot(),
                containment: contained.isEmpty ? nil : Double(contained.filter { $0 }.count) / Double(contained.count),
                medianR95: Stats.median(r95s), methods: methods)
        }
    }
}
