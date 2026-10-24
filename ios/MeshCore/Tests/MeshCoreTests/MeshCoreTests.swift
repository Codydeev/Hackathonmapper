import Foundation
import XCTest
import MeshCore

final class MeshCoreTests: XCTestCase {
    private let epoch = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let nextEpoch = "11111111-2222-3333-4444-555555555555"

    private func update(
        id: String = "device",
        label: String? = nil,
        epochId: String? = nil,
        sequence: Int = 0,
        role: String = "mobile",
        position: Position = Position(x: 1, y: 2, z: 3),
        positionMode: String = "3d",
        accuracyMeters: Double? = nil
    ) -> DeviceUpdate {
        DeviceUpdate(
            id: id, label: label, epochId: epochId ?? epoch, sequence: sequence,
            role: role, position: position, positionMode: positionMode,
            accuracyMeters: accuracyMeters
        )
    }

    private func packet(
        _ update: DeviceUpdate,
        hops: Int = 8,
        frame: String = "frame"
    ) -> MeshPacket {
        MeshPacket(frameId: frame, hopsRemaining: hops, update: update)
    }

    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread {
            try body()
        } else {
            try DispatchQueue.main.sync(execute: body)
        }
    }

    func testPositionAndOptionalDefaults() throws {
        let position = Position(x: 1, y: 2, z: 3)
        XCTAssertEqual(try JSONDecoder().decode(
            Position.self, from: JSONEncoder().encode(position)
        ), position)
        let value = update()
        XCTAssertNil(value.label)
        XCTAssertNil(value.accuracyMeters)
        try value.validate()
    }

    func testAllPublicRolesAndModes() throws {
        for role in ["anchor", "mobile", "gateway"] {
            try update(role: role).validate()
            try update(
                role: role, position: Position(x: 1, y: 0, z: 3),
                positionMode: "floor", accuracyMeters: 0
            ).validate()
        }
    }

    func testUpdateValidation() throws {
        let invalid = [
            update(id: ""),
            update(id: String(repeating: "x", count: 129)),
            update(label: String(repeating: "x", count: 129)),
            update(epochId: "not-a-uuid"),
            update(sequence: -1),
            update(sequence: 9_007_199_254_740_992),
            update(role: "unknown"),
            update(positionMode: "2d"),
            update(positionMode: "floor"),
            update(accuracyMeters: -0.1),
            update(accuracyMeters: .infinity),
            update(accuracyMeters: .nan)
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.validate())
        }
        for coordinate in [Double.nan, .infinity, -.infinity] {
            for position in [
                Position(x: coordinate, y: 0, z: 0),
                Position(x: 0, y: coordinate, z: 0),
                Position(x: 0, y: 0, z: coordinate)
            ] {
                XCTAssertThrowsError(try update(position: position).validate())
            }
        }
        try update(
            id: String(repeating: "x", count: 64),
            label: String(repeating: "x", count: 40),
            sequence: 9_007_199_254_740_991
        ).validate()
        XCTAssertThrowsError(try update(id: String(repeating: "é", count: 65)).validate())
    }

    // Anything the mesh accepts must also pass website/server/validate.ts, or one report blocks every upload.
    func testUpdateValidationMatchesDashboardLimits() throws {
        let invalid = [
            update(id: "   "),
            update(id: String(repeating: "x", count: 65)),
            update(label: String(repeating: "x", count: 41)),
            // 25 emoji are 50 UTF-16 units: 40 Swift characters but 65 JavaScript ones.
            update(label: String(repeating: "😀", count: 25) + String(repeating: "x", count: 15)),
            update(position: Position(x: 10_000.001, y: 0, z: 0)),
            update(position: Position(x: 0, y: -10_000.001, z: 0)),
            update(position: Position(x: 0, y: 0, z: 10_000.001)),
            update(accuracyMeters: 1_000.1)
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.validate())
        }
        try update(label: String(repeating: "😀", count: 20), position: Position(x: 10_000, y: -10_000, z: 10_000),
                   accuracyMeters: 1_000).validate()
    }

    func testHelloRoundTripAndCompatibility() throws {
        let hello = Hello(frameId: "frame", deviceId: "device", label: "Phone")
        let decoded = try Hello.decode(hello.encoded())
        XCTAssertEqual(decoded, hello)
        XCTAssertEqual(decoded.protocolVersion, Hello.currentProtocolVersion)
        XCTAssertTrue(decoded.isCompatible(frameId: "frame"))
        XCTAssertFalse(decoded.isCompatible(frameId: "other"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: hello.encoded()) as? [String: Any])
        object["protocolVersion"] = 1
        XCTAssertFalse(try Hello.decode(JSONSerialization.data(withJSONObject: object)).isCompatible(frameId: "frame"))
        for invalid in [
            Hello(frameId: "", deviceId: "device", label: nil),
            Hello(frameId: "frame", deviceId: " ", label: nil),
            Hello(frameId: "frame", deviceId: String(repeating: "x", count: 65), label: nil),
            Hello(frameId: "frame", deviceId: "device", label: String(repeating: "x", count: 41))
        ] {
            XCTAssertThrowsError(try invalid.encoded())
        }
        XCTAssertThrowsError(try Hello.decode(Data("not json".utf8)))
    }

    func testFrameEncodingBounds() throws {
        XCTAssertNil(Frame.encode(.position, Data()))
        XCTAssertNil(Frame.encode(.position, Data(repeating: 1, count: Frame.maximumPayload + 1)))
        let framed = try XCTUnwrap(Frame.encode(.hello, Data([7, 8, 9])))
        XCTAssertEqual(framed, Data([1, 0, 0, 0, 3, 7, 8, 9]))
    }

    func testAssemblerHandlesSplitAndCombinedFrames() throws {
        let first = try XCTUnwrap(Frame.encode(.hello, Data("hello".utf8)))
        let second = try XCTUnwrap(Frame.encode(.position, Data(repeating: 42, count: 300)))
        let stream = first + second
        // Split at every chunk size, including splits inside the header.
        for size in [1, 2, 4, 5, 6, 20, 182, 512, stream.count] {
            var assembler = FrameAssembler()
            var frames: [Frame] = []
            for start in stride(from: 0, to: stream.count, by: size) {
                frames += try assembler.append(stream.subdata(in: start..<min(start + size, stream.count)))
            }
            XCTAssertEqual(frames, [Frame(type: .hello, payload: Data("hello".utf8)),
                                    Frame(type: .position, payload: Data(repeating: 42, count: 300))], "size \(size)")
            XCTAssertTrue(assembler.isEmpty)
            XCTAssertNil(assembler.updatedAt)
        }
    }

    func testAssemblerRejectsInvalidFramesAndRecovers() throws {
        var assembler = FrameAssembler()
        XCTAssertThrowsError(try assembler.append(Data([9, 0, 0, 0, 1, 0]))) {
            XCTAssertEqual($0 as? FrameError, .invalidFrame)
        }
        XCTAssertTrue(assembler.isEmpty)
        XCTAssertThrowsError(try assembler.append(Data([2, 0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? FrameError, .invalidFrame)
        }
        XCTAssertThrowsError(try assembler.append(Data([2, 0, 0, 16, 1]))) {
            XCTAssertEqual($0 as? FrameError, .invalidFrame)
        }
        XCTAssertThrowsError(try assembler.append(Data(repeating: 2, count: FrameAssembler.maximumBuffer + 1))) {
            XCTAssertEqual($0 as? FrameError, .bufferOverflow)
        }
        let valid = try XCTUnwrap(Frame.encode(.position, Data([1])))
        XCTAssertEqual(try assembler.append(valid).count, 1)
    }

    func testAssemblerStaleness() throws {
        var assembler = FrameAssembler()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(assembler.isStale(at: start.addingTimeInterval(60), timeout: 10))
        XCTAssertTrue(try assembler.append(Data([2, 0, 0, 0, 5, 1]), at: start).isEmpty)
        XCTAssertFalse(assembler.isStale(at: start.addingTimeInterval(10), timeout: 10))
        XCTAssertTrue(assembler.isStale(at: start.addingTimeInterval(10.1), timeout: 10))
        assembler.reset()
        XCTAssertFalse(assembler.isStale(at: start.addingTimeInterval(60), timeout: 10))
    }

    func testOutboxCoalescesByKeyAndKeepsTransferInProgress() {
        var outbox = LinkOutbox()
        XCTAssertNil(outbox.nextChunk(maxLength: 2))
        outbox.enqueue(Data([1, 1, 1]), key: "a")
        outbox.enqueue(Data([2]), key: "b")
        outbox.enqueue(Data([3, 3, 3, 3]), key: "a")
        XCTAssertEqual(outbox.pendingCount, 2)
        // Newer "a" replaced the older one and kept its place ahead of "b".
        XCTAssertEqual(outbox.nextChunk(maxLength: 2), Data([3, 3]))
        // A replacement arriving mid-transfer waits; the transfer in progress is never cut.
        outbox.enqueue(Data([4]), key: "a")
        XCTAssertEqual(outbox.nextChunk(maxLength: 2), Data([3, 3]))
        outbox.chunkSent()
        XCTAssertEqual(outbox.nextChunk(maxLength: 2), Data([3, 3]))
        outbox.chunkSent()
        XCTAssertEqual(outbox.nextChunk(maxLength: 2), Data([2]))
        outbox.chunkSent()
        XCTAssertEqual(outbox.nextChunk(maxLength: 0), Data([4]))
        outbox.chunkSent()
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertNil(outbox.nextChunk(maxLength: 2))
    }

    func testPacketRoundTrip() throws {
        let original = packet(update(label: "Gateway", role: "gateway", accuracyMeters: 1.5))
        let decoded = try MeshPacket.decode(original.encoded())
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.frameId, original.frameId)
        XCTAssertEqual(decoded.hopsRemaining, 8)
        XCTAssertEqual(decoded.update, original.update)
    }

    func testPacketValidationAndDecodeValidation() throws {
        for invalid in [
            packet(update(), hops: -1), packet(update(), hops: 9),
            packet(update(), frame: ""),
            packet(update(), frame: String(repeating: "x", count: 129)),
            packet(update(role: "bad"))
        ] {
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertThrowsError(try invalid.encoded())
            let data = try JSONEncoder().encode(invalid)
            XCTAssertThrowsError(try MeshPacket.decode(data))
        }
        try packet(update(), hops: 0).validate()
        try packet(update(), frame: String(repeating: "x", count: 128)).validate()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: packet(update()).encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try MeshPacket.decode(unsupported))
        object["schemaVersion"] = nil
        XCTAssertThrowsError(try MeshPacket.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try MeshPacket.decode(Data("not json".utf8)))
    }

    func testDecodeSizeLimitIncludesExactBoundary() throws {
        let data = try packet(update()).encoded()
        var atLimit = data
        atLimit.append(Data(repeating: 32, count: 4_096 - data.count))
        XCTAssertEqual(try MeshPacket.decode(atLimit).update, update())
        atLimit.append(32)
        XCTAssertThrowsError(try MeshPacket.decode(atLimit)) { error in
            XCTAssertEqual(error as? MeshCoreError, .packetTooLarge)
        }
    }

    func testDuplicateAndOutOfOrderUpdatesDoNotAlterRelay() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            let newest = update(sequence: 5)
            XCTAssertEqual(try store.ingest(packet(newest))?.hopsRemaining, 7)
            XCTAssertNil(try store.ingest(packet(newest, hops: 0)))
            XCTAssertNil(try store.ingest(packet(update(sequence: 4))))
            XCTAssertEqual(store.latest["device"], newest)
            XCTAssertEqual(store.relayPackets["device"]?.hopsRemaining, 7)
            XCTAssertEqual(try store.ingest(packet(update(sequence: 6)))?.update.sequence, 6)
        }
    }

    func testRetiredEpochsCannotReturnEvenWithHigherSequence() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            _ = try store.ingest(packet(update(sequence: 100)))
            let current = update(epochId: nextEpoch, sequence: 0)
            _ = try store.ingest(packet(current))
            XCTAssertNil(try store.ingest(packet(update(sequence: 101))))
            XCTAssertNil(try store.ingest(packet(update(epochId: epoch.lowercased(), sequence: 102))))
            XCTAssertEqual(store.latest["device"], current)
            XCTAssertEqual(store.relayPackets["device"]?.update, current)
        }
    }

    func testEpochIdentityIsCaseInsensitive() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            _ = try store.ingest(packet(update(sequence: 5)))
            XCTAssertNil(try store.ingest(packet(update(epochId: epoch.lowercased(), sequence: 4))))
            XCTAssertNotNil(try store.ingest(packet(update(epochId: epoch.lowercased(), sequence: 6))))
        }
    }

    func testTTLAndAntiEntropyCacheNeverResetHops() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            let peer = MeshStore(frameId: "frame")
            let relay = try XCTUnwrap(store.ingest(packet(update(), hops: 1)))
            XCTAssertEqual(relay.hopsRemaining, 0)
            for _ in 0..<3 {
                let cached = try XCTUnwrap(store.relayPackets["device"])
                XCTAssertEqual(cached.hopsRemaining, 0)
                XCTAssertNil(try peer.ingest(MeshPacket.decode(cached.encoded())))
                XCTAssertTrue(peer.relayPackets.isEmpty)
                XCTAssertEqual(peer.latest["device"], update())
            }
            let exhausted = update(sequence: 1)
            XCTAssertNil(try store.ingest(packet(exhausted, hops: 0)))
            XCTAssertEqual(store.latest["device"], exhausted)
            XCTAssertTrue(store.relayPackets.isEmpty)
            XCTAssertNil(try store.ingest(packet(exhausted, hops: 8)))
            XCTAssertTrue(store.relayPackets.isEmpty)
        }
    }

    func testFrameAndInvalidPacketsDoNotMutateStore() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            _ = try store.ingest(packet(update()))
            XCTAssertThrowsError(try store.ingest(packet(update(sequence: 1), frame: "other"))) {
                XCTAssertEqual($0 as? MeshCoreError, .frameMismatch)
            }
            XCTAssertThrowsError(try store.ingest(packet(update(sequence: 1), hops: 9)))
            XCTAssertEqual(store.latest["device"]?.sequence, 0)
            XCTAssertEqual(store.relayPackets["device"]?.update.sequence, 0)
        }
    }

    func testOneHundredDevicesAndCapacityRejection() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            for index in 0..<100 {
                _ = try store.ingest(packet(update(id: "device-\(index)")))
            }
            XCTAssertEqual(store.latest.count, 100)
            XCTAssertEqual(store.relayPackets.count, 100)
            XCTAssertThrowsError(try store.ingest(packet(update(id: "overflow")))) {
                XCTAssertEqual($0 as? MeshCoreError, .deviceCapacityReached)
            }
            XCTAssertNil(store.latest["overflow"])
            XCTAssertNil(store.relayPackets["overflow"])
            XCTAssertNotNil(try store.ingest(packet(update(id: "device-0", sequence: 1))))
            XCTAssertEqual(store.latest.count, 100)
        }
    }

    func testEpochCapacityPreservesRetiredEpochsAndCurrentUpdates() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            _ = try store.ingest(packet(update()))
            var currentEpoch = epoch
            for _ in 1..<100 {
                currentEpoch = UUID().uuidString
                _ = try store.ingest(packet(update(epochId: currentEpoch)))
            }
            XCTAssertThrowsError(try store.ingest(packet(update(epochId: nextEpoch)))) {
                XCTAssertEqual($0 as? MeshCoreError, .epochCapacityReached)
            }
            XCTAssertEqual(store.latest["device"]?.epochId, currentEpoch)
            XCTAssertNil(try store.ingest(packet(update(sequence: 999))))
            XCTAssertNotNil(try store.ingest(packet(update(epochId: currentEpoch, sequence: 1))))
            XCTAssertEqual(store.relayPackets["device"]?.update.sequence, 1)
        }
    }

    func testResetClearsLatestRelaysAndEpochHistory() throws {
        try onMain {
            let store = MeshStore(frameId: "frame")
            _ = try store.ingest(packet(update()))
            _ = try store.ingest(packet(update(epochId: nextEpoch)))
            store.reset(frameId: "new-frame")
            XCTAssertTrue(store.latest.isEmpty)
            XCTAssertTrue(store.relayPackets.isEmpty)
            XCTAssertThrowsError(try store.ingest(packet(update())))
            XCTAssertNotNil(try store.ingest(packet(update(), frame: "new-frame")))
        }
    }

    func testRSSIInitialStateAndInvalidValues() {
        var stats = RSSIStatistics()
        XCTAssertNil(stats.raw)
        XCTAssertNil(stats.smoothed)
        XCTAssertNil(stats.standardDeviation)
        XCTAssertEqual(stats.sampleCount, 0)
        for value in [127, -128, 21, Int.min, Int.max] {
            XCTAssertFalse(stats.record(value))
        }
        XCTAssertNil(stats.raw)
        XCTAssertNil(stats.smoothed)
        XCTAssertNil(stats.standardDeviation)
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertTrue(stats.record(-80))
        XCTAssertFalse(stats.record(127))
        XCTAssertEqual(stats.raw, -80)
        XCTAssertEqual(stats.smoothed, -80)
        XCTAssertEqual(stats.standardDeviation, 0)
        XCTAssertEqual(stats.sampleCount, 1)
    }

    func testRSSIEMAAndPopulationDeviation() throws {
        var stats = RSSIStatistics()
        XCTAssertTrue(stats.record(-80))
        XCTAssertTrue(stats.record(-60))
        XCTAssertEqual(stats.raw, -60)
        XCTAssertEqual(try XCTUnwrap(stats.smoothed), -75, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(stats.standardDeviation), 10, accuracy: 0.000001)
        XCTAssertTrue(stats.record(-60))
        XCTAssertEqual(try XCTUnwrap(stats.smoothed), -71.25, accuracy: 0.000001)
        XCTAssertEqual(stats.sampleCount, 3)
    }

    func testRSSIBoundedWindowAndInclusiveRange() throws {
        var stats = RSSIStatistics()
        XCTAssertTrue(stats.record(-127))
        XCTAssertTrue(stats.record(20))
        for _ in 0..<20 { XCTAssertTrue(stats.record(-60)) }
        XCTAssertEqual(stats.sampleCount, 22)
        XCTAssertEqual(try XCTUnwrap(stats.standardDeviation), 0, accuracy: 0.000001)
        XCTAssertTrue(stats.record(-80))
        XCTAssertEqual(try XCTUnwrap(stats.standardDeviation), sqrt(19), accuracy: 0.000001)
    }
}
