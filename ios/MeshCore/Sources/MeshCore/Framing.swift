import Foundation

public enum FrameType: UInt8 {
    case hello = 1
    case position = 2
    /// Link-local `RangingToken`.
    case rangingToken = 3
    /// Link-local `RangingFix`.
    case rangingFix = 4
    /// Store-and-forward `RelayEnvelope`. Version 3 phones without the relay skip it.
    case relayMessage = 5
    /// Link-local `RelaySummary`: the message IDs this phone already has.
    case relaySummary = 6
    /// GhostCore contract `RelayMessage`, carried by `RecordRelay`.
    case record = 7
}

public struct Frame: Equatable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

/// BLE stream framing: `[type: UInt8][length: UInt32 big-endian][payload]`.
public enum Framing {
    public static let headerLength = 5
    public static let maxPayload = 4_096

    public static func encode(_ payload: Data, type: FrameType) -> Data? {
        guard (1...maxPayload).contains(payload.count) else { return nil }
        let size = UInt32(payload.count)
        var data = Data([type.rawValue, UInt8(size >> 24 & 255), UInt8(size >> 16 & 255),
                         UInt8(size >> 8 & 255), UInt8(size & 255)])
        data.append(payload)
        return data
    }
}

/// Reassembles frames from the chunks of one link. Not thread-safe; one instance per link.
public struct FrameAssembler {
    public static let maxBuffered = 8_192
    /// A partial frame older than this is discarded, so a lost chunk cannot wedge the link.
    public static let timeout: TimeInterval = 10

    private var buffer = Data()
    private var updatedAt: Date?

    public init() {}

    public var hasPartialFrame: Bool { !buffer.isEmpty }

    /// Returns the frames completed by `chunk`. Throws on malformed input and clears the buffer.
    public mutating func append(_ chunk: Data, at now: Date = Date()) throws -> [Frame] {
        buffer.append(chunk)
        guard buffer.count <= Self.maxBuffered else {
            reset()
            throw MeshCoreError.invalidFrame
        }
        var frames: [Frame] = []
        while buffer.count >= Framing.headerLength {
            let header = [UInt8](buffer.prefix(Framing.headerLength))
            let length = header[1...].reduce(0) { ($0 << 8) | Int($1) }
            // Type 0 is how a version 1 length prefix starts, so it is never valid.
            guard header[0] != 0, (1...Framing.maxPayload).contains(length) else {
                reset()
                throw MeshCoreError.invalidFrame
            }
            guard buffer.count >= Framing.headerLength + length else { break }
            // Unknown types are skipped, so a later frame type does not need another version bump.
            if let type = FrameType(rawValue: header[0]) {
                frames.append(Frame(type: type, payload: Data(buffer.dropFirst(Framing.headerLength).prefix(length))))
            }
            buffer = Data(buffer.dropFirst(Framing.headerLength + length))
        }
        updatedAt = buffer.isEmpty ? nil : now
        return frames
    }

    /// Drops a partial frame that has waited longer than `timeout`. Returns true if one was dropped.
    @discardableResult
    public mutating func expire(at now: Date = Date()) -> Bool {
        guard let updatedAt, now.timeIntervalSince(updatedAt) > Self.timeout else { return false }
        reset()
        return true
    }

    public mutating func reset() {
        buffer = Data()
        updatedAt = nil
    }
}

/// Outgoing queue for one link. Holds at most one pending frame per key, so a slow link only
/// ever delivers the latest report for each origin. The frame being sent is never interrupted,
/// which keeps the receiver's framing intact.
public struct LinkOutbox {
    public private(set) var chunks: [Data] = []
    private var pending: [String: Data] = [:]
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { chunks.isEmpty && order.isEmpty }
    public var pendingCount: Int { order.count }

    /// A newer frame for the same key replaces the queued one and keeps its place in line.
    public mutating func enqueue(_ framed: Data, key: String) {
        if pending.updateValue(framed, forKey: key) == nil { order.append(key) }
    }

    public mutating func nextChunk(maxLength: Int) -> Data? {
        if chunks.isEmpty, !order.isEmpty, let framed = pending.removeValue(forKey: order.removeFirst()) {
            let size = max(1, maxLength)
            chunks = stride(from: 0, to: framed.count, by: size).map {
                framed.subdata(in: $0..<min($0 + size, framed.count))
            }
        }
        return chunks.first
    }

    public mutating func chunkSent() {
        if !chunks.isEmpty { chunks.removeFirst() }
    }

    public mutating func removeAll() {
        chunks.removeAll()
        pending.removeAll()
        order.removeAll()
    }
}
