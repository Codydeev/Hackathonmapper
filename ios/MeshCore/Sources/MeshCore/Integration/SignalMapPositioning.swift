import Foundation

/// The signal map in the pipeline's positioning slot, so the app's main map places phones without
/// a position the way the dashboard and the Track tab do (`SignalMap`, golden-tested against
/// website/shared/signalmap.ts): every phone in the mesh is laid out so its distances match the
/// links' UWB distances where measured and RSSI ranges otherwise, with measured and typed
/// positions as priors and the radio model calibrated from UWB distances and placed phones.
///
/// A lost phone whose group the anchors don't fix in direction gets an ambiguous estimate whose
/// circle covers its whole ring, never a confident spot on it. One that the mesh doesn't connect to
/// any anchor gets no estimate: it has no place in the world.
public final class SignalMapPositioning: GhostPositioningEngine {
    public static let algorithm = "signal-map@1"
    /// Matches the other engines' freshness for placed peers.
    public static let maxAge = 6.0

    public let producerId: String
    public let frameId: String
    /// The radio model the solve starts from; each solve calibrates its own copy.
    public let radio: RadioModel
    /// Which distances it uses (a feature switch for comparing them; both by default).
    public var ranges = SignalRanges.all
    /// Fit the radio model from UWB distances and placed phones each solve; off keeps `radio`.
    public var calibrate = true
    /// The radio model after the last solve.
    public private(set) var calibratedRadio: RadioModel
    /// Last layout, so the picture stays put from one second to the next.
    private var layout: [String: FloorPoint] = [:]

    public init(producerId: String, frameId: String, radio: RadioModel = .standard) {
        self.producerId = producerId
        self.frameId = frameId
        self.radio = radio
        calibratedRadio = radio
    }

    public func place(anchors: [PositionEstimate], lost: [String], links: [LinkMeasurement],
                      observations: [PeerObservation], now: Double) -> [PositionEstimate] {
        guard !lost.isEmpty else { return [] }
        let measured = ranges.apply(links)
        let usable = anchors.filter { $0.position != nil }
        var ids = Set(lost)
        for anchor in usable { ids.insert(anchor.subjectId) }
        for link in measured {
            ids.insert(link.a)
            ids.insert(link.b)
        }
        let priors = usable.map { anchor -> SignalPrior in
            let p = anchor.position!
            return SignalPrior(id: anchor.subjectId, x: p.x, z: p.z, r95: anchor.uncertainty.r95)
        }
        let result = SignalMap.solve(ids: Array(ids), links: measured.map { SignalLink(a: $0.a, b: $0.b, rssi: $0.rssi, uwb: $0.uwb) },
                                     priors: priors, radio: radio, previous: layout, calibrate: calibrate)
        layout = Dictionary(result.nodes.map { ($0.id, FloorPoint(x: $0.x, z: $0.z)) }, uniquingKeysWith: { first, _ in first })
        calibratedRadio = result.radio
        let nodes = Dictionary(result.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var out: [PositionEstimate] = []
        for id in Set(lost).sorted() {
            guard let node = nodes[id], let place = SignalMap.placeInWorld(node, nodes: nodes) else { continue }
            // The anchors this phone's group hangs on: its evidence and its provenance.
            let group = usable.filter { nodes[$0.subjectId]?.component == node.component && $0.subjectId != id }
            guard !group.isEmpty else { continue }
            let usesUWB = result.links.contains { ($0.a == id || $0.b == id) && $0.uwb != nil }
            let linkCount = result.links.filter { $0.a == id || $0.b == id }.count
            let inputs = group.prefix(GhostCoreContract.maxInputs - 1).map {
                ProvenanceInput(source: $0.source, id: $0.subjectId, used: true, reason: "anchor")
            } + [ProvenanceInput(source: usesUWB ? .uwb : .bluetooth, used: true,
                                 reason: "\(linkCount) link\(linkCount == 1 ? "" : "s")\(usesUWB ? " with UWB" : "")")]
            let provenance = Provenance.derived(producerId: producerId, algorithm: Self.algorithm, inputs: inputs,
                                                from: group.map(\.provenance))
            let r95 = min(max(place.r95, 0.1), GhostCoreContract.maxRadius)
            let estimate = PositionEstimate(subjectId: id, timestamp: now, frameId: frameId, kind: .estimated,
                                            method: .multilateration, position: Position(x: place.x, y: 0, z: place.z),
                                            uncertainty: PositionUncertainty(r95: r95, ambiguous: place.ambiguous),
                                            lastAbsoluteAt: group.map(\.timestamp).max(), source: usesUWB ? .uwb : .bluetooth,
                                            freshness: Freshness(maxAge: Self.maxAge), provenance: provenance)
            if (try? estimate.validate()) != nil { out.append(estimate) }
        }
        return out
    }
}
