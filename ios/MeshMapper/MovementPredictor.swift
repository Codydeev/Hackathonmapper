import Foundation
import MeshCore

/// Keeps each phone's recent track and, when Bluetooth loses a phone, predicts where it has
/// probably walked since with the on-device movement model (movement-model.json, trained on
/// walking tracks around Hervanta). The result is a cloud that grows with time, instead of a dot
/// frozen at the last spot. It takes over only after `takeOverAfter` seconds lost, so a link that
/// drops for a moment does not throw the phone onto a prediction.
@MainActor
final class MovementPredictor: ObservableObject {
    struct Cloud: Identifiable {
        let id: String
        /// Most likely spot (weighted mean of the mixture).
        let center: FloorPoint
        let points: [FloorPoint]
        /// Radius around `center` holding 95 % of `points`: the one circle the map draws.
        let radius: Double
        /// Seconds since the phone was last placed.
        let horizon: Double
    }

    /// Seconds of track kept per phone; the model reads the last 60 s.
    static let trackSeconds: Double = 120
    static let cloudPoints = 80
    /// Seconds a phone must be lost before the prediction replaces its last spot.
    static let takeOverAfter: Double = 5

    @Published private(set) var clouds: [String: Cloud] = [:]
    private let model: MovementModel?
    private var tracks: [String: [MovementModel.TrackPoint]] = [:]
    private var lastPlaced: [String: (t: Double, accuracy: Double)] = [:]

    init() {
        model = Bundle.main.url(forResource: "movement-model", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? MovementModel(json: $0) }
    }

    var isAvailable: Bool { model != nil }

    func reset() {
        tracks = [:]
        lastPlaced = [:]
        clouds = [:]
    }

    func update(phones: [TrackedPhone], now: Date = Date()) {
        let t = now.timeIntervalSince1970
        var result: [String: Cloud] = [:]
        for phone in phones {
            switch phone.state {
            case .placed, .estimated:
                // A ring's centre is its neighbour, not this phone: no track point.
                guard let point = phone.point, !phone.directionUnresolved else { continue }
                var track = tracks[phone.id] ?? []
                track.append(MovementModel.TrackPoint(t: t, x: point.x, y: point.z))
                track.removeAll { t - $0.t > Self.trackSeconds }
                tracks[phone.id] = track
                lastPlaced[phone.id] = (t, min(max(phone.radius ?? 5, 3), 30))
            case .lastSeen:
                guard let model, let track = tracks[phone.id], !track.isEmpty,
                      let placed = lastPlaced[phone.id] else { continue }
                let horizon = t - placed.t
                guard horizon >= Self.takeOverAfter else { continue }
                let history = model.history(track: track, now: placed.t)
                let prediction = model.predict(history: history, accuracy: placed.accuracy, horizon: horizon)
                // Same seed every second, so the dots drift as the cloud grows instead of flickering.
                var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: phone.id.hashValue))
                let points = prediction.sample(Self.cloudPoints, using: &rng).map { FloorPoint(x: $0.x, z: $0.y) }
                var cx = 0.0, cz = 0.0
                for (w, m) in zip(prediction.weights, prediction.means) { cx += w * m.x; cz += w * m.y }
                let center = FloorPoint(x: cx, z: cz)
                result[phone.id] = Cloud(id: phone.id, center: center, points: points,
                                         radius: Self.radius95(points, around: center), horizon: horizon)
            case .unplaced:
                continue
            }
        }
        clouds = result
    }

    /// Distance from `center` within which 95 % of `points` lie.
    static func radius95(_ points: [FloorPoint], around center: FloorPoint) -> Double {
        let distances = points.map { hypot($0.x - center.x, $0.z - center.z) }.sorted()
        guard !distances.isEmpty else { return 0 }
        return distances[min(distances.count - 1, Int(Double(distances.count) * 0.95))]
    }
}

/// Small deterministic generator for stable cloud dots.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
