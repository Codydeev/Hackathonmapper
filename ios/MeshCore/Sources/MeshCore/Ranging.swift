import Foundation

/// Link-local: a phone's Nearby Interaction discovery token for one neighbor. Each phone runs one
/// session per neighbor, configured with that neighbor's token. Never relayed.
public struct RangingToken: Codable, Equatable {
    public static let maxTokenSize = 1_024

    /// Archived `NIDiscoveryToken`; opaque to MeshCore.
    public let token: Data
    /// Only links with a direction anchor on at least one side need a session.
    public let isAnchor: Bool

    public init(token: Data, isAnchor: Bool) {
        self.token = token
        self.isAnchor = isAnchor
    }

    public func encoded() throws -> Data {
        guard (1...Self.maxTokenSize).contains(token.count) else { throw MeshCoreError.invalidRanging }
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RangingToken {
        guard data.count <= Framing.maxPayload else { throw MeshCoreError.invalidRanging }
        let value = try JSONDecoder().decode(RangingToken.self, from: data)
        guard (1...maxTokenSize).contains(value.token.count) else { throw MeshCoreError.invalidRanging }
        return value
    }
}

/// Link-local: a position an anchor measured for the phone at the other end of the link from UWB
/// distance and direction. The target publishes it as its own report. Never relayed.
public struct RangingFix: Codable, Equatable {
    /// A target stops using a fix this old; it never falls back to manual coordinates silently.
    public static let maxAge: TimeInterval = 3

    public let anchorId: String
    public let targetId: String
    public let position: Position
    public let accuracyMeters: Double
    public let distanceMeters: Double

    public init(anchorId: String, targetId: String, position: Position, accuracyMeters: Double, distanceMeters: Double) {
        self.anchorId = anchorId
        self.targetId = targetId
        self.position = position
        self.accuracyMeters = accuracyMeters
        self.distanceMeters = distanceMeters
    }

    public func validate() throws {
        guard DashboardContract.isValidId(anchorId), DashboardContract.isValidId(targetId), anchorId != targetId,
              [position.x, position.y, position.z].allSatisfy({ $0.isFinite && abs($0) <= DashboardContract.maxCoordinate }),
              accuracyMeters.isFinite, (0...DashboardContract.maxAccuracyMeters).contains(accuracyMeters),
              distanceMeters.isFinite, distanceMeters >= 0 else {
            throw MeshCoreError.invalidRanging
        }
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RangingFix {
        guard data.count <= Framing.maxPayload else { throw MeshCoreError.invalidRanging }
        let fix = try JSONDecoder().decode(RangingFix.self, from: data)
        try fix.validate()
        return fix
    }
}

public struct Vector3: Equatable {
    public var x, y, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var length: Double { (x * x + y * y + z * z).squareRoot() }
    func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    func cross(_ o: Vector3) -> Vector3 { Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
    func scaled(_ s: Double) -> Vector3 { Vector3(x * s, y * s, z * s) }
    func minus(_ o: Vector3) -> Vector3 { Vector3(x - o.x, y - o.y, z - o.z) }
    var normalized: Vector3? {
        let l = length
        return l.isFinite && l > 0 ? scaled(1 / l) : nil
    }
}

/// Converts a Nearby Interaction measurement taken by a mounted anchor into the shared frame.
///
/// Device frame (Core Motion and Nearby Interaction): x to the right of the screen, y up the
/// screen, z out of the screen, so a peer straight behind the phone is at (0, 0, -1).
/// `headingDegrees` is the direction the back of the phone faces, projected on the floor plan and
/// measured from map +z towards map +x. Gravity supplies pitch and roll, so only the heading has to
/// be entered. Map frame: x right, y up, z forward.
public enum AnchorGeometry {
    /// Rough direction error of iPhone UWB plus the error of a hand-entered heading.
    public static let directionErrorDegrees = 10.0
    public static let headingErrorDegrees = 5.0
    public static let baseErrorMeters = 0.3
    /// The back may point at most this far above or below the horizon; beyond it the heading is
    /// too poorly defined.
    public static let maxTiltDegrees = 60.0

    public static let upright = Vector3(0, -1, 0)

    /// Map-frame unit vector for a device-frame direction; nil if the phone lies too flat.
    public static func mapDirection(_ direction: Vector3, gravity: Vector3 = upright, headingDegrees: Double) -> Vector3? {
        guard headingDegrees.isFinite, let up = gravity.scaled(-1).normalized, let d = direction.normalized else { return nil }
        let back = Vector3(0, 0, -1)
        let horizontal = back.minus(up.scaled(back.dot(up)))
        guard horizontal.length >= cos(maxTiltDegrees * .pi / 180), let forward = horizontal.normalized else { return nil }
        let right = forward.cross(up)
        let a = d.dot(forward), r = d.dot(right), u = d.dot(up)
        let h = headingDegrees * .pi / 180
        return Vector3(a * sin(h) + r * cos(h), u, a * cos(h) - r * sin(h))
    }

    /// The direction and heading errors are rough upper bounds added together, so this is used as
    /// the 95 % radius `accuracyMeters` carries.
    public static func accuracy(distance: Double) -> Double {
        let angle = (directionErrorDegrees + headingErrorDegrees) * .pi / 180
        let value = distance * sin(angle) + baseErrorMeters
        return min(DashboardContract.maxAccuracyMeters, (value * 100).rounded() / 100)
    }

    /// Nil unless the measurement is usable. With `floor`, the result lies on the floor (y = 0).
    public static func fix(anchorId: String, targetId: String, anchor: Position, headingDegrees: Double,
                           gravity: Vector3 = upright, distance: Double, direction: Vector3, floor: Bool) -> RangingFix? {
        guard distance.isFinite, distance >= 0,
              let v = mapDirection(direction, gravity: gravity, headingDegrees: headingDegrees) else { return nil }
        let position = Position(x: anchor.x + distance * v.x,
                                y: floor ? 0 : anchor.y + distance * v.y,
                                z: anchor.z + distance * v.z)
        let fix = RangingFix(anchorId: anchorId, targetId: targetId, position: position,
                             accuracyMeters: accuracy(distance: distance), distanceMeters: distance)
        return (try? fix.validate()) == nil ? nil : fix
    }
}
