import Foundation
import MeshCore

/// Keeps each phone's recent track and, when Bluetooth loses a phone, predicts where it has
/// probably walked since, with two on-device models trained on walking tracks around Hervanta:
/// - the movement model (v2): a cloud that grows with time, instead of a dot frozen at the last spot;
/// - the route model (v3, walks the bundled path graph): 2-4 routes with percentages ("65 % straight
///   on at the fork in 240 m") and where along each one they probably are by now.
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

    struct RouteOption: Identifiable {
        /// Rank, 0 = most likely.
        let id: Int
        let probability: Double
        let text: String
        let line: [FloorPoint]
        /// Where along this route they probably are by now (median), and the 10-90 % stretch.
        let here: FloorPoint?
        let band: [FloorPoint]
    }

    struct Routes {
        let options: [RouteOption]
        /// Chance they left the paths altogether.
        let offPath: Double
    }

    /// Seconds of track kept per phone; the models read the last 60 s.
    static let trackSeconds: Double = 120
    static let cloudPoints = 80
    static let maxRoutes = 4
    /// Whether the model also reads the map patch around the person. Off: on held-out Hervanta the
    /// map made the cloud sharper (37 m vs 43 m median error at 1 min, mesh history) but too tight,
    /// holding its 90% area only 77-85% of the time against 83-88% without it (ml/README.md).
    /// The map is still used to convert positions; the route model is where the paths count.
    static let readsMap = false

    @Published private(set) var clouds: [String: Cloud] = [:]
    @Published private(set) var routes: [String: Routes] = [:]
    private let model: MovementModel?
    /// The map the movement model reads (ml/export/maps/hervanta), in its own metre frame.
    private let map: MovementModel.MapLayer?
    /// Loaded in the background: the path graph is 4 MB.
    private var routeModel: RouteModel?
    private var tracks: [String: [(t: Double, point: FloorPoint)]] = [:]
    private var lastPlaced: [String: (t: Double, accuracy: Double)] = [:]
    /// The horizon-independent parts, made once per dropout.
    private var prepared: [String: (placedAt: Double, value: MovementModel.Prepared)] = [:]
    private var routePredictions: [String: (placedAt: Double, value: RouteModel.Prediction)] = [:]

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
        // Reading the graph takes a few hundred milliseconds on a phone: keep it off the main thread.
        Task.detached(priority: .utility) { [weak self] in
            guard let tables = Bundle.main.url(forResource: "route-model", withExtension: "json").flatMap({ try? Data(contentsOf: $0) }),
                  let graph = Bundle.main.url(forResource: "hervanta-graph", withExtension: "json").flatMap({ try? Data(contentsOf: $0) }),
                  let loaded = try? RouteModel(model: tables, graph: graph) else { return }
            await MainActor.run { self?.routeModel = loaded }
        }
    }

    var isAvailable: Bool { model != nil }

    func reset() {
        tracks = [:]
        lastPlaced = [:]
        prepared = [:]
        routePredictions = [:]
        clouds = [:]
        routes = [:]
    }

    /// `frameId` is the shared frame of the tracker's points; the map and the path graph are only
    /// used when that frame has a GPS origin, since points are converted through latitude and longitude.
    func update(phones: [TrackedPhone], frameId: String, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        let anchored = GeoFrame.origins[frameId] != nil
        let map = anchored ? self.map : nil
        var newClouds: [String: Cloud] = [:]
        var newRoutes: [String: Routes] = [:]
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
                routePredictions[phone.id] = nil
            case .lastSeen:
                guard let track = tracks[phone.id], !track.isEmpty, let placed = lastPlaced[phone.id] else { continue }
                let horizon = t - placed.t
                if let model {
                    newClouds[phone.id] = cloud(for: phone.id, model: model, map: map, track: track, placed: placed,
                                                horizon: horizon, frameId: frameId)
                }
                if anchored, let routeModel,
                   let found = routeOptions(for: phone.id, routeModel: routeModel, track: track, placed: placed,
                                            horizon: horizon, frameId: frameId) {
                    newRoutes[phone.id] = found
                }
            case .unplaced:
                continue
            }
        }
        clouds = newClouds
        routes = newRoutes
    }

    private func cloud(for id: String, model: MovementModel, map: MovementModel.MapLayer?,
                       track: [(t: Double, point: FloorPoint)], placed: (t: Double, accuracy: Double),
                       horizon: Double, frameId: String) -> Cloud {
        let ready: MovementModel.Prepared
        if let cached = prepared[id], cached.placedAt == placed.t {
            ready = cached.value
        } else {
            let modelTrack = track.map { MovementModel.TrackPoint(t: $0.t, point: toModel($0.point, frameId, map)) }
            let history = model.history(track: modelTrack, now: placed.t)
            ready = model.prepare(history: history, accuracy: placed.accuracy, map: Self.readsMap ? map : nil)
            prepared[id] = (placed.t, ready)
        }
        let prediction = model.predict(prepared: ready, horizon: horizon)
        // Same seed every second, so the dots drift as the cloud grows instead of flickering.
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: id.hashValue))
        let points = prediction.sample(Self.cloudPoints, using: &rng).map { fromModel($0, frameId, map) }
        var cx = 0.0, cy = 0.0
        for (w, m) in zip(prediction.weights, prediction.means) { cx += w * m.x; cy += w * m.y }
        return Cloud(id: id, center: fromModel(MovementModel.Point(cx, cy), frameId, map), points: points, horizon: horizon)
    }

    private func routeOptions(for id: String, routeModel: RouteModel, track: [(t: Double, point: FloorPoint)],
                              placed: (t: Double, accuracy: Double), horizon: Double, frameId: String) -> Routes? {
        let prediction: RouteModel.Prediction
        if let cached = routePredictions[id], cached.placedAt == placed.t {
            prediction = cached.value
        } else {
            let graphTrack = track.compactMap { sample -> MovementModel.TrackPoint? in
                guard let c = GeoFrame.coordinate(frameId: frameId, x: sample.point.x, z: sample.point.z) else { return nil }
                return MovementModel.TrackPoint(t: sample.t, point: routeModel.toXY(lat: c.latitude, lon: c.longitude))
            }
            guard !graphTrack.isEmpty else { return nil }
            prediction = routeModel.predict(track: graphTrack, now: placed.t, accuracy: placed.accuracy)
            routePredictions[id] = (placed.t, prediction)
        }
        func floor(_ p: RouteModel.Point) -> FloorPoint? {
            let c = routeModel.toLatLon(p)
            return GeoFrame.position(frameId: frameId, latitude: c.lat, longitude: c.lon).map { FloorPoint(x: $0.x, z: $0.z) }
        }
        let markers = routeModel.whereAlong(prediction, seconds: horizon)
        let options = zip(prediction.routes, markers).prefix(Self.maxRoutes).enumerated().map { rank, pair in
            RouteOption(id: rank, probability: pair.0.p, text: pair.0.text, line: pair.0.line.compactMap(floor),
                        here: floor(pair.1.point), band: pair.1.band.compactMap(floor))
        }
        return options.isEmpty ? nil : Routes(options: options, offPath: prediction.offPath)
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
