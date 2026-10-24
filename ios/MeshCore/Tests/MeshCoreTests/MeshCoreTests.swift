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
        accuracyMeters: Double? = nil,
        neighbors: [NeighborObservation]? = nil
    ) -> DeviceUpdate {
        DeviceUpdate(
            id: id, label: label, epochId: epochId ?? epoch, sequence: sequence,
            role: role, position: position, positionMode: positionMode,
            accuracyMeters: accuracyMeters, neighbors: neighbors
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

    func testValidationMatchesDashboardContract() throws {
        // Each of these would make the dashboard reject the gateway's whole batch.
        let invalid = [
            update(id: String(repeating: "x", count: 65)),
            update(id: " padded"),
            update(label: String(repeating: "x", count: 41)),
            update(label: String(repeating: "📡", count: 21)),
            update(position: Position(x: 10_000.1, y: 0, z: 0)),
            update(position: Position(x: 0, y: 0, z: -10_000.1)),
            update(accuracyMeters: 1_000.1)
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.validate())
        }
        try update(
            label: String(repeating: "📡", count: 20),
            position: Position(x: 10_000, y: -10_000, z: 10_000),
            accuracyMeters: 1_000
        ).validate()
    }

    func testNeighborValidation() throws {
        let valid = NeighborObservation(id: "peer", rssi: -60, ageMs: 250)
        try update(neighbors: []).validate()
        try update(neighbors: [valid, NeighborObservation(id: "other")]).validate()
        try update(neighbors: (0..<16).map { NeighborObservation(id: "peer-\($0)") }).validate()

        let invalid: [[NeighborObservation]] = [
            (0..<17).map { NeighborObservation(id: "peer-\($0)") },
            [NeighborObservation(id: "")],
            [NeighborObservation(id: String(repeating: "x", count: 65))],
            [NeighborObservation(id: "device")],
            [valid, valid],
            [NeighborObservation(id: "peer", rssi: -128)],
            [NeighborObservation(id: "peer", rssi: 21)],
            [NeighborObservation(id: "peer", ageMs: -1)],
            [NeighborObservation(id: "peer", ageMs: 86_400_001)]
        ]
        for neighbors in invalid {
            XCTAssertThrowsError(try update(neighbors: neighbors).validate())
        }
    }

    func testNeighborsRoundTripAndAreOptionalOnTheWire() throws {
        let withNeighbors = packet(update(neighbors: [NeighborObservation(id: "peer", rssi: -60)]))
        XCTAssertEqual(try MeshPacket.decode(withNeighbors.encoded()).update, withNeighbors.update)

        // Packets from app builds without the field still decode, and nil is omitted on encode.
        let legacy = try packet(update()).encoded()
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("neighbors"))
        XCTAssertNil(try MeshPacket.decode(legacy).update.neighbors)
    }

    func testLabelTruncationCountsUTF16Units() {
        XCTAssertEqual(DashboardContract.truncatedLabel("short"), "short")
        XCTAssertEqual(DashboardContract.truncatedLabel(String(repeating: "x", count: 50)).utf16.count, 40)
        let emoji = DashboardContract.truncatedLabel(String(repeating: "📡", count: 30))
        XCTAssertEqual(emoji, String(repeating: "📡", count: 20))
        // A character that would straddle the limit is dropped whole, never split.
        XCTAssertEqual(DashboardContract.truncatedLabel(String(repeating: "x", count: 39) + "📡"),
                       String(repeating: "x", count: 39))
    }

    func testPacketRoundTrip() throws {
        let original = packet(update(label: "Gateway", role: "gateway", accuracyMeters: 1.5))
        let decoded = try MeshPacket.decode(original.encoded())
        XCTAssertEqual(decoded.schemaVersion, MeshProtocol.version)
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
        object["schemaVersion"] = 1
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
            _ = try store.ingest(packet(update(sequence: 5)))
            XCTAssertNil(try store.ingest(packet(update(epochId: epoch.lowercased(), sequence: 4))))
            XCTAssertNotNil(try store.ingest(packet(update(epochId: epoch.lowercased(), sequence: 6))))
        }
    }

    func testTTLAndAntiEntropyCacheNeverResetHops() throws {
        try onMain {
            let store = MeshStore(frameId: "frame", selfId: "self")
            let peer = MeshStore(frameId: "frame", selfId: "peer")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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
            let store = MeshStore(frameId: "frame", selfId: "self")
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

    func testRSSITimeBasedSmoothingAndPopulationDeviation() throws {
        let start = Date()
        var stats = RSSIStatistics()
        XCTAssertTrue(stats.record(-80, at: start))
        XCTAssertTrue(stats.record(-60, at: start.addingTimeInterval(RSSIStatistics.timeConstant)))
        XCTAssertEqual(stats.raw, -60)
        // One time constant closes 1 - 1/e of the gap.
        XCTAssertEqual(try XCTUnwrap(stats.smoothed), -60 - 20 * exp(-1), accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(stats.standardDeviation), 10, accuracy: 0.000001)
        // A sample with no elapsed time does not move the average.
        let before = try XCTUnwrap(stats.smoothed)
        XCTAssertTrue(stats.record(-60, at: start.addingTimeInterval(RSSIStatistics.timeConstant)))
        XCTAssertEqual(try XCTUnwrap(stats.smoothed), before, accuracy: 0.000001)
        XCTAssertEqual(stats.sampleCount, 3)
    }

    func testRSSISmoothingDoesNotDependOnSampleRate() throws {
        let start = Date()
        var sparse = RSSIStatistics()
        var dense = RSSIStatistics()
        sparse.record(-80, at: start)
        dense.record(-80, at: start)
        sparse.record(-60, at: start.addingTimeInterval(3))
        for second in 1...3 { dense.record(-60, at: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(try XCTUnwrap(sparse.smoothed), try XCTUnwrap(dense.smoothed), accuracy: 0.000001)
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

    // MARK: Relay path

    func testRelayPathGrowsPerHopAndOwnReportsLeaveEmpty() throws {
        try onMain {
            let origin = MeshStore(frameId: "frame", selfId: "device")
            let b = MeshStore(frameId: "frame", selfId: "b")
            let c = MeshStore(frameId: "frame", selfId: "c")
            let own = try XCTUnwrap(origin.ingest(packet(update(), hops: 5)))
            XCTAssertEqual(own.path, [])
            XCTAssertEqual(own.hopsRemaining, 4)
            let viaB = try XCTUnwrap(b.ingest(MeshPacket.decode(own.encoded())))
            XCTAssertEqual(viaB.path, ["b"])
            let viaC = try XCTUnwrap(c.ingest(MeshPacket.decode(viaB.encoded())))
            XCTAssertEqual(viaC.path, ["b", "c"])
            XCTAssertEqual(viaC.hopsRemaining, 2)
            XCTAssertEqual(viaC.update, update())
            // Resending the cached relay never changes its path.
            XCTAssertEqual(c.relayPackets["device"]?.path, ["b", "c"])
        }
    }

    func testPacketThatAlreadyPassedThroughThisPhoneIsDropped() throws {
        try onMain {
            let store = MeshStore(frameId: "frame", selfId: "b")
            let looped = MeshPacket(frameId: "frame", hopsRemaining: 4, update: update(), path: ["b", "c"])
            XCTAssertNil(try store.ingest(looped))
            XCTAssertNil(store.latest["device"])
            XCTAssertNil(store.receivedAt["device"])
        }
    }

    func testRelayStopsWhenPathIsFull() throws {
        try onMain {
            let store = MeshStore(frameId: "frame", selfId: "self")
            let full = (1...MeshProtocol.maxPathLength).map { "relay-\($0)" }
            XCTAssertNil(try store.ingest(MeshPacket(frameId: "frame", hopsRemaining: 8, update: update(), path: full)))
            XCTAssertEqual(store.latest["device"], update())
            XCTAssertNil(store.relayPackets["device"])
        }
    }

    func testInvalidPathsAreRejected() {
        let paths: [[String]] = [
            (0...MeshProtocol.maxPathLength).map { "relay-\($0)" },
            ["b", "b"],
            ["device"],
            [""],
            [String(repeating: "x", count: 65)]
        ]
        for path in paths {
            XCTAssertThrowsError(try MeshPacket(frameId: "frame", hopsRemaining: 4, update: update(), path: path).validate())
        }
    }

    func testFreshnessUsesLocalReceiveTime() throws {
        try onMain {
            let store = MeshStore(frameId: "frame", selfId: "self")
            let start = Date()
            _ = try store.ingest(packet(update()), at: start)
            XCTAssertTrue(store.isFresh("device", within: 30, at: start.addingTimeInterval(30)))
            XCTAssertFalse(store.isFresh("device", within: 30, at: start.addingTimeInterval(31)))
            XCTAssertFalse(store.isFresh("unknown", within: 30, at: start))
            // A duplicate does not refresh the receive time.
            XCTAssertNil(try store.ingest(packet(update()), at: start.addingTimeInterval(20)))
            XCTAssertEqual(store.receivedAt["device"], start)
        }
    }

    // MARK: Hello

    func testHelloRoundTripAndValidation() throws {
        let hello = Hello(frameId: "frame", deviceId: "device", label: "Phone 📡")
        XCTAssertEqual(hello.protocolVersion, MeshProtocol.version)
        XCTAssertEqual(try Hello.decode(hello.encoded()), hello)
        for invalid in [
            Hello(frameId: "", deviceId: "device", label: nil),
            Hello(frameId: "frame", deviceId: "", label: nil),
            Hello(frameId: "frame", deviceId: String(repeating: "x", count: 65), label: nil),
            Hello(frameId: "frame", deviceId: "device", label: String(repeating: "x", count: 41))
        ] {
            XCTAssertThrowsError(try invalid.encoded())
        }
        XCTAssertThrowsError(try Hello.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try Hello.decode(Data(repeating: 32, count: Hello.maxEncodedSize + 1)))
    }

    // MARK: Framing

    func testFramesSurviveArbitraryChunking() throws {
        let hello = try Hello(frameId: "frame", deviceId: "device", label: nil).encoded()
        let position = try packet(update()).encoded()
        let stream = try XCTUnwrap(Framing.encode(hello, type: .hello)) + XCTUnwrap(Framing.encode(position, type: .position))
        for size in [1, 7, 20, 182, stream.count] {
            var assembler = FrameAssembler()
            var frames: [Frame] = []
            for start in stride(from: 0, to: stream.count, by: size) {
                frames += try assembler.append(stream.subdata(in: start..<min(start + size, stream.count)))
            }
            XCTAssertEqual(frames, [Frame(type: .hello, payload: hello), Frame(type: .position, payload: position)])
            XCTAssertFalse(assembler.hasPartialFrame)
        }
    }

    func testMalformedFramesAreRejectedAndTheAssemblerRecovers() throws {
        let valid = try XCTUnwrap(Framing.encode(Data("ok".utf8), type: .position))
        let malformed: [Data] = [
            Data([0, 0, 0, 0, 2]) + Data("ok".utf8),   // type 0: also how a version 1 length prefix starts
            Data([2, 0, 0, 0, 0]),                     // empty payload
            Data([2, 0, 0, 0x10, 0x01]),               // 4,097-byte payload
            Data([2, 0, 0, 0x10, 0]) + Data(repeating: 0, count: 8_200)  // over the buffer limit
        ]
        for data in malformed {
            var assembler = FrameAssembler()
            XCTAssertThrowsError(try assembler.append(data)) {
                XCTAssertEqual($0 as? MeshCoreError, .invalidFrame)
            }
            XCTAssertFalse(assembler.hasPartialFrame)
            XCTAssertEqual(try assembler.append(valid), [Frame(type: .position, payload: Data("ok".utf8))])
        }
        XCTAssertNil(Framing.encode(Data(), type: .position))
        XCTAssertNil(Framing.encode(Data(repeating: 0, count: Framing.maxPayload + 1), type: .position))
        XCTAssertNotNil(Framing.encode(Data(repeating: 0, count: Framing.maxPayload), type: .position))
    }

    func testPartialFrameExpires() throws {
        let start = Date()
        let framed = try XCTUnwrap(Framing.encode(Data("payload".utf8), type: .position))
        var assembler = FrameAssembler()
        XCTAssertEqual(try assembler.append(framed.prefix(3), at: start), [])
        XCTAssertFalse(assembler.expire(at: start.addingTimeInterval(FrameAssembler.timeout)))
        XCTAssertTrue(assembler.hasPartialFrame)
        XCTAssertTrue(assembler.expire(at: start.addingTimeInterval(FrameAssembler.timeout + 0.1)))
        XCTAssertFalse(assembler.hasPartialFrame)
        XCTAssertEqual(try assembler.append(framed), [Frame(type: .position, payload: Data("payload".utf8))])
    }

    func testUnknownFrameTypesAreSkipped() throws {
        let known = try XCTUnwrap(Framing.encode(Data("ok".utf8), type: .position))
        var assembler = FrameAssembler()
        let frames = try assembler.append(Data([9, 0, 0, 0, 3]) + Data("new".utf8) + known)
        XCTAssertEqual(frames, [Frame(type: .position, payload: Data("ok".utf8))])
        XCTAssertFalse(assembler.hasPartialFrame)
    }

    // MARK: Ranging

    private func assertClose(_ a: Position?, _ b: Position, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil position", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    private func rangingFix(heading: Double, gravity: Vector3 = AnchorGeometry.upright, direction: Vector3,
                            distance: Double = 2, floor: Bool = false) -> RangingFix? {
        AnchorGeometry.fix(anchorId: "anchor", targetId: "target", anchor: Position(x: 10, y: 1, z: 20),
                           headingDegrees: heading, gravity: gravity, distance: distance, direction: direction, floor: floor)
    }

    func testUprightAnchorMapsDeviceAxesByHeading() {
        let behind = Vector3(0, 0, -1), right = Vector3(1, 0, 0), up = Vector3(0, 1, 0)
        // Heading 0: the back faces map +z and the screen's right is map +x.
        assertClose(rangingFix(heading: 0, direction: behind)?.position, Position(x: 10, y: 1, z: 22))
        assertClose(rangingFix(heading: 0, direction: right)?.position, Position(x: 12, y: 1, z: 20))
        assertClose(rangingFix(heading: 0, direction: up)?.position, Position(x: 10, y: 3, z: 20))
        // Heading 90: the back faces map +x, so the screen's right is map -z.
        assertClose(rangingFix(heading: 90, direction: behind)?.position, Position(x: 12, y: 1, z: 20))
        assertClose(rangingFix(heading: 90, direction: right)?.position, Position(x: 10, y: 1, z: 18))
        assertClose(rangingFix(heading: 180, direction: behind)?.position, Position(x: 10, y: 1, z: 18))
        assertClose(rangingFix(heading: -90, direction: behind)?.position, Position(x: 8, y: 1, z: 20))
    }

    func testGravityCorrectsPitch() {
        // Tilted so the screen faces 30° downwards: gravity gains a +z (out of the screen) part and the back points 30° up.
        let pitch = 30.0 * .pi / 180
        let gravity = Vector3(0, -cos(pitch), sin(pitch))
        let behind = Vector3(0, 0, -1)
        let level = Vector3(0, -sin(pitch), -cos(pitch))   // a horizontal ray straight ahead, in device axes
        assertClose(rangingFix(heading: 0, gravity: gravity, direction: level)?.position, Position(x: 10, y: 1, z: 22))
        assertClose(rangingFix(heading: 0, gravity: gravity, direction: behind)?.position,
                    Position(x: 10, y: 1 + 2 * sin(pitch), z: 20 + 2 * cos(pitch)))
    }

    func testFlatPhoneFloorModeAndInvalidMeasurements() {
        let behind = Vector3(0, 0, -1)
        XCTAssertNil(rangingFix(heading: 0, gravity: Vector3(0, 0, 1), direction: behind), "lying flat: heading undefined")
        XCTAssertNil(rangingFix(heading: 0, direction: Vector3(0, 0, 0)))
        XCTAssertNil(rangingFix(heading: .nan, direction: behind))
        XCTAssertNil(rangingFix(heading: 0, direction: behind, distance: -1))
        XCTAssertNil(rangingFix(heading: 0, direction: behind, distance: .infinity))
        assertClose(rangingFix(heading: 0, direction: Vector3(0, 1, -1), distance: 2, floor: true)?.position,
                    Position(x: 10, y: 0, z: 20 + 2.0.squareRoot()))
        // Non-unit directions are normalized.
        assertClose(rangingFix(heading: 0, direction: Vector3(0, 0, -5))?.position, Position(x: 10, y: 1, z: 22))
    }

    func testAccuracyGrowsWithDistance() throws {
        XCTAssertEqual(AnchorGeometry.accuracy(distance: 0), AnchorGeometry.baseErrorMeters)
        let near = AnchorGeometry.accuracy(distance: 2), far = AnchorGeometry.accuracy(distance: 8)
        XCTAssertLessThan(near, far)
        XCTAssertEqual(far, 8 * sin(15 * .pi / 180) + 0.3, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(rangingFix(heading: 0, direction: Vector3(0, 0, -1), distance: 8)).accuracyMeters, far)
    }

    func testRangingMessagesRoundTripAndValidate() throws {
        let fix = try XCTUnwrap(rangingFix(heading: 0, direction: Vector3(0, 0, -1)))
        XCTAssertEqual(try RangingFix.decode(fix.encoded()), fix)
        for invalid in [
            RangingFix(anchorId: "a", targetId: "a", position: Position(x: 0, y: 0, z: 0), accuracyMeters: 1, distanceMeters: 1),
            RangingFix(anchorId: "a", targetId: "b", position: Position(x: 10_001, y: 0, z: 0), accuracyMeters: 1, distanceMeters: 1),
            RangingFix(anchorId: "a", targetId: "b", position: Position(x: 0, y: 0, z: 0), accuracyMeters: 1_001, distanceMeters: 1),
            RangingFix(anchorId: "a", targetId: "b", position: Position(x: 0, y: 0, z: 0), accuracyMeters: 1, distanceMeters: -1)
        ] {
            XCTAssertThrowsError(try invalid.encoded())
        }
        let token = RangingToken(token: Data([1, 2, 3]), isAnchor: true)
        XCTAssertEqual(try RangingToken.decode(token.encoded()), token)
        XCTAssertThrowsError(try RangingToken(token: Data(), isAnchor: false).encoded())
        XCTAssertThrowsError(try RangingToken(token: Data(count: RangingToken.maxTokenSize + 1), isAnchor: false).encoded())
    }

    // MARK: Link outbox

    private func drain(_ outbox: inout LinkOutbox, maxLength: Int) -> [Data] {
        var sent: [Data] = []
        while let chunk = outbox.nextChunk(maxLength: maxLength) {
            sent.append(chunk)
            outbox.chunkSent()
        }
        return sent
    }

    func testOutboxReplacesQueuedMessageWithSameKey() {
        var outbox = LinkOutbox()
        outbox.enqueue(Data("old-a".utf8), key: "a")
        outbox.enqueue(Data("b".utf8), key: "b")
        outbox.enqueue(Data("new-a".utf8), key: "a")
        XCTAssertEqual(outbox.pendingCount, 2)
        // The replacement keeps the original place in line.
        XCTAssertEqual(drain(&outbox, maxLength: 100), [Data("new-a".utf8), Data("b".utf8)])
        XCTAssertTrue(outbox.isEmpty)
    }

    func testOutboxFinishesTransferInProgressBeforeReplacement() {
        var outbox = LinkOutbox()
        outbox.enqueue(Data("abcdef".utf8), key: "a")
        XCTAssertEqual(outbox.nextChunk(maxLength: 4), Data("abcd".utf8))
        outbox.chunkSent()
        outbox.enqueue(Data("XYZ".utf8), key: "a")
        XCTAssertEqual(drain(&outbox, maxLength: 4), [Data("ef".utf8), Data("XYZ".utf8)])
    }

    func testOutboxChunksRespectMaxLength() {
        var outbox = LinkOutbox()
        let message = Data((0..<50).map { UInt8($0) })
        outbox.enqueue(message, key: "a")
        let chunks = drain(&outbox, maxLength: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 10])
        XCTAssertEqual(chunks.reduce(Data(), +), message)
        // A chunk is removed only once sent, so an unsent chunk is offered again unchanged.
        outbox.enqueue(message, key: "a")
        let first = outbox.nextChunk(maxLength: 20)
        let again = outbox.nextChunk(maxLength: 20)
        XCTAssertEqual(first, again)
    }

    func testGeoFrameConvertsGPSToEastNorthMeters() throws {
        let origin = try XCTUnwrap(GeoFrame.origins[GeoFrame.defaultFrameId])
        let atOrigin = try XCTUnwrap(GeoFrame.position(frameId: GeoFrame.defaultFrameId,
                                                       latitude: origin.latitude, longitude: origin.longitude))
        XCTAssertEqual(atOrigin, Position(x: 0, y: 0, z: 0))
        // 0.001° north is about 111 m; 0.002° east at 61.45° N is about 106 m.
        let moved = try XCTUnwrap(GeoFrame.position(frameId: GeoFrame.defaultFrameId,
                                                    latitude: origin.latitude + 0.001, longitude: origin.longitude + 0.002))
        XCTAssertEqual(moved.z, 111.2, accuracy: 0.5)
        XCTAssertEqual(moved.x, 106.3, accuracy: 0.5)
        XCTAssertEqual(moved.y, 0)
        try update(position: moved, positionMode: "floor").validate()
    }

    func testGeoFrameCoordinateIsTheInverse() throws {
        let p = try XCTUnwrap(GeoFrame.position(frameId: GeoFrame.defaultFrameId, latitude: 61.4512, longitude: 23.8601))
        let back = try XCTUnwrap(GeoFrame.coordinate(frameId: GeoFrame.defaultFrameId, x: p.x, z: p.z))
        XCTAssertEqual(back.latitude, 61.4512, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, 23.8601, accuracy: 1e-9)
        XCTAssertNil(GeoFrame.coordinate(frameId: "demo-room-v1", x: 0, z: 0))
    }

    func testGeoFrameRejectsUnknownFramesAndFarFixes() {
        XCTAssertNil(GeoFrame.position(frameId: "demo-room-v1", latitude: 61.4499, longitude: 23.856))
        // Helsinki is ~150 km away, outside the dashboard's ±10 km limit.
        XCTAssertNil(GeoFrame.position(frameId: GeoFrame.defaultFrameId, latitude: 60.17, longitude: 24.94))
    }

    func testPositionSourceRoundTripsAndIsOptionalOnTheWire() throws {
        for source in PositionSource.allCases {
            let value = DeviceUpdate(id: "device", epochId: epoch, sequence: 1, role: "mobile",
                                     position: Position(x: 0, y: 0, z: 0), positionMode: "floor",
                                     positionSource: source)
            let decoded = try MeshPacket.decode(try packet(value).encoded())
            XCTAssertEqual(decoded.update.positionSource, source)
        }
        // Reports from builds without the field still decode, as manual positions.
        let legacy = try MeshPacket.decode(try packet(update()).encoded())
        XCTAssertNil(legacy.update.positionSource)
        let unknown = #"{"schemaVersion":\#(MeshProtocol.version),"frameId":"frame","hopsRemaining":3,"path":[],"#
            + #""update":{"id":"d","epochId":"\#(epoch)","sequence":1,"role":"mobile","#
            + #""position":{"x":0,"y":0,"z":0},"positionMode":"floor","positionSource":"guess"}}"#
        XCTAssertThrowsError(try MeshPacket.decode(Data(unknown.utf8)))
    }

    // MARK: UWB neighbor fields (wire version 4)

    func testNeighborUWBFieldsRoundTripRoundedAndOptional() throws {
        let neighbor = NeighborObservation(id: "peer", rssi: -60, ageMs: 100, uwbDistanceM: 3.4167,
                                           uwbBearingDeg: 359.7, uwbBearingErrorDeg: 18.03)
        XCTAssertEqual(neighbor.uwbDistanceM, 3.42)
        XCTAssertEqual(neighbor.uwbBearingDeg, 0)
        XCTAssertEqual(neighbor.uwbBearingErrorDeg, 18)
        let value = packet(update(neighbors: [neighbor, NeighborObservation(id: "other", uwbDistanceM: 12)]))
        let data = try value.encoded()
        XCTAssertEqual(try MeshPacket.decode(data).update, value.update)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""uwbDistanceM":3.42"#))
        XCTAssertTrue(text.contains("uwbBearingErrorDeg"))

        // Absent fields are omitted and decode as nil, so reports without UWB look as before.
        let plain = try packet(update(neighbors: [NeighborObservation(id: "peer", rssi: -60)])).encoded()
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("uwb"))
        XCTAssertNil(try MeshPacket.decode(plain).update.neighbors?.first?.uwbDistanceM)
    }

    func testNeighborUWBValidationBounds() throws {
        try update(neighbors: [NeighborObservation(id: "peer", uwbDistanceM: 0)]).validate()
        try update(neighbors: [NeighborObservation(id: "peer", uwbDistanceM: DashboardContract.maxUWBDistanceMeters)]).validate()
        try update(neighbors: [NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingDeg: 270)]).validate()
        try update(neighbors: [NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingDeg: 90, uwbBearingErrorDeg: 180)]).validate()
        XCTAssertEqual(DashboardContract.maxUWBDistanceMeters, 200)

        let invalid: [NeighborObservation] = [
            NeighborObservation(id: "peer", uwbDistanceM: 200.01),
            NeighborObservation(id: "peer", uwbDistanceM: -0.5),
            NeighborObservation(id: "peer", uwbDistanceM: .nan),
            NeighborObservation(id: "peer", uwbDistanceM: .infinity),
            NeighborObservation(id: "peer", uwbBearingDeg: 90),
            NeighborObservation(id: "peer", uwbBearingDeg: 90, uwbBearingErrorDeg: 10),
            NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingErrorDeg: 10),
            NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingDeg: .nan),
            NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingDeg: 90, uwbBearingErrorDeg: 0.4),
            NeighborObservation(id: "peer", uwbDistanceM: 5, uwbBearingDeg: 90, uwbBearingErrorDeg: 181)
        ]
        for neighbor in invalid {
            XCTAssertThrowsError(try update(neighbors: [neighbor]).validate())
        }
        // Values that bypass the rounding initializer are still checked on decode.
        let raw = #"{"schemaVersion":\#(MeshProtocol.version),"frameId":"frame","hopsRemaining":3,"path":[],"#
            + #""update":{"id":"d","epochId":"\#(epoch)","sequence":1,"role":"mobile","#
            + #""position":{"x":0,"y":0,"z":0},"positionMode":"floor","#
            + #""neighbors":[{"id":"p","uwbDistanceM":4,"uwbBearingDeg":360,"uwbBearingErrorDeg":20}]}}"#
        XCTAssertThrowsError(try MeshPacket.decode(Data(raw.utf8)))
    }

    func testVersion3PacketsAreRejected() throws {
        XCTAssertEqual(MeshProtocol.version, 4)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: packet(update()).encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 3
        XCTAssertThrowsError(try MeshPacket.decode(JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? MeshCoreError, .invalidPacket)
        }
        XCTAssertEqual(Hello(frameId: "frame", deviceId: "a", label: nil).protocolVersion, 4)
    }

    func testFullNeighborListWithUWBFitsOnePacket() throws {
        let neighbors = (0..<DashboardContract.maxNeighbors).map { _ in
            NeighborObservation(id: UUID().uuidString, rssi: -100, ageMs: 86_400_000,
                                uwbDistanceM: 123.45, uwbBearingDeg: 359, uwbBearingErrorDeg: 180)
        }
        let report = DeviceUpdate(id: UUID().uuidString, label: String(repeating: "x", count: 40),
                                  epochId: epoch, sequence: 9_007_199_254_740_991, role: "gateway",
                                  position: Position(x: -9_999.123456, y: 0, z: -9_999.123456), positionMode: "floor",
                                  accuracyMeters: 999.123456, neighbors: neighbors, positionSource: PositionSource.none)
        let path = (0..<MeshProtocol.maxPathLength).map { _ in UUID().uuidString }
        let data = try MeshPacket(frameId: String(repeating: "f", count: 64), hopsRemaining: 8, update: report, path: path).encoded()
        XCTAssertLessThanOrEqual(data.count, Framing.maxPayload)
    }

    // MARK: Ranging token

    func testRangingTokenCarriesDirectionAndDecodesWithoutIt() throws {
        let token = RangingToken(token: Data([1, 2, 3]), isAnchor: false, uwbDirection: true)
        XCTAssertEqual(try RangingToken.decode(token.encoded()), token)
        XCTAssertFalse(RangingToken(token: Data([1]), isAnchor: true).uwbDirection)
        // A version 3 sender has no `uwbDirection`.
        let legacy = try RangingToken.decode(Data(#"{"token":"AQID","isAnchor":true}"#.utf8))
        XCTAssertEqual(legacy, RangingToken(token: Data([1, 2, 3]), isAnchor: true, uwbDirection: false))
        XCTAssertThrowsError(try RangingToken.decode(Data(#"{"token":"AQID"}"#.utf8)))
    }

    // MARK: Peer bearing

    /// Attitude whose rows are the device x, y and z axes in the `.xTrueNorthZVertical` reference
    /// frame (x north, y west, z up), the convention `RotationMatrix` documents.
    private func attitude(x: Vector3, y: Vector3, z: Vector3) -> RotationMatrix {
        RotationMatrix(rows: [[x.x, x.y, x.z], [y.x, y.y, y.z], [z.x, z.y, z.z]])
    }

    private var north: Vector3 { Vector3(1, 0, 0) }
    private var south: Vector3 { Vector3(-1, 0, 0) }
    private var west: Vector3 { Vector3(0, 1, 0) }
    private var east: Vector3 { Vector3(0, -1, 0) }
    private var up: Vector3 { Vector3(0, 0, 1) }

    func testBearingOfUprightPhoneFacingNorth() throws {
        // Upright, screen towards the user, back facing north: right = east, top = up, screen = south.
        let facingNorth = attitude(x: east, y: up, z: south)
        let behind = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: facingNorth, compassErrorDegrees: 10))
        XCTAssertEqual(behind.degrees, 0, accuracy: 1e-9)
        XCTAssertEqual(behind.errorDegrees, (15.0 * 15 + 10 * 10).squareRoot(), accuracy: 1e-9)
        let right = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(1, 0, 0), attitude: facingNorth, compassErrorDegrees: 10))
        XCTAssertEqual(right.degrees, 90, accuracy: 1e-9)
        let left = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(-2, 0, 0), attitude: facingNorth, compassErrorDegrees: 10))
        XCTAssertEqual(left.degrees, 270, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PeerBearing.headingDegrees(attitude: facingNorth)), 0, accuracy: 1e-9)
    }

    func testBearingOfUprightPhoneFacingEast() throws {
        let facingEast = attitude(x: south, y: up, z: west)
        let behind = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: facingEast, compassErrorDegrees: 20))
        XCTAssertEqual(behind.degrees, 90, accuracy: 1e-9)
        XCTAssertEqual(behind.errorDegrees, 25, accuracy: 1e-9)
        let right = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(1, 0, 0), attitude: facingEast, compassErrorDegrees: 20))
        XCTAssertEqual(right.degrees, 180, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PeerBearing.headingDegrees(attitude: facingEast)), 90, accuracy: 1e-9)
    }

    func testBearingOfTiltedPhone() throws {
        // Hand-held at 45° facing east: top = east + up, screen = up + towards the user (west), right = south.
        let r = 0.5.squareRoot()
        let tilted = attitude(x: south, y: Vector3(0, -r, r), z: Vector3(0, r, r))
        let ahead = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: tilted, compassErrorDegrees: 10))
        XCTAssertEqual(ahead.degrees, 90, accuracy: 1e-9)
        // Behind and to the right in the device's x-z plane: between east and south.
        let aside = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(r, 0, -r), attitude: tilted, compassErrorDegrees: 10))
        XCTAssertGreaterThan(aside.degrees, 90)
        XCTAssertLessThan(aside.degrees, 180)
        XCTAssertEqual(try XCTUnwrap(PeerBearing.headingDegrees(attitude: tilted)), 90, accuracy: 1e-9)
    }

    func testFlatPhoneAndUnknownCalibrationGiveNoBearing() throws {
        // Flat, screen up, top north: a peer along the screen normal is straight down or up.
        let flat = attitude(x: east, y: north, z: up)
        XCTAssertNil(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: flat, compassErrorDegrees: 10))
        XCTAssertNil(PeerBearing.bearing(direction: Vector3(0.1, 0, 1), attitude: flat, compassErrorDegrees: 10))
        let top = try XCTUnwrap(PeerBearing.bearing(direction: Vector3(0, 1, 0), attitude: flat, compassErrorDegrees: 10))
        XCTAssertEqual(top.degrees, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PeerBearing.headingDegrees(attitude: flat)), 0, accuracy: 1e-9)
        // Uncalibrated compass and invalid input.
        let upright = attitude(x: east, y: up, z: south)
        XCTAssertNil(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: upright, compassErrorDegrees: nil))
        XCTAssertNil(PeerBearing.bearing(direction: Vector3(0, 0, 0), attitude: upright, compassErrorDegrees: 10))
        XCTAssertNil(PeerBearing.bearing(direction: Vector3(0, 0, -1), attitude: RotationMatrix(rows: [[1, 0, 0]]), compassErrorDegrees: 10))
    }

    func testLinkBearingNormalizesAndReverses() throws {
        XCTAssertEqual(LinkBearing(degrees: -90, errorDegrees: 5).degrees, 270)
        XCTAssertEqual(LinkBearing(degrees: 720, errorDegrees: 5).degrees, 0)
        XCTAssertEqual(LinkBearing(degrees: 30, errorDegrees: 5).reversed, LinkBearing(degrees: 210, errorDegrees: 5))
        XCTAssertEqual(LinkBearing(degrees: 200, errorDegrees: 5).reversed.degrees, 20, accuracy: 1e-9)
        let diagonal = try XCTUnwrap(PeerBearing.bearing(mapDirection: Vector3(1, 0, 1), errorDegrees: 0))
        XCTAssertEqual(diagonal.degrees, 45, accuracy: 1e-9)
        XCTAssertEqual(diagonal.errorDegrees, 1)
    }
}
