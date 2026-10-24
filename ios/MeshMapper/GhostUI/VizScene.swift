import CoreLocation
import Foundation
import MeshCore

// What the GhostCore map draws, one snapshot per second, built from the GhostCore contract records
// (PositionEstimate, IntegrityAssessment, Prediction, PeerObservation, relay routes). This file is
// the only place that knows where the data comes from. Nothing here invents a value: a field the
// pipeline did not provide stays nil and the UI says so.

typealias VizKind = PositionEstimate.Kind
typealias VizMethod = PositionEstimate.Method
typealias VizIntegrityStatus = IntegrityAssessment.Status

extension PositionEstimate.Method {
    var title: String {
        switch self {
        case .gnss: return "GPS"
        case .uwb: return "UWB"
        case .multilateration: return "Bluetooth multilateration"
        case .proximity: return "Bluetooth proximity"
        case .particle: return "Bluetooth particle filter"
        case .deadReckoning: return "dead reckoning"
        case .fusion: return "fusion"
        case .manual: return "typed spot"
        case .prediction: return "prediction"
        case .none: return "none"
        }
    }
}

struct VizEvidence: Identifiable {
    let index: Int
    let check: String
    let observed: Double?
    let threshold: Double?
    let unit: String
    /// 1 = fully consistent, 0 = impossible.
    let score: Double
    /// False when the evidence itself depends on GNSS (e.g. a peer placed by GPS).
    let independent: Bool
    let reason: String?
    var id: Int { index }
}

struct VizReason: Identifiable {
    let code: String
    /// One plain sentence, e.g. "GPS jumped 412 m in one step (limit 25 m)". It never names an attacker.
    let text: String
    var id: String { code }

    /// A sentence from a reason code and the numbers of the check behind it. It states what was
    /// measured against what is physically possible; it never names an attacker.
    static func sentence(code: String, evidence: VizEvidence?) -> String {
        func n(_ v: Double?) -> String {
            guard let v else { return "?" }
            return v >= 100 ? "\(Int(v.rounded()))" : String(format: v >= 10 ? "%.0f" : "%.1f", v)
        }
        let o = n(evidence?.observed), unit = evidence.map { $0.unit.isEmpty ? "" : " \($0.unit)" } ?? ""
        let limit = evidence?.threshold == nil ? "" : " (limit \(n(evidence?.threshold))\(unit))"
        switch code {
        case "noFix": return "No GPS fix"
        case "staleFix": return "Last GPS fix is \(o) s old\(limit)"
        case "invalidFix": return "GPS fix is invalid"
        case "timestampInconsistent": return "GPS fix time does not add up"
        case "degradedAccuracy": return "GPS claims only ±\(o) m\(limit)"
        case "accuracyInconsistent": return "GPS error is larger than the accuracy it claims"
        case "impossibleSpeed": return "GPS implies \(o) m/s, faster than a person moves\(limit)"
        case "impossibleAcceleration": return "GPS implies an impossible acceleration\(limit)"
        case "positionJump": return "GPS jumped \(o) m in one step\(limit)"
        case "inertialDisagreement": return "GPS moved \(o) m the motion sensors did not feel\(limit)"
        case "slowDrift": return "GPS is drifting away from the motion sensors\(limit)"
        case "peerDisagreement": return "GPS is \(o) m from where nearby phones place it\(limit)"
        case "independentEvidenceDisagreement": return "GPS disagrees with an independent position by \(o) m\(limit)"
        case "peerEvidenceNotIndependent": return "Nearby phones agree, but they use GPS too"
        case "insufficientEvidence": return "Nothing independent of GPS confirms it yet"
        case "continuityLost": return "GPS came back after a rejection; waiting for independent confirmation"
        case "recovering": return "Checks pass again; trust is still climbing"
        default:
            let words = code.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// The raw GNSS fix the integrity checks judged, in the shared frame.
struct VizRawFix {
    let point: FloorPoint
    /// r95 from the receiver's claimed accuracy.
    let claimedR95: Double
    let observedAt: Date
    let simulated: Bool
}

struct VizIntegrity {
    let status: VizIntegrityStatus
    let trustScore: Double?
    /// The score's coverage interval (lower is 0 with no GNSS-independent check active).
    let trustLower: Double?
    let reasons: [VizReason]
    let evidence: [VizEvidence]
    let evaluatedFix: VizRawFix?
    /// "GPS could move this phone by up to N m unnoticed"; nil = unbounded.
    let minimumDetectableOffset: Double?
    let summary: String?
    let simulated: Bool

    /// The one line to show: the engine's summary, else the first reason as a sentence.
    var headline: String? { summary ?? reasons.first?.text }
}

struct VizPrediction {
    let lastObservedAt: Date
    let horizon: TimeInterval
    let center: FloorPoint
    let r95: Double?
    let cloud: [FloorPoint]
    let method: String
    let simulated: Bool
}

/// One input behind a position, e.g. "phone-c GNSS, not used: positionJump".
struct VizInput: Identifiable {
    let index: Int
    let source: String
    let deviceId: String?
    let age: Double?
    let used: Bool
    let reason: String?
    var id: Int { index }
}

struct VizPhone: Identifiable {
    let id: String
    let label: String
    let isSelf: Bool
    let kind: VizKind
    let method: VizMethod
    let point: FloorPoint?
    let r95: Double?
    let ambiguous: Bool
    /// Spots an ambiguous estimate cannot choose between; drawn instead of a single dot.
    let candidates: [FloorPoint]
    /// Particle cloud of a Bluetooth estimate (the prediction cloud lives in `prediction`).
    let cloud: [FloorPoint]
    /// When the shown position was last measured; the age shown on screen counts from here.
    let observedAt: Date?
    let hops: Int?
    let integrity: VizIntegrity?
    /// This phone's latest raw GNSS fix, shown even when no trust verdict exists.
    let rawFix: VizRawFix?
    let prediction: VizPrediction?
    let inputs: [VizInput]
    let simulated: Bool

    /// The raw fix to compare with the shown position: the one judged, else the latest.
    var comparedFix: VizRawFix? { integrity?.evaluatedFix ?? rawFix }

    func age(at now: Date) -> TimeInterval? { observedAt.map { max(0, now.timeIntervalSince($0)) } }
}

struct VizLink: Identifiable {
    let a: String
    let b: String
    let rssi: Double
    var id: String { a + "\n" + b }
}

/// One accepted report's way to this phone: origin, then relays oldest first, then this phone.
struct VizRoute: Identifiable {
    let origin: String
    let relays: [String]
    var id: String { origin }
}

struct VizScenarioState {
    let name: String
    let elapsed: TimeInterval
    let stepIndex: Int
    let caption: String?
    let isRunning: Bool
}

struct VizScene {
    var now = Date()
    var frameId = GeoFrame.defaultFrameId
    var selfId = ""
    var phones: [VizPhone] = []
    var links: [VizLink] = []
    var routes: [VizRoute] = []
    var scenario: VizScenarioState?
    /// True when the integrity engine is wired in; without it GPS is shown as not checked, never "trusted".
    var integrityConnected = false

    var me: VizPhone? { phones.first { $0.isSelf } }
    func phone(_ id: String) -> VizPhone? { phones.first { $0.id == id } }
    var anySimulated: Bool {
        scenario?.isRunning == true || phones.contains {
            $0.simulated || $0.integrity?.simulated == true || $0.prediction?.simulated == true
        }
    }

    /// Where a phone is drawn: its prediction centre when predicted, otherwise its point.
    func drawnPoint(_ id: String) -> FloorPoint? {
        guard let phone = phone(id) else { return nil }
        if phone.kind == .predicted, let p = phone.prediction { return p.center }
        return phone.point
    }
}

/// How a phone reads on screen: the honest label for its kind, its colour and whether it is live.
struct VizPresentation {
    let title: String
    let detail: String?
    let tint: VizTint
    let live: Bool

    enum VizTint { case confirmed, unchecked, bluetooth, predicted, rejected, suspect, declared, unknown }

    static func of(_ phone: VizPhone, scene: VizScene) -> VizPresentation {
        let r95 = phone.r95.map { "±\(Int($0.rounded())) m" }
        let age = phone.age(at: scene.now).map(Self.ageText)
        switch phone.kind {
        case .measured:
            let method = phone.method == .uwb ? "UWB" : "GPS"
            let why = phone.integrity?.headline
            switch phone.integrity?.status {
            case .trusted?: return .init(title: "\(method) trusted", detail: r95, tint: .confirmed, live: true)
            case .degraded?: return .init(title: "\(method) degraded", detail: why ?? r95, tint: .suspect, live: true)
            case .suspect?: return .init(title: "\(method) suspect", detail: why ?? r95, tint: .suspect, live: true)
            case .insufficientEvidence?: return .init(title: "\(method) unconfirmed", detail: why ?? r95, tint: .suspect, live: true)
            case .rejected?: return .init(title: "\(method) rejected", detail: why, tint: .rejected, live: true)
            case .unavailable?, nil:
                // No verdict: never drawn as trusted. UWB fixes are not judged by the GNSS checks.
                if phone.method == .uwb { return .init(title: "UWB fix", detail: r95, tint: .confirmed, live: true) }
                return .init(title: "\(method) not checked", detail: r95, tint: .unchecked, live: true)
            }
        case .estimated:
            let what = phone.method == .uwb ? "UWB estimate" : "Bluetooth estimate"
            if phone.ambiguous { return .init(title: "\(what): 2+ spots", detail: r95, tint: .bluetooth, live: true) }
            return .init(title: "\(what) \(r95 ?? "")", detail: phone.hops.map(Self.hopText), tint: .bluetooth, live: true)
        case .predicted:
            return .init(title: "Predicted", detail: age.map { "last seen \($0) ago" }, tint: .predicted, live: false)
        case .declared:
            return .init(title: "Typed spot", detail: r95, tint: .declared, live: true)
        case .unavailable:
            return .init(title: "Position unknown", detail: "needs GPS or a placed peer", tint: .unknown, live: false)
        }
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 90 ? "\(s) s" : "\(s / 60) min"
    }

    static func hopText(_ hops: Int) -> String { "\(hops) hop\(hops == 1 ? "" : "s") from GPS" }
}

// MARK: - Feed from the GhostCore contract records

/// Everything the map needs from the GhostCore pipeline for one frame. Times are Unix seconds on
/// this phone's clock; `*ReceivedAt` is when each subject's latest record arrived here (a record
/// this phone produced itself counts as received at its own timestamp).
struct VizContractInputs {
    var selfId: String
    var frameId: String
    var now: Double
    var labels: [String: String] = [:]
    var positions: [String: PositionEstimate] = [:]
    var integrity: [String: IntegrityAssessment] = [:]
    var predictions: [String: Prediction] = [:]
    var observations: [PeerObservation] = []
    /// Links already paired and averaged by the pipeline; used instead of `observations` when given.
    var links: [VizLink]?
    /// originId -> relays oldest first.
    var routes: [String: [String]] = [:]
    /// Latest raw GNSS fix per phone, judged or not.
    var rawFixes: [String: PositionEstimate] = [:]
    /// Whether an integrity engine runs at all; nil = infer from whether any assessment exists.
    var integrityAvailable: Bool?
    var positionReceivedAt: [String: Double] = [:]
    var integrityReceivedAt: [String: Double] = [:]
    var predictionReceivedAt: [String: Double] = [:]
    var scenario: VizScenarioState?
}

extension VizScene {
    static func contract(_ input: VizContractInputs) -> VizScene {
        let now = input.now
        var scene = VizScene(now: Date(timeIntervalSince1970: now), frameId: input.frameId, selfId: input.selfId)
        scene.integrityConnected = input.integrityAvailable ?? !input.integrity.isEmpty
        scene.scenario = input.scenario

        func floor(_ p: Position) -> FloorPoint { FloorPoint(x: p.x, z: p.z) }
        func date(age: Double) -> Date { Date(timeIntervalSince1970: now - max(0, age)) }

        let ids = Set(input.positions.keys).union(input.predictions.keys).union(input.integrity.keys).union(input.rawFixes.keys)
        for id in ids.sorted() {
            let position = input.positions[id]
            let predictionRecord = input.predictions[id]

            var integrity: VizIntegrity?
            if let record = input.integrity[id] {
                let rx = input.integrityReceivedAt[id] ?? record.timestamp
                let assessedAge = record.freshness.age(receivedAt: rx, now: now)
                let evidence = record.evidence.enumerated().map { i, e in
                    VizEvidence(index: i, check: e.check, observed: e.observed, threshold: e.threshold, unit: e.unit ?? "",
                                score: e.score, independent: e.independent, reason: e.reason?.rawValue)
                }
                let reasons = record.reasons.map { reason in
                    VizReason(code: reason.rawValue,
                              text: VizReason.sentence(code: reason.rawValue, evidence: evidence.first { $0.reason == reason.rawValue }))
                }
                let fix = record.evaluatedFix.flatMap { fix -> VizRawFix? in
                    guard let p = fix.position else { return nil }
                    // The fix's age on this phone: the assessment's age plus how old the fix was when judged.
                    return VizRawFix(point: floor(p), claimedR95: fix.uncertainty.r95,
                                     observedAt: date(age: assessedAge + max(0, record.timestamp - fix.timestamp)),
                                     simulated: fix.provenance.simulated)
                }
                integrity = VizIntegrity(status: record.status, trustScore: record.trustScore,
                                         trustLower: record.uncertainty.lower, reasons: reasons, evidence: evidence,
                                         evaluatedFix: fix, minimumDetectableOffset: record.minimumDetectableOffsetMeters,
                                         summary: record.summary, simulated: record.provenance.simulated)
            }

            var prediction: VizPrediction?
            if let record = predictionRecord {
                let rx = input.predictionReceivedAt[id] ?? record.timestamp
                let sinceObserved = record.horizon + record.freshness.age(receivedAt: rx, now: now)
                prediction = VizPrediction(lastObservedAt: date(age: sinceObserved), horizon: sinceObserved,
                                           center: floor(record.center), r95: record.uncertainty.r95,
                                           cloud: (record.cloud ?? []).map { FloorPoint(x: $0.x, z: $0.z) },
                                           method: record.method.rawValue, simulated: record.provenance.simulated)
            }

            // A phone with a fresh prediction and no live position is shown predicted.
            let livePosition = position.flatMap { [.measured, .estimated, .declared].contains($0.kind) ? $0 : nil }
            let kind: VizKind, method: VizMethod, point: FloorPoint?, r95: Double?, observedAt: Date?
            if let p = livePosition {
                (kind, method) = (p.kind, p.method)
                point = p.position.map(floor)
                r95 = p.uncertainty.r95
                observedAt = date(age: p.freshness.age(receivedAt: input.positionReceivedAt[id] ?? p.timestamp, now: now))
            } else if let prediction {
                (kind, method, point, r95, observedAt) = (.predicted, .prediction, prediction.center, prediction.r95,
                                                          prediction.lastObservedAt)
            } else if let p = position, p.kind == .predicted, let at = p.position {
                // A predicted position without its Prediction record (e.g. relayed from another phone).
                let rx = input.positionReceivedAt[id] ?? p.timestamp
                let since = (p.lastAbsoluteAt.map { p.timestamp - $0 } ?? 0) + p.freshness.age(receivedAt: rx, now: now)
                prediction = VizPrediction(lastObservedAt: date(age: since), horizon: since, center: floor(at),
                                           r95: p.uncertainty.r95, cloud: [], method: p.provenance.algorithm,
                                           simulated: p.provenance.simulated)
                (kind, method, point, r95, observedAt) = (.predicted, .prediction, floor(at), p.uncertainty.r95, date(age: since))
            } else {
                (kind, method, point, r95, observedAt) = (.unavailable, .none, nil, nil, nil)
            }

            let provenance = livePosition?.provenance ?? predictionRecord?.provenance ?? position?.provenance
            let inputs = (provenance?.inputs ?? []).enumerated().map { i, item in
                VizInput(index: i, source: item.source.rawValue, deviceId: item.id, age: item.age, used: item.used, reason: item.reason)
            }
            let rawFix = input.rawFixes[id].flatMap { fix -> VizRawFix? in
                guard let p = fix.position else { return nil }
                let age = fix.freshness.age(receivedAt: input.positionReceivedAt[id] ?? fix.timestamp, now: now)
                return VizRawFix(point: floor(p), claimedR95: fix.uncertainty.r95, observedAt: date(age: age),
                                 simulated: fix.provenance.simulated)
            }
            let isSelf = id == input.selfId
            scene.phones.append(VizPhone(
                id: id, label: isSelf ? "You" : (input.labels[id] ?? shortID(id)), isSelf: isSelf, kind: kind, method: method,
                point: point, r95: r95, ambiguous: livePosition?.uncertainty.ambiguous ?? false,
                candidates: (livePosition?.candidates ?? []).map { FloorPoint(x: $0.x, z: $0.z) }, cloud: [],
                observedAt: observedAt, hops: nil, integrity: integrity, rawFix: rawFix, prediction: prediction, inputs: inputs,
                simulated: provenance?.simulated ?? false))
        }
        scene.phones.sort { ($0.isSelf ? 0 : 1, $0.label) < ($1.isSelf ? 0 : 1, $1.label) }

        // One line per pair of phones that hear each other, at the mean RSSI either end reports.
        var pairs: [String: (a: String, b: String, sum: Double, count: Int)] = [:]
        for observation in input.observations where observation.linkState != .lost {
            guard let peer = observation.peerId, peer != observation.observerId else { continue }
            let samples = observation.rawRSSI
            guard let rssi = observation.smoothedRSSI ?? (samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)) else { continue }
            let (a, b) = observation.observerId < peer ? (observation.observerId, peer) : (peer, observation.observerId)
            var pair = pairs[a + "\n" + b] ?? (a, b, 0, 0)
            pair.sum += rssi
            pair.count += 1
            pairs[a + "\n" + b] = pair
        }
        scene.links = input.links ?? pairs.keys.sorted().compactMap { key in
            pairs[key].map { VizLink(a: $0.a, b: $0.b, rssi: $0.sum / Double($0.count)) }
        }
        scene.routes = input.routes.keys.sorted().compactMap { origin in
            guard origin != input.selfId, let relays = input.routes[origin] else { return nil }
            return VizRoute(origin: origin, relays: relays)
        }
        return scene
    }
}

// MARK: - Feed from today's pipeline (until GhostCoreHub lands)

extension VizScene {
    /// Built from the tracker (GPS, typed spots, Bluetooth estimates, last-seen), the movement
    /// predictor and the mesh's relay paths. There is no integrity engine on this path, so GPS stays
    /// not checked and nothing is marked trusted.
    @MainActor
    static func legacy(model: MeshModel, tracker: BluetoothTracker, predictor: MovementPredictor,
                       location: LocationSource, now: Date = Date()) -> VizScene {
        var scene = VizScene(now: now, frameId: model.frameID, selfId: model.deviceID)
        let simulatedLoss = model.simulateGPSLoss
        for phone in tracker.phones {
            let kind: VizKind, method: VizMethod
            switch phone.state {
            case .placed(.gps): (kind, method) = (.measured, .gnss)
            case .placed: (kind, method) = (.declared, .manual)
            case .estimated: (kind, method) = (.estimated, .particle)
            case .lastSeen: (kind, method) = (.predicted, .prediction)
            case .unplaced: (kind, method) = (.unavailable, .none)
            }
            var prediction: VizPrediction?
            if phone.state == .lastSeen, let point = phone.point {
                if let cloud = predictor.clouds[phone.id] {
                    prediction = VizPrediction(lastObservedAt: phone.since, horizon: cloud.horizon, center: cloud.center,
                                               r95: nil, cloud: cloud.points, method: "movementModel", simulated: false)
                } else {
                    prediction = VizPrediction(lastObservedAt: phone.since, horizon: now.timeIntervalSince(phone.since),
                                               center: point, r95: phone.radius, cloud: [], method: "walkingSpeed", simulated: false)
                }
            }
            // This phone's raw fix is real; there is no trust verdict on this path.
            var rawFix: VizRawFix?
            if phone.isSelf, let fix = location.latest, fix.horizontalAccuracy >= 0,
               let p = GeoFrame.position(frameId: model.frameID, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude) {
                rawFix = VizRawFix(point: FloorPoint(x: p.x, z: p.z),
                                   claimedR95: PositionUncertainty.r95(fromRadius68: fix.horizontalAccuracy),
                                   observedAt: fix.timestamp, simulated: false)
            }
            scene.phones.append(VizPhone(
                id: phone.id, label: phone.isSelf ? "You" : phone.label, isSelf: phone.isSelf, kind: kind, method: method,
                point: phone.point, r95: phone.radius,
                ambiguous: phone.ambiguous, candidates: [], cloud: phone.state == .estimated ? Array(phone.cloud.prefix(60)) : [],
                observedAt: phone.since, hops: phone.hops, integrity: nil, rawFix: rawFix, prediction: prediction, inputs: [],
                simulated: phone.isSelf && simulatedLoss))
        }
        scene.links = tracker.links.map { VizLink(a: $0.a, b: $0.b, rssi: $0.rssi) }
        scene.routes = model.devices.compactMap { device in
            guard let path = device.path, device.id != model.deviceID else { return nil }
            return VizRoute(origin: device.id, relays: path)
        }
        if simulatedLoss {
            scene.scenario = VizScenarioState(name: "GPS off (this phone)", elapsed: 0, stepIndex: 0,
                                              caption: "This phone ignores its GPS and asks peers to place it", isRunning: true)
        }
        return scene
    }
}
