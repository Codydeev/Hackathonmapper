import Foundation

public enum RelayError: Error, Equatable {
    case invalidEnvelope
    case invalidSummary
    case tooLarge
}

/// A store-and-forward message (frame type 5). Position packets only ever carry the latest report
/// per origin; an envelope is delivered once per phone and held for neighbors that appear later,
/// until its TTL runs out or a delivery receipt clears it.
///
/// Time: wall clocks on the phones are not synchronized, so `createdAt` is advisory only. `ageMs`
/// is the time the message spent on the origin and on each relay, measured on each phone's
/// monotonic clock and summed hop by hop. It leaves out link queue and air time, so it is a lower
/// bound. TTL is enforced on `ageMs`, never on wall clock differences.
public struct RelayEnvelope: Codable, Equatable {
    public static let schemaVersion = 1
    public static let maxBodyBytes = 1_024
    public static let maxTTLMs = 15 * 60_000
    /// Relays a copy may still pass through plus relays it already passed through.
    public static let maxHops = MeshProtocol.maxPathLength
    public static let maxEncodedSize = 3_072
    public static let receiptKind = "receipt"

    public let schemaVersion: Int
    /// Created by the origin and preserved across relays; duplicates are suppressed by it.
    public let messageId: UUID
    public let originId: String
    /// Nil broadcasts to every phone.
    public let destinationId: String?
    /// Short machine name: `text`, `ping`, `receipt`, or a module's own such as `ghostcore.sos`.
    public let kind: String
    public let body: String
    /// Origin wall clock in milliseconds since 1970. Advisory: never used for ages or expiry.
    public let createdAt: Double?
    public let ageMs: Int
    public let ttlMs: Int
    /// How many more phones may relay this copy.
    public let hopsRemaining: Int
    /// Device IDs of the phones that relayed this copy, oldest first. Empty when sent by the origin.
    public let path: [String]
    /// For receipts: the message whose delivery this confirms.
    public let acknowledges: UUID?

    public init(
        messageId: UUID = UUID(),
        originId: String,
        destinationId: String? = nil,
        kind: String,
        body: String,
        createdAt: Double? = nil,
        ageMs: Int = 0,
        ttlMs: Int,
        hopsRemaining: Int,
        path: [String] = [],
        acknowledges: UUID? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.messageId = messageId
        self.originId = originId
        self.destinationId = destinationId
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.ageMs = ageMs
        self.ttlMs = ttlMs
        self.hopsRemaining = hopsRemaining
        self.path = path
        self.acknowledges = acknowledges
    }

    public var isReceipt: Bool { kind == Self.receiptKind }
    public var isExpired: Bool { ageMs >= ttlMs }

    /// The copy a relay sends on: one hop fewer, itself appended to the path, and the time it held
    /// the message added to the age.
    func relayed(by relayId: String, heldMs: Int) -> RelayEnvelope? {
        guard hopsRemaining > 0 else { return nil }
        return copy(ageMs: ageMs + max(0, heldMs), hopsRemaining: hopsRemaining - 1, path: path + [relayId])
    }

    func copy(ageMs: Int, hopsRemaining: Int, path: [String]) -> RelayEnvelope {
        RelayEnvelope(messageId: messageId, originId: originId, destinationId: destinationId, kind: kind,
                      body: body, createdAt: createdAt, ageMs: ageMs, ttlMs: ttlMs,
                      hopsRemaining: hopsRemaining, path: path, acknowledges: acknowledges)
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              DashboardContract.isValidId(originId),
              destinationId.map({ DashboardContract.isValidId($0) && $0 != originId }) ?? true,
              kind.range(of: "^[a-z0-9._-]{1,32}$", options: .regularExpression) != nil,
              body.utf8.count <= Self.maxBodyBytes,
              createdAt.map({ $0.isFinite && $0 >= 0 }) ?? true,
              (1...Self.maxTTLMs).contains(ttlMs),
              // An expired copy is still well formed; the engine counts it separately.
              ageMs >= 0, ageMs <= 4 * Self.maxTTLMs,
              hopsRemaining >= 0, path.count + hopsRemaining <= Self.maxHops,
              pathIsValid,
              isReceipt == (acknowledges != nil) else {
            throw RelayError.invalidEnvelope
        }
    }

    private var pathIsValid: Bool {
        var seen = Set<String>()
        return path.allSatisfy { DashboardContract.isValidId($0) && $0 != originId && seen.insert($0).inserted }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxEncodedSize else { throw RelayError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> RelayEnvelope {
        guard data.count <= maxEncodedSize else { throw RelayError.tooLarge }
        let envelope = try JSONDecoder().decode(RelayEnvelope.self, from: data)
        try envelope.validate()
        return envelope
    }
}

/// Body of a delivery receipt: how the confirmed message reached its destination.
public struct RelayReceiptInfo: Codable, Equatable {
    /// Relays of the copy the destination accepted, oldest first.
    public let path: [String]
    /// `ageMs` of that copy on arrival: a lower bound on delivery time.
    public let ageMs: Int

    public init(path: [String], ageMs: Int) {
        self.path = path
        self.ageMs = ageMs
    }

    public func encodedBody() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decode(body: String) -> RelayReceiptInfo? {
        try? JSONDecoder().decode(RelayReceiptInfo.self, from: Data(body.utf8))
    }
}

/// Link-local summary (frame type 6): the most recent message IDs this phone has seen. A neighbor
/// answers by sending the stored messages missing from it, which repairs copies lost when a link
/// dropped mid-transfer and brings a phone that just arrived up to date.
public struct RelaySummary: Codable, Equatable {
    public static let maxIds = 64

    public let schemaVersion: Int
    public let have: [UUID]

    public init(have: [UUID]) {
        self.schemaVersion = RelayEnvelope.schemaVersion
        self.have = have
    }

    public func validate() throws {
        guard schemaVersion == RelayEnvelope.schemaVersion, have.count <= Self.maxIds else {
            throw RelayError.invalidSummary
        }
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RelaySummary {
        guard data.count <= Framing.maxPayload else { throw RelayError.tooLarge }
        let summary = try JSONDecoder().decode(RelaySummary.self, from: data)
        try summary.validate()
        return summary
    }
}
