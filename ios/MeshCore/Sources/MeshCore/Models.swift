import Foundation

public enum MeshCoreError: Error, Equatable {
    case invalidUpdate
    case invalidPacket
    case invalidHello
    case packetTooLarge
    case frameMismatch
    case deviceCapacityReached
    case epochCapacityReached
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

    public init(
        id: String,
        label: String? = nil,
        epochId: String,
        sequence: Int,
        role: String,
        position: Position,
        positionMode: String,
        accuracyMeters: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.epochId = epochId
        self.sequence = sequence
        self.role = role
        self.position = position
        self.positionMode = positionMode
        self.accuracyMeters = accuracyMeters
    }

    // Dashboard limits (website/server/validate.ts). Text is counted in UTF-16 units like JavaScript.
    public static let maximumIdLength = 64
    public static let maximumLabelLength = 40
    public static let maximumCoordinate = 10_000.0
    public static let maximumAccuracy = 1_000.0

    public func validate() throws {
        // Sequences must round-trip through JSON numbers.
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf16.count <= Self.maximumIdLength,
              label.map({ $0.utf16.count <= Self.maximumLabelLength }) ?? true,
              UUID(uuidString: epochId) != nil,
              sequence >= 0, sequence <= 9_007_199_254_740_991,
              ["anchor", "mobile", "gateway"].contains(role),
              [position.x, position.y, position.z].allSatisfy({ $0.isFinite && abs($0) <= Self.maximumCoordinate }),
              ["3d", "floor"].contains(positionMode),
              positionMode != "floor" || position.y == 0,
              accuracyMeters.map({ $0.isFinite && $0 >= 0 && $0 <= Self.maximumAccuracy }) ?? true else {
            throw MeshCoreError.invalidUpdate
        }
    }
}

// Link-local handshake exchanged once per Bluetooth link before any mesh data. Never relayed.
public struct Hello: Codable, Equatable {
    public static let currentProtocolVersion = 2

    public let protocolVersion: Int
    public let frameId: String
    public let deviceId: String
    public let label: String?

    public init(frameId: String, deviceId: String, label: String?) {
        self.protocolVersion = Self.currentProtocolVersion
        self.frameId = frameId
        self.deviceId = deviceId
        self.label = label
    }

    public func validate() throws {
        guard protocolVersion >= 1, !frameId.isEmpty, frameId.utf8.count <= 128,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deviceId.utf16.count <= DeviceUpdate.maximumIdLength,
              label.map({ $0.utf16.count <= DeviceUpdate.maximumLabelLength }) ?? true else {
            throw MeshCoreError.invalidHello
        }
    }

    // Phones mapping a different room or speaking another protocol never join the same mesh.
    public func isCompatible(frameId: String) -> Bool {
        protocolVersion == Self.currentProtocolVersion && self.frameId == frameId
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Hello {
        guard data.count <= 1_024 else { throw MeshCoreError.packetTooLarge }
        let hello = try JSONDecoder().decode(Hello.self, from: data)
        try hello.validate()
        return hello
    }
}

public struct MeshPacket: Codable {
    public let schemaVersion: Int
    public let frameId: String
    public let hopsRemaining: Int
    public let update: DeviceUpdate

    public init(frameId: String, hopsRemaining: Int, update: DeviceUpdate) {
        self.schemaVersion = 1
        self.frameId = frameId
        self.hopsRemaining = hopsRemaining
        self.update = update
    }

    public func validate() throws {
        guard schemaVersion == 1, !frameId.isEmpty, frameId.utf8.count <= 128,
              (0...8).contains(hopsRemaining) else {
            throw MeshCoreError.invalidPacket
        }
        try update.validate()
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
