import Foundation

/// Which measured distances a signal map uses: both (UWB where a pair measured it, RSSI otherwise),
/// or one kind only, so the approaches can be compared on the phones.
public enum SignalRanges: String, Codable, CaseIterable, Identifiable {
    case all, bluetoothOnly, uwbOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "UWB + BT"
        case .bluetoothOnly: return "BT only"
        case .uwbOnly: return "UWB only"
        }
    }

    /// The links this choice keeps: Bluetooth only drops their UWB distances, UWB only drops links without one.
    public func apply(_ links: [LinkMeasurement]) -> [LinkMeasurement] {
        switch self {
        case .all: return links
        case .bluetoothOnly: return links.map { LinkMeasurement(a: $0.a, b: $0.b, rssi: $0.rssi) }
        case .uwbOnly: return links.filter { $0.uwb != nil }
        }
    }
}

/// The engine in GhostCore's positioning slot, which places other phones on the main map.
public enum PeerPlacement: String, Codable, CaseIterable, Identifiable {
    /// The signal map, as on the dashboard and the Track tab (`SignalMapPositioning`).
    case signalMap
    /// GhostCore's per-phone engine (`Positioning.PeerLocator`), RSSI only.
    case peerLocator
    /// Build 7's particle filter (`EstimatorPositioning`), RSSI only.
    case particleFilter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .signalMap: return "Signal map"
        case .peerLocator: return "Peer locator"
        case .particleFilter: return "Particle filter"
        }
    }
}

/// What the main map shows for a phone that went silent.
public enum PredictionMode: String, Codable, CaseIterable, Identifiable {
    /// GhostCore's movement-model prediction (`GhostPredictor`).
    case model
    /// The last spot with a circle growing at walking pace (`WalkingCirclePrediction`).
    case walkingCircle
    /// Nothing: a silent phone just ages out.
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .model: return "Model"
        case .walkingCircle: return "Circle"
        case .off: return "Off"
        }
    }
}

/// Runtime switches for the app's features, so the team can try combinations on the phones without
/// a new build. Stored as JSON; a key missing from (or unknown to) a stored copy takes its default, so
/// settings saved by another build always load.
public struct FeatureFlags: Codable, Equatable {
    // Sensors
    /// Accelerometer and gyroscope: GhostCore's dead reckoning (and the GPS check's independent
    /// evidence), and the steps of fused tracking.
    public var motion = true
    /// Magnetometer heading for GhostCore's dead reckoning.
    public var compass = true

    // Placement of other phones
    public var peerPlacement = PeerPlacement.signalMap
    /// Which distances the main map's signal map uses.
    public var mainMapRanges = SignalRanges.all
    /// The signal map fits its radio model live from UWB distances and placed phones (main map and
    /// Track tab); off keeps the default model.
    public var calibrateRadio = true

    // Lost phones
    public var prediction = PredictionMode.model
    /// The route model's likely paths, with percentages, for a phone that went silent.
    public var likelyPaths = true

    // Mesh
    /// Publish and upload within 0.2 s of a move; off, once a second (less Bluetooth load and battery).
    public var fastUpdates = true
    /// Send this phone's GPS check (integrity) records over the mesh (frame 7).
    public var relayIntegrity = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case motion, compass, peerPlacement, mainMapRanges, calibrateRadio, prediction, likelyPaths, fastUpdates, relayIntegrity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FeatureFlags()
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            // A missing key gives nil; a wrong type or an unknown case throws, so try? gives nil too.
            (try? c.decodeIfPresent(type, forKey: key)) ?? fallback
        }
        motion = value(Bool.self, .motion, defaults.motion)
        compass = value(Bool.self, .compass, defaults.compass)
        peerPlacement = value(PeerPlacement.self, .peerPlacement, defaults.peerPlacement)
        mainMapRanges = value(SignalRanges.self, .mainMapRanges, defaults.mainMapRanges)
        calibrateRadio = value(Bool.self, .calibrateRadio, defaults.calibrateRadio)
        prediction = value(PredictionMode.self, .prediction, defaults.prediction)
        likelyPaths = value(Bool.self, .likelyPaths, defaults.likelyPaths)
        fastUpdates = value(Bool.self, .fastUpdates, defaults.fastUpdates)
        relayIntegrity = value(Bool.self, .relayIntegrity, defaults.relayIntegrity)
    }

    /// The stored copy, or the defaults when there is none or it can't be read.
    public static func decode(_ data: Data?) -> FeatureFlags {
        guard let data, let flags = try? JSONDecoder().decode(FeatureFlags.self, from: data) else { return FeatureFlags() }
        return flags
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
