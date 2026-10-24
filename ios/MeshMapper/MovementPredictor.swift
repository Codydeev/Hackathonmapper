import Foundation
import MeshCore

/// Keeps each phone's recent track and, when Bluetooth loses a phone, predicts where it has
/// probably walked since with the on-device movement model (v2, trained on walking tracks from
/// Finnish forests). The result is a cloud that grows with time, instead of a dot frozen at the
/// last spot.
@MainActor
final class MovementPredictor: ObservableObject {
    struct Cloud: Identifiable {
        let id: String
        /// Most likely spot (weighted mean of the mixture).
        let center: FloorPoint
        let points: [FloorPoint]
        /// Seconds since the phone was last placed.
        let horizon: Double
    }

    /// Seconds of track kept per phone; the model reads the last 60 s.
    static let trackSeconds: Double = 120
    static let cloudPoints = 80
    /// Whether the model also reads the map patch around the person. Off: on held-out Hervanta the
    /// map made the cloud sharper (37 m vs 43 m median error at 1 min, mesh history) but too tight,
    /// holding its 90% area only 77-85% of the time against 83-88% without it (ml/README.md).
    /// The map is still used to convert positions; the route model is where the paths count.
    static let readsMap = false

    @Published private(set) var clouds: [String: Cloud] = [:]
    private let model: MovementModel?
    /// The map the model reads (ml/export/maps/hervanta), in its own metre frame.
    private let map: MovementModel.MapLayer?
    private var tracks: [String: [(t: Double, point: FloorPoint)]] = [:]
    private var lastPlaced: [String: (t: Double, accuracy: Double)] = [:]
    /// The horizon-independent part of the prediction, made once per dropout.
    private var prepared: [String: (placedAt: Double, value: MovementModel.Prepared)] = [:]

    init() {
        func resource(_ name: String, _ ext: String) -> Data? {
            Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) }
        }
        let model = resource("movement-model-v2", "json").flatMap { try? MovementModel(json: $0) }
        self.model = model
        // Without the map the v2 model still runs; it was trained to know when the map is missing.
        if model?.usesMap == true, let png = resource("hervanta-map", "png"), let meta = resource("hervanta-map", "json") {
            map = try? MovementModel.MapLayer(png: png, meta: meta)
        } else {
            map = nil
        }
    }

    var isAvailable: Bool { model != nil }

    func reset() {
        tracks = [:]
        lastPlaced = [:]
        prepared = [:]
        clouds = [:]
    }

    /// `frameId` is the shared frame of the tracker's points; the map is only used when that frame
    /// has a GPS origin, since both are converted through latitude and longitude.
    func update(phones: [TrackedPhone], frameId: String, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        let map = GeoFrame.origins[frameId] == nil ? nil : self.map
        var result: [String: Cloud] = [:]
        for phone in phones {
            switch phone.state {
            case .placed, .estimated:
                guard let point = phone.point else { continue }
                var track = tracks[phone.id] ?? []
                track.append((t, point))
                track.removeAll { t - $0.t > Self.trackSeconds }
                tracks[phone.id] = track
                lastPlaced[phone.id] = (t, min(max(phone.radius ?? 5, 3), 30))
                prepared[phone.id] = nil
            case .lastSeen:
                guard let model, let track = tracks[phone.id], !track.isEmpty,
                      let placed = lastPlaced[phone.id] else { continue }
                let ready: MovementModel.Prepared
                if let cached = prepared[phone.id], cached.placedAt == placed.t {
                    ready = cached.value
                } else {
                    let modelTrack = track.map { MovementModel.TrackPoint(t: $0.t, point: toModel($0.point, frameId, map)) }
                    let history = model.history(track: modelTrack, now: placed.t)
                    ready = model.prepare(history: history, accuracy: placed.accuracy, map: Self.readsMap ? map : nil)
                    prepared[phone.id] = (placed.t, ready)
                }
                let horizon = t - placed.t
                let prediction = model.predict(prepared: ready, horizon: horizon)
                // Same seed every second, so the dots drift as the cloud grows instead of flickering.
                var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: phone.id.hashValue))
                let points = prediction.sample(Self.cloudPoints, using: &rng).map { fromModel($0, frameId, map) }
                var cx = 0.0, cy = 0.0
                for (w, m) in zip(prediction.weights, prediction.means) { cx += w * m.x; cy += w * m.y }
                result[phone.id] = Cloud(id: phone.id, center: fromModel(MovementModel.Point(cx, cy), frameId, map),
                                         points: points, horizon: horizon)
            case .unplaced:
                continue
            }
        }
        clouds = result
    }

    /// Tracker frame (x east, z north) to the map's frame (x east, y north), through GPS coordinates.
    /// Without a map the model only needs relative positions, so the point is used as it is.
    private func toModel(_ p: FloorPoint, _ frameId: String, _ map: MovementModel.MapLayer?) -> MovementModel.Point {
        guard let map, let c = GeoFrame.coordinate(frameId: frameId, x: p.x, z: p.z) else { return MovementModel.Point(p.x, p.z) }
        return map.toXY(lat: c.latitude, lon: c.longitude)
    }

    private func fromModel(_ p: MovementModel.Point, _ frameId: String, _ map: MovementModel.MapLayer?) -> FloorPoint {
        guard let map else { return FloorPoint(x: p.x, z: p.y) }
        let c = map.toLatLon(p)
        guard let q = GeoFrame.position(frameId: frameId, latitude: c.lat, longitude: c.lon) else { return FloorPoint(x: p.x, z: p.y) }
        return FloorPoint(x: q.x, z: q.z)
    }
}

private extension MovementModel.TrackPoint {
    init(t: Double, point: MovementModel.Point) { self.init(t: t, x: point.x, y: point.y) }
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
