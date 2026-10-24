import CoreLocation
import Foundation
import MeshCore

// What the GhostCore map draws, one snapshot per second. The names follow the GhostCore contract
// (PositionEstimate.kind/method, uncertainty.r95, IntegrityAssessment.status/reasons/evidence,
// Prediction) so this file is the only place that knows where the data comes from. Nothing here
// invents a value: a field the pipeline did not provide stays nil and the UI says so.

enum VizKind: String {
    case measured, estimated, predicted, declared, unavailable
}

enum VizMethod: String {
    case gnss, uwb, multilateration, proximity, particle, deadReckoning, fusion, manual, none

    var title: String {
        switch self {
        case .gnss: return "GPS"
        case .uwb: return "UWB"
        case .multilateration: return "multilateration"
        case .proximity: return "proximity"
        case .particle: return "Bluetooth particle filter"
        case .deadReckoning: return "dead reckoning"
        case .fusion: return "fusion"
        case .manual: return "typed spot"
        case .none: return "none"
        }
    }
}

enum VizIntegrityStatus: String {
    case trusted, degraded, suspect, rejected, unavailable, insufficientEvidence
}

struct VizEvidence: Identifiable {
    let check: String
    let observed: Double?
    let threshold: Double?
    let unit: String
    /// 0 (fails) ... 1 (passes).
    let score: Double
    var id: String { check }
}

struct VizReason: Identifiable {
    let code: String
    /// One plain sentence, e.g. "jumped 390 m in 1 s (limit 12 m/s)". Never "spoofing detected".
    let text: String
    var id: String { code }

    /// A sentence from a reason code and its check's numbers, for when the engine sends only codes.
    /// It states what was measured against what is physically possible; it never names an attacker.
    static func sentence(code: String, evidence: VizEvidence?) -> String {
        func n(_ v: Double?) -> String {
            guard let v else { return "?" }
            return v >= 100 ? "\(Int(v.rounded()))" : String(format: v >= 10 ? "%.0f" : "%.1f", v)
        }
        let o = n(evidence?.observed), t = n(evidence?.threshold)
        let limit = evidence?.threshold == nil ? "" : " (limit \(t)\(evidence.map { $0.unit.isEmpty ? "" : " \($0.unit)" } ?? ""))"
        switch code {
        case "positionJump": return "GPS jumped \(o) m in one step\(limit)"
        case "impossibleSpeed": return "GPS implies \(o) m/s, faster than a person moves\(limit)"
        case "inertialDisagreement": return "GPS moved \(o) m that the motion sensors did not feel\(limit)"
        case "peerDisagreement": return "GPS is \(o) m from where nearby phones place it\(limit)"
        case "slowDrift": return "GPS is drifting away from the motion estimate at \(o) m/s\(limit)"
        case "staleFix": return "Last GPS fix is \(o) s old\(limit)"
        case "poorAccuracy", "claimedAccuracy": return "GPS claims only ±\(o) m\(limit)"
        default:
            let words = code.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// The raw GNSS fix the integrity checks judged, in the shared frame.
struct VizRawFix {
    let point: FloorPoint
    /// r95 derived from the receiver's claimed accuracy.
    let claimedR95: Double
    let observedAt: Date
    let simulated: Bool
}

struct VizIntegrity {
    let status: VizIntegrityStatus
    let trustScore: Double?
    let reasons: [VizReason]
    let evidence: [VizEvidence]
    let evaluatedFix: VizRawFix?
    let simulated: Bool
}

struct VizPrediction {
    let lastObservedAt: Date
    let horizon: TimeInterval
    let center: FloorPoint
    let r95: Double?
    let cloud: [FloorPoint]
    let simulated: Bool
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
    let prediction: VizPrediction?
    let simulated: Bool

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
    /// True when the integrity engine is wired in; without it GPS is shown as unchecked, never "trusted".
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
            switch phone.integrity?.status {
            case .trusted?: return .init(title: "\(method) trusted", detail: r95, tint: .confirmed, live: true)
            case .degraded?, .suspect?:
                return .init(title: "\(method) in doubt", detail: phone.integrity?.reasons.first?.text ?? r95,
                             tint: .suspect, live: true)
            case .insufficientEvidence?:
                return .init(title: "\(method) checking…", detail: r95, tint: .suspect, live: true)
            case .rejected?:
                return .init(title: "\(method) rejected", detail: phone.integrity?.reasons.first?.text, tint: .rejected, live: true)
            case .unavailable?, nil:
                // No verdict: never drawn as trusted.
                return .init(title: "\(method) unchecked", detail: r95, tint: .unchecked, live: true)
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
            return .init(title: "No position", detail: "needs GPS or a placed peer", tint: .unknown, live: false)
        }
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 90 ? "\(s) s" : "\(s / 60) min"
    }

    static func hopText(_ hops: Int) -> String { "\(hops) hop\(hops == 1 ? "" : "s") from GPS" }
}

// MARK: - Feed from today's pipeline (until GhostCoreHub lands)

extension VizScene {
    /// Built from the tracker (GPS, typed spots, Bluetooth estimates, last-seen), the movement
    /// predictor and the mesh's relay paths. There is no integrity engine on this path, so GPS stays
    /// unchecked and nothing is marked trusted.
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
            case .lastSeen: (kind, method) = (.predicted, predictor.clouds[phone.id] == nil ? .none : .deadReckoning)
            case .unplaced: (kind, method) = (.unavailable, .none)
            }
            var prediction: VizPrediction?
            if phone.state == .lastSeen, let point = phone.point {
                if let cloud = predictor.clouds[phone.id] {
                    prediction = VizPrediction(lastObservedAt: phone.since, horizon: cloud.horizon, center: cloud.center,
                                                 r95: nil, cloud: cloud.points, simulated: false)
                } else {
                    prediction = VizPrediction(lastObservedAt: phone.since, horizon: now.timeIntervalSince(phone.since),
                                                 center: point, r95: phone.radius, cloud: [], simulated: false)
                }
            }
            var integrity: VizIntegrity?
            if phone.isSelf, let fix = location.latest, fix.horizontalAccuracy >= 0,
               let p = GeoFrame.position(frameId: model.frameID, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude) {
                // The raw fix is real; there is no verdict on this path. Claimed accuracy is ~68%
                // (1.51 sigma in 2D); r95 is 2.45 sigma.
                integrity = VizIntegrity(
                    status: .unavailable, trustScore: nil, reasons: [], evidence: [],
                    evaluatedFix: VizRawFix(point: FloorPoint(x: p.x, z: p.z), claimedR95: fix.horizontalAccuracy * 2.45 / 1.51,
                                              observedAt: fix.timestamp, simulated: false),
                    simulated: false)
            }
            scene.phones.append(VizPhone(
                id: phone.id, label: phone.isSelf ? "You" : phone.label, isSelf: phone.isSelf, kind: kind, method: method,
                point: phone.point, r95: phone.radius,
                ambiguous: phone.ambiguous, candidates: [], cloud: phone.state == .estimated ? Array(phone.cloud.prefix(60)) : [],
                observedAt: phone.since, hops: phone.hops, integrity: integrity, prediction: prediction,
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
