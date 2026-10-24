import Foundation

// Wire framing on one Bluetooth link: [type: UInt8][length: UInt32 big-endian][payload].
public enum FrameType: UInt8 {
    case hello = 1
    case position = 2
}

public struct Frame: Equatable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public static let headerLength = 5
    public static let maximumPayload = 4_096

    // Nil for empty or oversized payloads.
    public static func encode(_ type: FrameType, _ payload: Data) -> Data? {
        guard (1...maximumPayload).contains(payload.count) else { return nil }
        let size = UInt32(payload.count)
        return Data([type.rawValue, UInt8((size >> 24) & 255), UInt8((size >> 16) & 255),
                     UInt8((size >> 8) & 255), UInt8(size & 255)]) + payload
    }
}

public enum FrameError: Error, Equatable {
    case invalidFrame
    case bufferOverflow
}

// Reassembles frames from the chunks of one link. Any error discards the buffer.
public struct FrameAssembler {
    public static let maximumBuffer = 8_192

    private var buffer = Data()
    public private(set) var updatedAt: Date?

    public init() {}

    public var isEmpty: Bool { buffer.isEmpty }

    public mutating func append(_ data: Data, at now: Date = Date()) throws -> [Frame] {
        buffer.append(data)
        guard buffer.count <= Self.maximumBuffer else { reset(); throw FrameError.bufferOverflow }
        var frames: [Frame] = []
        while buffer.count >= Frame.headerLength {
            let start = buffer.startIndex
            guard let type = FrameType(rawValue: buffer[start]) else { reset(); throw FrameError.invalidFrame }
            let length = buffer[(start + 1)..<(start + Frame.headerLength)].reduce(0) { ($0 << 8) | Int($1) }
            guard (1...Frame.maximumPayload).contains(length) else { reset(); throw FrameError.invalidFrame }
            guard buffer.count >= Frame.headerLength + length else { break }
            let payloadStart = start + Frame.headerLength
            frames.append(Frame(type: type, payload: Data(buffer[payloadStart..<(payloadStart + length)])))
            buffer = Data(buffer.dropFirst(Frame.headerLength + length))
        }
        updatedAt = buffer.isEmpty ? nil : now
        return frames
    }

    // An incomplete frame that has not grown for `timeout` seconds will never complete.
    public func isStale(at now: Date, timeout: TimeInterval) -> Bool {
        updatedAt.map { now.timeIntervalSince($0) > timeout } ?? false
    }

    public mutating func reset() {
        buffer = Data()
        updatedAt = nil
    }
}

// Per-link send queue that keeps at most one pending message per key, so a slow link
// delivers the latest position of each phone instead of a backlog of old ones.
public struct LinkOutbox {
    // The transfer in progress. Never dropped part-way, so receiver framing stays intact.
    public private(set) var chunks: [Data] = []
    private var pending: [String: Data] = [:]
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { chunks.isEmpty && order.isEmpty }
    public var pendingCount: Int { order.count }

    // A newer message for the same key replaces the queued one and keeps its place in line.
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
}
