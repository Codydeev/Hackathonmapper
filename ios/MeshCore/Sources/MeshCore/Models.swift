import Foundation

public enum MeshCoreError: Error, Equatable {
    case invalidUpdate
    case invalidPacket
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

    public func validate() throws {
        // Text bounds are UTF-8 bytes; sequences must round-trip through JSON numbers.
        guard !id.isEmpty, id.utf8.count <= 128,
              label.map({ $0.utf8.count <= 128 }) ?? true,
              UUID(uuidString: epochId) != nil,
              sequence >= 0, sequence <= 9_007_199_254_740_991,
              ["anchor", "mobile", "gateway"].contains(role),
              position.x.isFinite, position.y.isFinite, position.z.isFinite,
              ["3d", "floor"].contains(positionMode),
              positionMode != "floor" || position.y == 0,
              accuracyMeters.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw MeshCoreError.invalidUpdate
        }
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
