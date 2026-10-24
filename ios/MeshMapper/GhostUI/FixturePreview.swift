#if DEBUG
import Foundation
import MeshCore

/// Development only: draws the contract's golden records (contract/fixtures) through
/// `VizScene.contract`, to check the map on the simulator without phones. Reachable only with the
/// launch argument `-GhostFixturePreview estimate|predicted`, compiled out of Release (TestFlight)
/// builds, and the map shows a FIXTURE banner the whole time. It never feeds the pipeline.
enum FixturePreview {
    static let stage: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GhostFixturePreview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// `-GhostFixtureOpen <phone id>|simulation`: opens that phone's explainer or the simulation
    /// panel at launch, for screenshots.
    static let open: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GhostFixtureOpen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// The section 1 story from the fixtures: A trusted GNSS, B placed over Bluetooth ("estimate") or
    /// predicted ("predicted"), C's raw GNSS rejected for a 412 m jump.
    static func scene(stage: String) -> VizScene? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../contract/fixtures").standardized
        func load<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name + ".json")) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let trusted = load("integrity-trusted", IntegrityAssessment.self),
              let rejected = load("integrity-rejected-jump", IntegrityAssessment.self),
              let bluetooth = load("position-ble-ambiguous", PositionEstimate.self),
              let prediction = load("prediction-kalman", Prediction.self),
              let observation = load("peer-observation", PeerObservation.self) else { return nil }

        let now = [trusted.timestamp, rejected.timestamp, bluetooth.timestamp, prediction.timestamp].max()! + 2
        var input = VizContractInputs(selfId: "phone-a", frameId: GeoFrame.defaultFrameId, now: now)
        input.labels = ["phone-a": "Otter 42", "phone-b": "Lynx 17", "phone-c": "Pike 31"]
        input.integrity = ["phone-a": trusted, "phone-c": rejected]
        if let fix = trusted.evaluatedFix { input.positions["phone-a"] = fix }
        input.rawFixes = ["phone-a": trusted.evaluatedFix, "phone-c": rejected.evaluatedFix].compactMapValues { $0 }
        switch stage {
        case "predicted":
            input.predictions["phone-b"] = prediction
            // The fixture's last spot is inside Tietotalo, where the route model (correctly) finds no
            // path; the made-up walk ends on the path north of it instead.
            if let paths = likelyPaths(walkingInto: FloorPoint(x: 0, z: 60), horizon: now - prediction.lastObservedAt) {
                input.likelyPaths["phone-b"] = paths
            }
        default:
            input.positions["phone-b"] = bluetooth
            input.observations = [observation]
        }
        return VizScene.contract(input)
    }

    private static var routeModel: RouteModel? = {
        func resource(_ name: String) -> Data? {
            Bundle.main.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        }
        guard let tables = resource("route-model"), let graph = resource("hervanta-graph") else { return nil }
        return try? RouteModel(model: tables, graph: graph)
    }()
    private static var pathsCache: [String: VizLikelyPaths] = [:]

    /// The real route model run on a made-up 60 s walk north at 1.3 m/s into `last`, the fixture's
    /// last observed spot. Only the input track is invented; the routes are the model's output.
    static func likelyPaths(walkingInto last: FloorPoint, horizon: Double) -> VizLikelyPaths? {
        let key = "\(last.x),\(last.z),\(Int(horizon))"
        if let cached = pathsCache[key] { return cached }
        guard let model = routeModel else { return nil }
        let frame = GeoFrame.defaultFrameId
        let track = (0...60).compactMap { i -> MovementModel.TrackPoint? in
            guard let c = GeoFrame.coordinate(frameId: frame, x: last.x, z: last.z - 1.3 * Double(60 - i)) else { return nil }
            let p = model.toXY(lat: c.latitude, lon: c.longitude)
            return MovementModel.TrackPoint(t: Double(i), x: p.x, y: p.y)
        }
        let prediction = model.predict(track: track, now: 60, accuracy: 8)
        func floor(_ p: RouteModel.Point) -> FloorPoint? {
            let c = model.toLatLon(p)
            return GeoFrame.position(frameId: frame, latitude: c.lat, longitude: c.lon).map { FloorPoint(x: $0.x, z: $0.z) }
        }
        let options = zip(prediction.routes, model.whereAlong(prediction, seconds: horizon)).prefix(4).enumerated().map { rank, pair in
            VizLikelyPath(rank: rank, probability: pair.0.p, text: pair.0.text, line: pair.0.line.compactMap(floor),
                          here: floor(pair.1.point), band: pair.1.band.compactMap(floor))
        }
        let paths = options.isEmpty ? nil : VizLikelyPaths(options: options, offPath: prediction.offPath)
        pathsCache[key] = paths
        return paths
    }
}

import SwiftUI

/// Red banner over the map while fixtures are shown.
struct FixtureBanner: View {
    var body: some View {
        Text("FIXTURE PREVIEW · NOT LIVE · DEBUG BUILD")
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(GhostTheme.rejected, in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif
