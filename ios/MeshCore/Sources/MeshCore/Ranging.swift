import Foundation

/// Link-local: a phone's Nearby Interaction discovery token for one neighbor. Each phone runs one
/// session per selected neighbor (`UWBSessionPolicy`), configured with that neighbor's token. Never relayed.
public struct RangingToken: Codable, Equatable {
    public static let maxTokenSize = 1_024

    /// Archived `NIDiscoveryToken`; opaque to MeshCore.
    public let token: Data
    /// The sender is a mounted direction anchor that sends `RangingFix`es.
    public let isAnchor: Bool
    /// The sender can measure UWB direction, so it may report bearings. Absent (older senders) means false.
    public let uwbDirection: Bool

    public init(token: Data, isAnchor: Bool, uwbDirection: Bool = false) {
        self.token = token
        self.isAnchor = isAnchor
        self.uwbDirection = uwbDirection
    }

    private enum CodingKeys: String, CodingKey {
        case token, isAnchor, uwbDirection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(Data.self, forKey: .token)
        isAnchor = try container.decode(Bool.self, forKey: .isAnchor)
        uwbDirection = try container.decodeIfPresent(Bool.self, forKey: .uwbDirection) ?? false
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

/// Horizontal map-frame direction of a link, in degrees [0, 360) from map +z (north) towards +x (east).
public struct LinkBearing: Equatable {
    public let degrees: Double
    public let errorDegrees: Double

    public init(degrees: Double, errorDegrees: Double) {
        self.degrees = PeerBearing.normalized(degrees)
        self.errorDegrees = errorDegrees
    }

    /// The same link seen from the other end.
    public var reversed: LinkBearing { LinkBearing(degrees: degrees + 180, errorDegrees: errorDegrees) }
}

/// A device attitude as Core Motion's `CMAttitude.rotationMatrix` (`rows[i][j]` = `m(i+1)(j+1)`),
/// taken with the `.xTrueNorthZVertical` reference frame: reference x = true north, y = west, z = up.
///
/// Convention assumed (verify on phones, see MAP_DESIGN.md risks): the matrix maps reference-frame
/// vectors to device-frame vectors, `v_device = R · v_reference`. Row i is therefore device axis i
/// expressed in reference coordinates, and a device-frame vector becomes `v_reference = Rᵀ · v_device`.
/// This matches the commonly used identity `CMDeviceMotion.gravity ≈ −(m13, m23, m33)`.
/// If bearings come out mirrored on phones, the matrix is the transpose and `referenceVector` must use `R`.
public struct RotationMatrix: Equatable {
    public let rows: [[Double]]

    public init(rows: [[Double]]) {
        self.rows = rows
    }

    public init(m11: Double, m12: Double, m13: Double,
                m21: Double, m22: Double, m23: Double,
                m31: Double, m32: Double, m33: Double) {
        rows = [[m11, m12, m13], [m21, m22, m23], [m31, m32, m33]]
    }

    public static let identity = RotationMatrix(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])

    var isValid: Bool { rows.count == 3 && rows.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) } }

    /// `Rᵀ · v`: a device-frame vector in the reference frame.
    func referenceVector(_ v: Vector3) -> Vector3 {
        Vector3(rows[0][0] * v.x + rows[1][0] * v.y + rows[2][0] * v.z,
                rows[0][1] * v.x + rows[1][1] * v.y + rows[2][1] * v.z,
                rows[0][2] * v.x + rows[1][2] * v.y + rows[2][2] * v.z)
    }
}

/// Turns a hand-held phone's Nearby Interaction direction into a map bearing with its attitude.
/// Map frame (GeoFrame): x east, y up, z north.
public enum PeerBearing {
    /// Direction error of iPhone UWB; combined with the compass error as √(a² + b²).
    public static let directionErrorDegrees = 15.0
    /// A direction this close to vertical has no usable bearing.
    public static let minHorizontal = 0.3

    /// Wraps any finite angle into [0, 360).
    public static func normalized(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let value = r < 0 ? r + 360 : r
        return value >= 360 ? 0 : value
    }

    /// Map-frame unit vector (x east, y up, z north) for a device-frame direction, or nil.
    public static func mapVector(direction: Vector3, attitude: RotationMatrix) -> Vector3? {
        guard attitude.isValid, let d = direction.normalized else { return nil }
        let r = attitude.referenceVector(d) // x north, y west, z up
        return Vector3(-r.y, r.z, r.x).normalized
    }

    /// Bearing of a map-frame vector; nil when its horizontal component is below `minHorizontal`.
    public static func bearing(mapDirection: Vector3, errorDegrees: Double) -> LinkBearing? {
        guard let u = mapDirection.normalized, errorDegrees.isFinite, errorDegrees >= 0,
              (u.x * u.x + u.z * u.z).squareRoot() >= minHorizontal else { return nil }
        return LinkBearing(degrees: atan2(u.x, u.z) * 180 / .pi, errorDegrees: min(180, max(1, errorDegrees)))
    }

    /// nil when the horizontal component is < 0.3 or calibration is unknown.
    public static func bearing(direction: Vector3, attitude: RotationMatrix,
                               compassErrorDegrees: Double?) -> LinkBearing? {
        guard let compass = compassErrorDegrees, compass.isFinite, compass >= 0,
              let v = mapVector(direction: direction, attitude: attitude) else { return nil }
        return bearing(mapDirection: v, errorDegrees: (directionErrorDegrees * directionErrorDegrees + compass * compass).squareRoot())
    }

    /// Map heading the phone faces, for a heading-up map: the direction of its top edge or of its
    /// back, whichever is more horizontal (the top when flat, the back when upright). nil when the
    /// attitude is invalid.
    public static func headingDegrees(attitude: RotationMatrix) -> Double? {
        guard let top = mapVector(direction: Vector3(0, 1, 0), attitude: attitude),
              let back = mapVector(direction: Vector3(0, 0, -1), attitude: attitude) else { return nil }
        let horizontal = { (v: Vector3) in (v.x * v.x + v.z * v.z).squareRoot() }
        let v = horizontal(top) >= horizontal(back) ? top : back
        guard horizontal(v) >= minHorizontal else { return nil }
        return normalized(atan2(v.x, v.z) * 180 / .pi)
    }
}
