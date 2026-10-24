import Foundation

public enum MeshCoreError: Error, Equatable {
    case invalidUpdate
    case invalidPacket
    case packetTooLarge
    case frameMismatch
    case deviceCapacityReached
    case epochCapacityReached
    case invalidFrame
    case invalidHello
    case invalidRanging
}

/// Mesh wire format. Version 2 added typed frames, the link Hello and `MeshPacket.path`; version 3
/// added UWB ranging frames and skips unknown frame types. Every phone in a demo must run the same version.
public enum MeshProtocol {
    public static let version = 3
    /// Longest relay path a packet may carry; matches the largest accepted hop count.
    public static let maxPathLength = 8
}

/// Limits of the dashboard upload contract (WEBSITE_PLAN.md). The dashboard rejects a whole
/// batch if one entry breaks them, so relayed reports are held to the same limits on ingest.
public enum DashboardContract {
    /// Lengths are UTF-16 code units, which is how the dashboard (JavaScript) measures strings.
    public static let maxIdLength = 64
    public static let maxLabelLength = 40
    public static let maxCoordinate = 10_000.0
    public static let maxAccuracyMeters = 1_000.0
    public static let maxNeighbors = 16
    public static let rssiRange = -127...20
    public static let maxAgeMs = 86_400_000

    static func isValidId(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= maxIdLength
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates on character boundaries so the result fits `maxLabelLength` UTF-16 units.
    public static func truncatedLabel(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf16.count + character.utf16.count <= maxLabelLength else { break }
            result.append(character)
        }
        return result
    }
}

/// A direct BLE link observed by the reporting phone. Relays forward it unchanged.
public struct NeighborObservation: Codable, Equatable {
    public let id: String
    public let rssi: Int?
    public let ageMs: Int?

    public init(id: String, rssi: Int? = nil, ageMs: Int? = nil) {
        self.id = id
        self.rssi = rssi
        self.ageMs = ageMs
    }
}

public struct Position: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct DeviceUpdate: Codable, Equatable {
    public let id: String
    public let label: String?
    public let epochId: String
    public let sequence: Int
    public let role: String
    public let position: Position
    public let positionMode: String
    public let accuracyMeters: Double?
    public let neighbors: [NeighborObservation]?

    public init(
        id: String,
        label: String? = nil,
        epochId: String,
        sequence: Int,
        role: String,
        position: Position,
        positionMode: String,
        accuracyMeters: Double? = nil,
        neighbors: [NeighborObservation]? = nil
    ) {
        self.id = id
        self.label = label
        self.epochId = epochId
        self.sequence = sequence
        self.role = role
        self.position = position
        self.positionMode = positionMode
        self.accuracyMeters = accuracyMeters
        self.neighbors = neighbors
    }

    public func validate() throws {
        // Bounds follow DashboardContract; sequences must round-trip through JSON numbers.
        let coordinates = [position.x, position.y, position.z]
        guard DashboardContract.isValidId(id),
              label.map({ $0.utf16.count <= DashboardContract.maxLabelLength }) ?? true,
              UUID(uuidString: epochId) != nil,
              sequence >= 0, sequence <= 9_007_199_254_740_991,
              ["anchor", "mobile", "gateway"].contains(role),
              coordinates.allSatisfy({ $0.isFinite && abs($0) <= DashboardContract.maxCoordinate }),
              ["3d", "floor"].contains(positionMode),
              positionMode != "floor" || position.y == 0,
              accuracyMeters.map({ $0.isFinite && $0 >= 0 && $0 <= DashboardContract.maxAccuracyMeters }) ?? true,
              neighborsAreValid else {
            throw MeshCoreError.invalidUpdate
        }
    }

    private var neighborsAreValid: Bool {
        guard let neighbors else { return true }
        guard neighbors.count <= DashboardContract.maxNeighbors else { return false }
        var seen = Set<String>()
        return neighbors.allSatisfy { neighbor in
            DashboardContract.isValidId(neighbor.id)
                && neighbor.id != id
                && seen.insert(neighbor.id).inserted
                && (neighbor.rssi.map { DashboardContract.rssiRange.contains($0) } ?? true)
                && (neighbor.ageMs.map { (0...DashboardContract.maxAgeMs).contains($0) } ?? true)
        }
    }
}

public struct MeshPacket: Codable {
    public let schemaVersion: Int
    public let frameId: String
    public let hopsRemaining: Int
    /// Device IDs of the phones that relayed this copy, oldest first. Empty when sent by the origin.
    public let path: [String]
    public let update: DeviceUpdate

    public init(frameId: String, hopsRemaining: Int, update: DeviceUpdate, path: [String] = []) {
        self.schemaVersion = MeshProtocol.version
        self.frameId = frameId
        self.hopsRemaining = hopsRemaining
        self.path = path
        self.update = update
    }

    public func validate() throws {
        guard schemaVersion == MeshProtocol.version, !frameId.isEmpty, frameId.utf8.count <= 128,
              (0...8).contains(hopsRemaining), pathIsValid else {
            throw MeshCoreError.invalidPacket
        }
        try update.validate()
    }

    private var pathIsValid: Bool {
        guard path.count <= MeshProtocol.maxPathLength else { return false }
        var seen = Set<String>()
        return path.allSatisfy { DashboardContract.isValidId($0) && $0 != update.id && seen.insert($0).inserted }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4_096 else {
            throw MeshCoreError.packetTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> MeshPacket {
        guard data.count <= 4_096 else {
            throw MeshCoreError.packetTooLarge
        }
        let packet = try JSONDecoder().decode(MeshPacket.self, from: data)
        try packet.validate()
        return packet
    }
}

/// First message on every BLE link, in both directions. A link carries mesh packets only after
/// both sides have subscribed and a valid Hello with the same protocol version and frame arrived.
public struct Hello: Codable, Equatable {
    public static let maxEncodedSize = 512

    public let protocolVersion: Int
    public let frameId: String
    public let deviceId: String
    public let label: String?

    public init(frameId: String, deviceId: String, label: String?) {
        self.protocolVersion = MeshProtocol.version
        self.frameId = frameId
        self.deviceId = deviceId
        self.label = label
    }

    // The protocol version is checked by the caller, so a mismatch can be reported as such.
    public func validate() throws {
        guard !frameId.isEmpty, frameId.utf8.count <= 128,
              DashboardContract.isValidId(deviceId),
              label.map({ $0.utf16.count <= DashboardContract.maxLabelLength }) ?? true else {
            throw MeshCoreError.invalidHello
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxEncodedSize else { throw MeshCoreError.invalidHello }
        return data
    }

    public static func decode(_ data: Data) throws -> Hello {
        guard data.count <= maxEncodedSize else { throw MeshCoreError.invalidHello }
        let hello = try JSONDecoder().decode(Hello.self, from: data)
        try hello.validate()
        return hello
    }
}
