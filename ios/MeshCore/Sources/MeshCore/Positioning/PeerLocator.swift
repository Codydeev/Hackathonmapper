import Foundation

extension Positioning {
    /// Places phones that have no trusted position of their own, for the pipeline's positioning slot
    /// (`GhostPositioningEngine`), with the rules this phone's own engine follows: one anchor gives a
    /// disc around it, two give a candidate pair, a point needs three well-placed anchors or a
    /// remembered trusted position carried forward. Each lost phone gets its own `Engine` without
    /// motion (a peer's steps are not relayed), so its uncertainty grows at walking pace between
    /// Bluetooth evidence and is never pulled toward an anchor by a single range.
    public final class PeerLocator: GhostPositioningEngine {
        public static let algorithm = "ghostcore-peer-locator@0.1"
        /// A lost phone's last anchor-grade position older than this is not used as its start.
        public static let rememberFor = 120.0
        /// Matches the baseline estimator's freshness for placed peers.
        public static let maxAge = 6.0

        public let producerId: String
        public let frameId: String
        private let config: Engine.Config
        private var engines: [String: Engine] = [:]
        private var lastAnchor: [String: PositionEstimate] = [:]

        /// `model`: path loss for the mesh's link RSSI (smoothed on the reporting phones).
        public init(producerId: String, frameId: String, model: PathLossModel? = nil) {
            self.producerId = producerId
            self.frameId = frameId
            var config = Engine.Config()
            config.useMotion = false
            config.useCompass = false
            // A remembered fix starts the track; it is never this phone's measurement of the peer now.
            config.gnssFreshFor = -1
            if let model { config.models[.relayedSmoothed] = model }
            self.config = config
        }

        public func place(anchors: [PositionEstimate], lost: [String], links: [LinkMeasurement],
                          observations: [PeerObservation], now: Double) -> [PositionEstimate] {
            let usable = anchors.filter { $0.position != nil && !$0.uncertainty.ambiguous }
            for a in usable where lastAnchor[a.subjectId].map({ $0.timestamp <= a.timestamp }) ?? true {
                lastAnchor[a.subjectId] = a
            }
            // A phone with its own position again starts from scratch the next time it is lost.
            engines = engines.filter { lost.contains($0.key) }
            var out: [PositionEstimate] = []
            for id in Set(lost).sorted() {
                let engine = engines[id] ?? start(id, now: now)
                var upstream: [String: Provenance] = [:]
                for a in usable where a.subjectId != id && !a.provenance.contains(device: id) {
                    engine.ingest(anchor: Self.anchor(a))
                    upstream[a.subjectId] = a.provenance
                }
                for link in links {
                    guard let other = link.a == id ? link.b : (link.b == id ? link.a : nil), upstream[other] != nil else { continue }
                    engine.ingest(rssi: RSSISample(peerId: other, rssi: link.rssi, t: now, channel: .relayedSmoothed))
                }
                let e = engine.estimate(at: now)
                guard e.method != .unavailable else { continue }
                // The lost phone contributed its own link readings.
                let sources = e.anchorIds.compactMap { upstream[$0] }
                    + [Provenance(producerId: id, algorithm: "mesh-report@1", gnssDependent: false)]
                let record = ContractMapping.positionEstimate(e, subjectId: id, clock: Clock(unixMinusMonotonic: 0),
                                                              upstream: sources, simulated: sources.contains { $0.simulated },
                                                              producerId: producerId, maxAge: Self.maxAge)
                if (try? record.validate()) != nil { out.append(record) }
            }
            return out
        }

        private func start(_ id: String, now: Double) -> Engine {
            let engine = Engine(selfId: id, frameId: frameId, config: config)
            engines[id] = engine
            if let last = lastAnchor[id], let p = last.position, now - last.timestamp <= Self.rememberFor {
                // Its last trusted position, widening at walking pace for its age.
                let radius68 = last.uncertainty.r95 / PositionUncertainty.r95(fromRadius68: 1)
                engine.ingest(gnss: GNSSFix(t: last.timestamp - last.freshness.ageAtHandoff, position: Vec2(x: p.x, z: p.z),
                                            horizontalAccuracy: radius68, trusted: true))
            }
            return engine
        }

        /// An anchor-grade contract position as an engine anchor; timed by its receipt, not its sender's clock.
        static func anchor(_ a: PositionEstimate) -> Anchor {
            let p = a.position!
            let sigma = a.uncertainty.covariance.map { $0.largestVariance.squareRoot() }
                ?? a.uncertainty.r95 / PositionUncertainty.sigmaTo95
            let kind: Anchor.Kind = a.kind == .measured ? .gnss : (a.kind == .declared ? .surveyed : .estimated)
            return Anchor(id: a.subjectId, position: Vec2(x: p.x, z: p.z), sigma: sigma, kind: kind,
                          measuredAt: a.timestamp - a.freshness.ageAtHandoff, timeSigma: ContractMapping.relayTimeSigma,
                          speedBound: a.kind == .declared ? 0.3 : 1.5, dependsOn: a.provenance.contributors,
                          gnssDependent: a.provenance.gnssDependent)
        }
    }
}
