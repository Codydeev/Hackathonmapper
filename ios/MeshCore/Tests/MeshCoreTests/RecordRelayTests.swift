import Foundation
import XCTest
import MeshCore

/// Phones running `RecordRelay`, joined by links that come and go. Frames take the real wire path:
/// JSON, `Framing` and `FrameAssembler`.
private final class RecordMesh {
    var now: TimeInterval = 5_000
    private(set) var relays: [String: RecordRelay] = [:]
    private(set) var received: [String: [ReceivedRecord]] = [:]
    private(set) var droppableSends = 0
    private var links = Set<String>()
    private var queue: [(from: String, to: String, framed: Data)] = []

    init(_ ids: [String]) {
        for id in ids { relays[id] = RecordRelay(selfId: id) }
    }

    subscript(_ id: String) -> RecordRelay { relays[id]! }

    func records(_ id: String) -> [RelayMessage] { (received[id] ?? []).map(\.message) }

    func link(_ a: String, _ b: String) {
        links.insert(Self.key(a, b))
        handle(a, self[a].neighborReady(b, now: now))
        handle(b, self[b].neighborReady(a, now: now))
        run()
    }

    func unlink(_ a: String, _ b: String) {
        links.remove(Self.key(a, b))
        self[a].neighborLost(b)
        self[b].neighborLost(a)
        queue.removeAll { Self.key($0.from, $0.to) == Self.key(a, b) }
    }

    func publish(_ message: RelayMessage) throws {
        handle(message.originId, try self[message.originId].publish(message, now: now))
        run()
    }

    func advance(_ seconds: Int) {
        for _ in 0..<seconds {
            now += 1
            for relay in relays.values { relay.tick(now: now) }
        }
    }

    private func run() {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard links.contains(Self.key(item.from, item.to)) else { continue }
            var assembler = FrameAssembler()
            for start in stride(from: 0, to: item.framed.count, by: 182) {
                let chunk = item.framed.subdata(in: start..<min(start + 182, item.framed.count))
                for frame in try! assembler.append(chunk) {
                    handle(item.to, self[item.to].receive(frame, from: item.from, now: now, wallClock: 1_793_000_000 + now))
                }
            }
        }
    }

    private func handle(_ id: String, _ actions: [RecordAction]) {
        for action in actions {
            switch action {
            case .send(let message, let to, _, let droppable):
                if droppable { droppableSends += 1 }
                guard links.contains(Self.key(id, to)) else { continue }
                queue.append((id, to, Framing.encode(try! message.encoded(), type: .record)!))
            case .deliver(let record):
                received[id, default: []].append(record)
            }
        }
    }

    private static func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
}

final class RecordRelayTests: XCTestCase {
    private let frame = "hervanta-v1"
    private let epoch = "2B7F0E64-5C1D-4E8B-A6F2-7D3C9B1E0A55"
    private let nextEpoch = "9A1C3E5F-7B2D-4F60-8E14-A3C5E7092B4D"

    private func position(_ origin: String, x: Double, age: Double = 0, maxAge: Double = 30) -> RelayMessage.Payload {
        .position(PositionEstimate(
            subjectId: origin, timestamp: 1_793_000_000, frameId: frame, kind: .declared, method: .manual,
            position: Position(x: x, y: 0, z: 0), uncertainty: PositionUncertainty(r95: 2), source: .manual,
            freshness: Freshness(ageAtHandoff: age, maxAge: maxAge),
            provenance: Provenance(producerId: origin, algorithm: "manual@1", gnssDependent: false)))
    }

    private func observations(_ origin: String, peer: String) -> RelayMessage.Payload {
        .observations([PeerObservation(
            observerId: origin, peerId: peer, timestamp: 1_793_000_000, frameId: frame, channel: .connection,
            linkState: .ready, rawRSSI: [-70, -72], window: 1, smoothedRSSI: -71, uncertainty: .init(stdDevDb: 1, sampleCount: 2),
            freshness: Freshness(maxAge: 6),
            provenance: Provenance(producerId: origin, algorithm: PeerSighting.algorithm, gnssDependent: false))])
    }

    private func message(_ origin: String, sequence: Int, epoch: String? = nil, x: Double = 1, hops: Int = 4,
                         age: Double = 0, maxAge: Double = 30, payload: RelayMessage.Payload? = nil) -> RelayMessage {
        let payload = payload ?? position(origin, x: x, age: age, maxAge: maxAge)
        return RelayMessage(originId: origin, epochId: epoch ?? self.epoch, sequence: sequence, timestamp: 1_793_000_000,
                            frameId: frame, hopsRemaining: hops, freshness: Freshness(ageAtHandoff: age, maxAge: maxAge),
                            payload: payload)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/fixtures")

    // MARK: Relaying

    func testStateRecordCrossesTheChainWithItsIdentity() throws {
        let mesh = RecordMesh(["a", "b", "c"])
        mesh.link("a", "b")
        mesh.link("b", "c")
        let sent = message("a", sequence: 1)
        try mesh.publish(sent)

        let atC = try XCTUnwrap(mesh.records("c").first)
        XCTAssertEqual(mesh.records("c").count, 1)
        XCTAssertEqual(atC.messageId, sent.messageId)
        XCTAssertEqual(atC.originId, "a")
        XCTAssertEqual(atC.epochId, sent.epochId)
        XCTAssertEqual(atC.sequence, 1)
        XCTAssertEqual(atC.payload, sent.payload)
        XCTAssertEqual(atC.path, ["b"])
        XCTAssertEqual(atC.hopsRemaining, 3)
        XCTAssertEqual(atC.freshness.ageAtHandoff, 0)
        XCTAssertEqual(mesh.records("b").map(\.messageId), [sent.messageId], "relays deliver to their own pipeline too")
        XCTAssertTrue(mesh.records("a").isEmpty)
        XCTAssertEqual(mesh["c"].latest(from: "a", type: "position")?.messageId, sent.messageId)
    }

    func testOlderSequencesAndRetiredEpochsAreIgnored() {
        let relay = RecordRelay(selfId: "b")
        func accept(_ message: RelayMessage) -> Bool {
            relay.receive(message, from: "a", now: 1, wallClock: 1).contains { if case .deliver = $0 { return true } else { return false } }
        }
        XCTAssertTrue(accept(message("a", sequence: 5)))
        XCTAssertFalse(accept(message("a", sequence: 4)))
        XCTAssertFalse(accept(message("a", sequence: 5)), "same sequence, new message ID")
        XCTAssertTrue(accept(message("a", sequence: 1, epoch: nextEpoch)), "a restart starts a new epoch")
        XCTAssertFalse(accept(message("a", sequence: 9, epoch: epoch)), "the old epoch is retired")
        XCTAssertTrue(accept(message("a", sequence: 2, epoch: nextEpoch)))
        XCTAssertEqual(relay.statistics.outOfOrder, 3)
        XCTAssertEqual(relay.latest(from: "a", type: "position")?.sequence, 2)
    }

    func testEachPayloadTypeHasItsOwnOrder() throws {
        let relay = RecordRelay(selfId: "b")
        _ = relay.receive(message("a", sequence: 7), from: "a", now: 1, wallClock: 1)
        let batch = message("a", sequence: 3, payload: observations("a", peer: "c"))
        XCTAssertEqual(relay.receive(batch, from: "a", now: 1, wallClock: 1).count, 1, "observations are not ordered against positions")
        XCTAssertEqual(relay.storedCount, 1, "observation batches are never stored")
    }

    func testPhoneThatLinksLaterGetsTheLatestRecordWithItsHoldTime() throws {
        let mesh = RecordMesh(["a", "b", "c"])
        mesh.link("a", "b")
        try mesh.publish(message("a", sequence: 1, x: 1))
        let newest = message("a", sequence: 2, x: 2)
        try mesh.publish(newest)
        mesh.unlink("a", "b")
        mesh.advance(10)
        mesh.link("b", "c")

        XCTAssertEqual(mesh.records("c").map(\.sequence), [2], "only the latest state is handed on")
        let atC = try XCTUnwrap(mesh.records("c").first)
        XCTAssertEqual(atC.messageId, newest.messageId)
        XCTAssertEqual(atC.path, ["b"])
        XCTAssertEqual(atC.freshness.ageAtHandoff, 10, accuracy: 1e-9, "B's hold time is added")
        XCTAssertEqual(atC.freshness.maxAge, 30)
    }

    func testOriginHandsItsOwnStoredRecordToALateNeighbor() throws {
        let mesh = RecordMesh(["a", "b"])
        let sent = message("a", sequence: 1)
        try mesh.publish(sent)
        mesh.advance(4)
        mesh.link("a", "b")
        let atB = try XCTUnwrap(mesh.records("b").first)
        XCTAssertEqual(atB.messageId, sent.messageId)
        XCTAssertEqual(atB.path, [])
        XCTAssertEqual(atB.hopsRemaining, sent.hopsRemaining)
        XCTAssertEqual(atB.freshness.ageAtHandoff, 4, accuracy: 1e-9)
    }

    func testStaleRecordsAreNeitherAcceptedNorHandedOn() throws {
        let mesh = RecordMesh(["a", "b", "c"])
        mesh.link("a", "b")
        try mesh.publish(message("a", sequence: 1, maxAge: 5))
        mesh.unlink("a", "b")
        mesh.advance(6)
        XCTAssertEqual(mesh["b"].storedCount, 0)
        XCTAssertEqual(mesh["b"].statistics.expired, 1)
        mesh.link("b", "c")
        XCTAssertTrue(mesh.records("c").isEmpty)

        let relay = RecordRelay(selfId: "b")
        XCTAssertTrue(relay.receive(message("a", sequence: 1, age: 31, maxAge: 30), from: "a", now: 0, wallClock: 0).isEmpty)
        XCTAssertEqual(relay.statistics.stale, 1)
    }

    func testObservationBatchesAreForwardedOnceAndMayBeDropped() throws {
        // Diamond: D hears A's batch through B and C but delivers it once.
        let mesh = RecordMesh(["a", "b", "c", "d"])
        mesh.link("a", "b")
        mesh.link("a", "c")
        mesh.link("b", "d")
        mesh.link("c", "d")
        let batch = message("a", sequence: 1, payload: observations("a", peer: "b"))
        try mesh.publish(batch)
        XCTAssertEqual(mesh.records("d").map(\.messageId), [batch.messageId])
        XCTAssertGreaterThanOrEqual(mesh["d"].statistics.duplicates, 1)
        XCTAssertEqual(mesh["d"].storedCount, 0)
        XCTAssertGreaterThan(mesh.droppableSends, 0)
    }

    func testLoopsAndOwnRecordsAreDropped() {
        let relay = RecordRelay(selfId: "b")
        let own = message("b", sequence: 1)
        XCTAssertTrue(relay.receive(own, from: "a", now: 0, wallClock: 0).isEmpty)
        let looped = RelayMessage(originId: "a", epochId: epoch, sequence: 1, timestamp: 1_793_000_000, frameId: frame,
                                  hopsRemaining: 3, path: ["b"], freshness: Freshness(maxAge: 30), payload: position("a", x: 1))
        XCTAssertTrue(relay.receive(looped, from: "c", now: 0, wallClock: 0).isEmpty)
        XCTAssertEqual(relay.statistics.loops, 2)
    }

    func testHopBudgetEndsForwarding() throws {
        let mesh = RecordMesh(["a", "b", "c"])
        mesh.link("a", "b")
        mesh.link("b", "c")
        try mesh.publish(message("a", sequence: 1, hops: 0))
        XCTAssertEqual(mesh.records("b").count, 1)
        XCTAssertTrue(mesh.records("c").isEmpty)
    }

    func testPublishRefusesForeignOrReplayedRecords() throws {
        let relay = RecordRelay(selfId: "a")
        XCTAssertThrowsError(try relay.publish(message("z", sequence: 1), now: 0))
        _ = try relay.publish(message("a", sequence: 3), now: 0)
        XCTAssertThrowsError(try relay.publish(message("a", sequence: 3), now: 0))
        XCTAssertThrowsError(try relay.publish(message("a", sequence: 2), now: 0))
        XCTAssertNoThrow(try relay.publish(message("a", sequence: 4), now: 0))
    }

    func testOutboxKeysCoalesceStateButNotEvents() {
        XCTAssertEqual(RecordRelay.outboxKey(message("a", sequence: 1)), RecordRelay.outboxKey(message("a", sequence: 2)))
        XCTAssertNotEqual(RecordRelay.outboxKey(message("a", sequence: 1)), RecordRelay.outboxKey(message("b", sequence: 1)))
        let first = message("a", sequence: 1, payload: observations("a", peer: "b"))
        let second = message("a", sequence: 2, payload: observations("a", peer: "b"))
        XCTAssertNotEqual(RecordRelay.outboxKey(first), RecordRelay.outboxKey(second))
    }

    func testGoldenRelayFixtureIsAcceptedAndRelayed() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("relay-integrity.json"))
        let golden = try RelayMessage.decode(data)
        let relay = RecordRelay(selfId: "phone-d")
        _ = relay.neighborReady("phone-b", now: 0)
        _ = relay.neighborReady("phone-e", now: 0)
        let actions = relay.receive(Frame(type: .record, payload: data), from: "phone-b", now: 0, wallClock: 1_793_001_643)

        guard case .deliver(let record) = actions.first else { return XCTFail("not delivered") }
        XCTAssertEqual(record.message, golden)
        XCTAssertEqual(record.hops, 2)
        let sends = actions.compactMap { action -> (RelayMessage, String)? in
            if case .send(let message, let to, _, _) = action { return (message, to) } else { return nil }
        }
        XCTAssertEqual(sends.map(\.1), ["phone-e"], "never back to where it came from")
        let copy = try XCTUnwrap(sends.first?.0)
        XCTAssertEqual(copy.path, golden.path + ["phone-d"])
        XCTAssertEqual(copy.hopsRemaining, golden.hopsRemaining - 1)
        XCTAssertEqual(copy.freshness.ageAtHandoff, golden.freshness.ageAtHandoff)
        XCTAssertEqual(copy.messageId, golden.messageId)
        XCTAssertNoThrow(try copy.encoded())
    }

    // MARK: Peer observations

    func testSightingMapsOntoTheContract() throws {
        var statistics = RSSIStatistics()
        let start = Date(timeIntervalSince1970: 1_793_001_640)
        statistics.record(-71, at: start)
        statistics.record(-74, at: start.addingTimeInterval(0.5))
        statistics.record(-69, at: start.addingTimeInterval(1))
        let sighting = try XCTUnwrap(PeerSighting.take(
            from: &statistics, observerId: "phone-b", peerId: "phone-a", transportHandle: UUID(), channel: .connection,
            linkState: .ready, txPower: -8, now: start.addingTimeInterval(1.25)))
        let observation = try XCTUnwrap(sighting.observation(frameId: frame, peerModel: "iPhone16,1"))

        XCTAssertNoThrow(try observation.validate())
        XCTAssertEqual(observation.observerId, "phone-b")
        XCTAssertEqual(observation.peerId, "phone-a")
        XCTAssertEqual(observation.timestamp, 1_793_001_641, accuracy: 1e-6, "time of the newest sample")
        XCTAssertEqual(observation.channel, .connection)
        XCTAssertEqual(observation.linkState, .ready)
        XCTAssertEqual(observation.rawRSSI, [-71, -74, -69])
        XCTAssertEqual(observation.window, 1, accuracy: 1e-9)
        XCTAssertEqual(observation.uncertainty.sampleCount, 3)
        XCTAssertNotNil(observation.uncertainty.stdDevDb)
        XCTAssertEqual(observation.txPower, -8)
        XCTAssertEqual(observation.source, .bluetooth)
        XCTAssertEqual(observation.freshness.ageAtHandoff, 0.25, accuracy: 1e-6)
        XCTAssertEqual(observation.freshness.maxAge, PeerSighting.observationMaxAge)
        XCTAssertEqual(observation.provenance.producerId, "phone-b")
        XCTAssertEqual(observation.provenance.algorithm, "ble-sighting@1")
        XCTAssertFalse(observation.provenance.gnssDependent)
        XCTAssertFalse(observation.provenance.simulated)
    }

    func testSightingStatesAndEdgeCasesMapOntoTheContract() throws {
        let at = Date(timeIntervalSince1970: 1_793_001_640)
        func observation(_ state: PeerSighting.LinkState, peerId: String?, samples: Int) -> PeerObservation? {
            var statistics = RSSIStatistics()
            for index in 0..<samples { statistics.record(-60 - index, at: at.addingTimeInterval(Double(index))) }
            _ = statistics.takeRecentSamples()
            return PeerSighting.take(from: &statistics, observerId: "phone-b", peerId: peerId, transportHandle: nil,
                                     channel: .advertisement, linkState: state, now: at)?.observation(frameId: frame)
        }
        XCTAssertEqual(observation(.advertised, peerId: nil, samples: 1)?.linkState, .advertisementOnly)
        XCTAssertNil(observation(.advertised, peerId: nil, samples: 1)?.peerId)
        XCTAssertNil(observation(.advertised, peerId: nil, samples: 1)?.uncertainty.stdDevDb, "no spread from one sample")
        XCTAssertEqual(observation(.linking, peerId: "phone-a", samples: 2)?.linkState, .connecting)
        XCTAssertEqual(observation(.lost, peerId: "phone-a", samples: 2)?.linkState, .lost)
        let quiet = try XCTUnwrap(observation(.ready, peerId: "phone-a", samples: 25))
        XCTAssertTrue(quiet.rawRSSI.isEmpty, "a snapshot with no new samples still reports the smoothed value")
        XCTAssertEqual(quiet.uncertainty.sampleCount, RSSIStatistics.deviationWindow)
        XCTAssertNil(observation(.ready, peerId: "phone-b", samples: 2), "a peer can't be the observer")
        XCTAssertNil(observation(.ready, peerId: "phone-a", samples: 0))
    }
}
