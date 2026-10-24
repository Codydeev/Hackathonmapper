import Foundation
import XCTest
import MeshCore

/// In-memory phones joined by links that come and go. Every frame goes through the real wire path:
/// JSON encoding, `Framing`, chunking at a BLE-sized payload and `FrameAssembler`.
private final class SimulatedMesh {
    static let chunkSize = 182

    var now: TimeInterval = 1_000
    private(set) var engines: [String: RelayEngine] = [:]
    private(set) var deliveries: [String: [RelayDelivery]] = [:]
    private(set) var framesSent = 0
    private var links = Set<String>()
    private var queue: [(from: String, to: String, chunk: Data)] = []
    private var assemblers: [String: FrameAssembler] = [:]

    init(_ ids: [String], configuration: RelayEngine.Configuration = RelayEngine.Configuration()) {
        for id in ids { engines[id] = RelayEngine(selfId: id, configuration: configuration) }
    }

    subscript(_ id: String) -> RelayEngine { engines[id]! }

    func delivered(_ id: String) -> [RelayDelivery] { deliveries[id] ?? [] }

    func link(_ a: String, _ b: String, run: Bool = true) {
        links.insert(Self.key(a, b))
        handle(a, self[a].neighborReady(b, now: now))
        handle(b, self[b].neighborReady(a, now: now))
        if run { self.run() }
    }

    /// Ends the link. Anything still in flight on it is lost.
    func unlink(_ a: String, _ b: String) {
        links.remove(Self.key(a, b))
        self[a].neighborLost(b)
        self[b].neighborLost(a)
        queue.removeAll { Self.key($0.from, $0.to) == Self.key(a, b) }
        assemblers["\(a)>\(b)"] = nil
        assemblers["\(b)>\(a)"] = nil
    }

    /// Loses everything in flight while the links stay up, like a failed write or notification.
    func dropInFlight() {
        queue.removeAll()
        assemblers.removeAll()
    }

    @discardableResult
    func send(from: String, to destination: String? = nil, kind: String = "text", body: String = "hello",
              ttlMs: Int? = nil, hops: Int? = nil, run: Bool = true) throws -> RelayEnvelope {
        let (envelope, actions) = try self[from].originate(
            kind: kind, body: body, to: destination, ttlMs: ttlMs, hops: hops,
            now: now, wallClock: Date(timeIntervalSince1970: 1_800_000_000 + now))
        handle(from, actions)
        if run { self.run() }
        return envelope
    }

    /// Moves time forward one second at a time, ticking every phone and delivering what it sends.
    func advance(_ seconds: Int) {
        for _ in 0..<seconds {
            now += 1
            for id in engines.keys.sorted() { handle(id, self[id].tick(now: now)) }
            run()
        }
    }

    func run() {
        var steps = 0
        while !queue.isEmpty {
            steps += 1
            precondition(steps < 100_000, "relay traffic did not settle")
            let item = queue.removeFirst()
            guard links.contains(Self.key(item.from, item.to)) else { continue }
            let direction = "\(item.from)>\(item.to)"
            var assembler = assemblers[direction] ?? FrameAssembler()
            let frames = try! assembler.append(item.chunk)
            assemblers[direction] = assembler
            for frame in frames {
                handle(item.to, self[item.to].receive(frame, from: item.from, now: now))
            }
        }
    }

    private func handle(_ id: String, _ actions: [RelayAction]) {
        for action in actions {
            switch action {
            case .send(let envelope, let to):
                enqueue(Framing.encode(try! envelope.encoded(), type: .relayMessage)!, from: id, to: to)
            case .sendSummary(let summary, let to):
                enqueue(Framing.encode(try! summary.encoded(), type: .relaySummary)!, from: id, to: to)
            case .deliver(let delivery):
                deliveries[id, default: []].append(delivery)
            }
        }
    }

    private func enqueue(_ framed: Data, from: String, to: String) {
        guard links.contains(Self.key(from, to)) else { return }
        framesSent += 1
        for start in stride(from: 0, to: framed.count, by: Self.chunkSize) {
            queue.append((from, to, framed.subdata(in: start..<min(start + Self.chunkSize, framed.count))))
        }
    }

    private static func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
}

final class RelayEngineTests: XCTestCase {
    private func envelope(
        originId: String = "phone-a",
        destinationId: String? = nil,
        kind: String = "text",
        body: String = "hello",
        ageMs: Int = 0,
        ttlMs: Int = 60_000,
        hopsRemaining: Int = 4,
        path: [String] = [],
        acknowledges: UUID? = nil
    ) -> RelayEnvelope {
        RelayEnvelope(originId: originId, destinationId: destinationId, kind: kind, body: body,
                      createdAt: 1_800_000_000_000, ageMs: ageMs, ttlMs: ttlMs,
                      hopsRemaining: hopsRemaining, path: path, acknowledges: acknowledges)
    }

    private func frame(_ envelope: RelayEnvelope) throws -> Frame {
        Frame(type: .relayMessage, payload: try envelope.encoded())
    }

    // MARK: Envelope

    func testEnvelopeRoundTripsThroughJSON() throws {
        let original = envelope(destinationId: "phone-c", path: ["phone-b"])
        let decoded = try RelayEnvelope.decode(original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.messageId, original.messageId)
    }

    func testEnvelopeValidation() throws {
        XCTAssertNoThrow(try envelope().validate())
        XCTAssertNoThrow(try envelope(hopsRemaining: 7, path: ["b"]).validate())
        XCTAssertNoThrow(try envelope(kind: "ghostcore.sos").validate())
        XCTAssertNoThrow(try envelope(body: String(repeating: "x", count: RelayEnvelope.maxBodyBytes)).validate())
        XCTAssertNoThrow(try envelope(ageMs: 60_000).validate(), "expired copies are well formed; the engine counts them")
        let receipt = envelope(destinationId: "phone-c", kind: RelayEnvelope.receiptKind, acknowledges: UUID())
        XCTAssertNoThrow(try receipt.validate())

        let invalid: [RelayEnvelope] = [
            envelope(originId: ""),
            envelope(originId: String(repeating: "a", count: 65)),
            envelope(destinationId: "phone-a"),
            envelope(kind: "Text"),
            envelope(kind: ""),
            envelope(kind: String(repeating: "k", count: 33)),
            envelope(body: String(repeating: "x", count: RelayEnvelope.maxBodyBytes + 1)),
            envelope(ageMs: -1),
            envelope(ttlMs: 0),
            envelope(ttlMs: RelayEnvelope.maxTTLMs + 1),
            envelope(hopsRemaining: -1),
            envelope(hopsRemaining: 8, path: ["b"]),
            envelope(path: ["phone-a"]),
            envelope(path: ["b", "b"]),
            envelope(path: [""]),
            envelope(kind: RelayEnvelope.receiptKind),
            envelope(acknowledges: UUID()),
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.validate(), "\(value)")
            XCTAssertThrowsError(try value.encoded())
        }
    }

    func testDecodeRejectsMalformedAndOversizedPayloads() {
        XCTAssertThrowsError(try RelayEnvelope.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try RelayEnvelope.decode(Data(repeating: 0x20, count: RelayEnvelope.maxEncodedSize + 1)))
        XCTAssertThrowsError(try RelaySummary.decode(Data("[1]".utf8)))
    }

    func testSummaryIsBounded() throws {
        XCTAssertNoThrow(try RelaySummary(have: (0..<RelaySummary.maxIds).map { _ in UUID() }).encoded())
        let full = try RelaySummary(have: (0..<RelaySummary.maxIds).map { _ in UUID() }).encoded()
        XCTAssertLessThanOrEqual(full.count, Framing.maxPayload)
        XCTAssertThrowsError(try RelaySummary(have: (0...RelaySummary.maxIds).map { _ in UUID() }).encoded())
    }

    func testOriginateRejectsInvalidMessages() {
        let engine = RelayEngine(selfId: "phone-a")
        XCTAssertThrowsError(try engine.originate(kind: "text", body: "x", to: "phone-a", now: 0))
        XCTAssertThrowsError(try engine.originate(kind: "BAD", body: "x", now: 0))
        XCTAssertThrowsError(try engine.originate(kind: "text", body: "x", hops: 9, now: 0))
        XCTAssertEqual(engine.statistics.originated, 0)
    }

    // MARK: Direct and multi-hop delivery

    func testDirectMessageIsDeliveredOnceAndAcknowledged() throws {
        let mesh = SimulatedMesh(["a", "b"])
        mesh.link("a", "b")
        let sent = try mesh.send(from: "a", to: "b", body: "ping")

        XCTAssertEqual(mesh.delivered("b").count, 1)
        let delivery = try XCTUnwrap(mesh.delivered("b").first)
        XCTAssertEqual(delivery.envelope.messageId, sent.messageId)
        XCTAssertEqual(delivery.envelope.originId, "a")
        XCTAssertEqual(delivery.envelope.body, "ping")
        XCTAssertEqual(delivery.envelope.path, [])
        XCTAssertEqual(delivery.hops, 1)
        XCTAssertEqual(delivery.fromNeighbor, "a")

        let receipt = try XCTUnwrap(mesh.delivered("a").first)
        XCTAssertTrue(receipt.envelope.isReceipt)
        XCTAssertEqual(receipt.envelope.acknowledges, sent.messageId)
        XCTAssertEqual(receipt.envelope.destinationId, "a")
        XCTAssertEqual(RelayReceiptInfo.decode(body: receipt.envelope.body), RelayReceiptInfo(path: [], ageMs: 0))
        XCTAssertFalse(mesh["a"].isStored(sent.messageId), "a receipt ends store-and-forward of the message")
        XCTAssertFalse(mesh["b"].isStored(sent.messageId), "the destination does not forward a message for itself")
    }

    func testThreePhoneChainRelaysThroughTheMiddlePhone() throws {
        // A and C have no link; only B can carry A's message.
        let mesh = SimulatedMesh(["a", "b", "c"])
        mesh.link("a", "b")
        mesh.link("b", "c")
        let sent = try mesh.send(from: "a", to: "c", hops: 4)

        let delivery = try XCTUnwrap(mesh.delivered("c").first)
        XCTAssertEqual(mesh.delivered("c").count, 1)
        XCTAssertEqual(delivery.envelope.messageId, sent.messageId, "message IDs survive relaying")
        XCTAssertEqual(delivery.envelope.originId, "a")
        XCTAssertEqual(delivery.envelope.createdAt, sent.createdAt)
        XCTAssertEqual(delivery.envelope.path, ["b"])
        XCTAssertEqual(delivery.envelope.hopsRemaining, 3)
        XCTAssertEqual(delivery.hops, 2)
        XCTAssertEqual(delivery.fromNeighbor, "b")
        XCTAssertTrue(mesh.delivered("b").isEmpty, "B relays a message addressed to C without delivering it")

        let receipt = try XCTUnwrap(mesh.delivered("a").first)
        XCTAssertEqual(receipt.envelope.acknowledges, sent.messageId)
        XCTAssertEqual(receipt.envelope.path, ["b"])
        XCTAssertEqual(RelayReceiptInfo.decode(body: receipt.envelope.body)?.path, ["b"])
        XCTAssertFalse(mesh["b"].isStored(sent.messageId), "the receipt passing through B clears B's copy")
        XCTAssertEqual(mesh["b"].statistics.cleared, 1)
    }

    func testBroadcastIsDeliveredByEveryPhoneExactlyOnce() throws {
        // Diamond: D hears A's broadcast through both B and C.
        let mesh = SimulatedMesh(["a", "b", "c", "d"])
        mesh.link("a", "b")
        mesh.link("a", "c")
        mesh.link("b", "d")
        mesh.link("c", "d")
        let sent = try mesh.send(from: "a", body: "all")

        for id in ["b", "c", "d"] {
            XCTAssertEqual(mesh.delivered(id).map(\.envelope.messageId), [sent.messageId], id)
        }
        XCTAssertTrue(mesh.delivered("a").isEmpty, "no receipts for broadcasts, no self-delivery")
        let suppressed = ["b", "c", "d"].map { mesh[$0].statistics.duplicates + mesh[$0].statistics.loops }.reduce(0, +)
        XCTAssertGreaterThanOrEqual(suppressed, 1, "the second copy reaching D is suppressed")
    }

    func testHopLimitStopsForwarding() throws {
        let mesh = SimulatedMesh(["a", "b", "c", "d"])
        mesh.link("a", "b")
        mesh.link("b", "c")
        mesh.link("c", "d")
        try mesh.send(from: "a", hops: 1)

        XCTAssertEqual(mesh.delivered("b").count, 1)
        XCTAssertEqual(mesh.delivered("c").first?.envelope.hopsRemaining, 0)
        XCTAssertEqual(mesh.delivered("c").first?.envelope.path, ["b"])
        XCTAssertTrue(mesh.delivered("d").isEmpty)
        XCTAssertEqual(mesh["c"].statistics.hopLimited, 1)
    }

    func testRelayIgnoresLoopsAndItsOwnMessages() throws {
        let engine = RelayEngine(selfId: "phone-b")
        _ = engine.neighborReady("phone-a", now: 0)
        let looped = envelope(originId: "phone-a", path: ["phone-b"])
        XCTAssertTrue(engine.receive(try frame(looped), from: "phone-a", now: 1).isEmpty)
        let own = envelope(originId: "phone-b", path: ["phone-a"])
        XCTAssertTrue(engine.receive(try frame(own), from: "phone-a", now: 1).isEmpty)
        XCTAssertEqual(engine.statistics.loops, 2)
        XCTAssertEqual(engine.statistics.accepted, 0)
    }

    func testInvalidFramesAreCountedNotDelivered() {
        let engine = RelayEngine(selfId: "phone-b")
        XCTAssertTrue(engine.receive(Frame(type: .relayMessage, payload: Data("not json".utf8)), from: "phone-a", now: 0).isEmpty)
        XCTAssertTrue(engine.receive(Frame(type: .relaySummary, payload: Data("{}".utf8)), from: "phone-a", now: 0).isEmpty)
        XCTAssertTrue(engine.receive(Frame(type: .position, payload: Data("{}".utf8)), from: "phone-a", now: 0).isEmpty)
        XCTAssertEqual(engine.statistics.invalid, 2)
        XCTAssertTrue(engine.relayCapable.isEmpty)
    }

    // MARK: Store and forward

    func testMiddlePhoneCarriesMessageToPhoneThatArrivesLater() throws {
        // A and B are together; C is out of range. B walks away from A, holds the message for 45 s,
        // then meets C.
        let mesh = SimulatedMesh(["a", "b", "c"])
        mesh.link("a", "b")
        let sent = try mesh.send(from: "a", to: "c", body: "need water", ttlMs: 10 * 60_000)
        XCTAssertTrue(mesh["b"].isStored(sent.messageId))
        XCTAssertTrue(mesh.delivered("c").isEmpty)

        mesh.unlink("a", "b")
        mesh.advance(45)
        mesh.link("b", "c")

        let delivery = try XCTUnwrap(mesh.delivered("c").first)
        XCTAssertEqual(mesh.delivered("c").count, 1)
        XCTAssertEqual(delivery.envelope.messageId, sent.messageId)
        XCTAssertEqual(delivery.envelope.path, ["b"])
        XCTAssertGreaterThanOrEqual(delivery.envelope.ageMs, 45_000, "B's hold time is part of the age")
        XCTAssertLessThan(delivery.envelope.ageMs, 46_000)
        XCTAssertFalse(mesh["b"].isStored(sent.messageId), "C's receipt clears B's copy")

        // A is still waiting: the receipt rides back with B.
        XCTAssertTrue(mesh.delivered("a").isEmpty)
        XCTAssertTrue(mesh["a"].isStored(sent.messageId))
        mesh.unlink("b", "c")
        mesh.advance(10)
        mesh.link("a", "b")
        let receipt = try XCTUnwrap(mesh.delivered("a").first)
        XCTAssertEqual(receipt.envelope.acknowledges, sent.messageId)
        XCTAssertEqual(RelayReceiptInfo.decode(body: receipt.envelope.body)?.path, ["b"])
        XCTAssertFalse(mesh["a"].isStored(sent.messageId))
        XCTAssertEqual(mesh.delivered("c").count, 1, "nothing is delivered twice")
    }

    func testAgeAccumulatesAcrossHoldsWithoutWallClocks() throws {
        let mesh = SimulatedMesh(["a", "b", "c"])
        let sent = try mesh.send(from: "a", body: "beacon")
        mesh.advance(2)
        mesh.link("a", "b")
        XCTAssertEqual(mesh.delivered("b").first?.envelope.ageMs, 2_000)
        mesh.advance(3)
        mesh.link("b", "c")
        let atC = try XCTUnwrap(mesh.delivered("c").first)
        XCTAssertEqual(atC.envelope.ageMs, 5_000)
        XCTAssertEqual(atC.envelope.createdAt, sent.createdAt, "the origin wall clock rides along unchanged")
    }

    func testExpiredMessagesAreNotCarriedFurther() throws {
        let mesh = SimulatedMesh(["a", "b", "c"])
        mesh.link("a", "b")
        let sent = try mesh.send(from: "a", to: "c", ttlMs: 30_000)
        mesh.unlink("a", "b")
        mesh.advance(31)
        XCTAssertFalse(mesh["b"].isStored(sent.messageId))
        XCTAssertGreaterThanOrEqual(mesh["b"].statistics.expired, 1)
        mesh.link("b", "c")
        XCTAssertTrue(mesh.delivered("c").isEmpty)
    }

    func testCopyArrivingAfterItsTTLIsDropped() throws {
        let engine = RelayEngine(selfId: "phone-b")
        _ = engine.neighborReady("phone-a", now: 0)
        let late = envelope(destinationId: "phone-b", ageMs: 60_000, ttlMs: 60_000)
        XCTAssertTrue(engine.receive(try frame(late), from: "phone-a", now: 1).isEmpty)
        XCTAssertEqual(engine.statistics.expired, 1)
        XCTAssertEqual(engine.statistics.delivered, 0)
    }

    func testReconnectResendsOnlyWhatWasLost() throws {
        let mesh = SimulatedMesh(["a", "b"])
        mesh.link("a", "b")
        let first = try mesh.send(from: "a", body: "one")
        XCTAssertEqual(mesh.delivered("b").count, 1)

        // The second message is queued, then the link drops before it is sent.
        let second = try mesh.send(from: "a", body: "two", run: false)
        mesh.unlink("a", "b")
        XCTAssertEqual(mesh.delivered("b").count, 1)

        mesh.advance(6)
        let framesBefore = mesh.framesSent
        mesh.link("a", "b")
        XCTAssertEqual(mesh.delivered("b").map(\.envelope.messageId), [first.messageId, second.messageId])
        // Two summaries plus the one missing message: the delivered one is not resent.
        XCTAssertEqual(mesh.framesSent - framesBefore, 3)
    }

    func testPeriodicSummaryRepairsLossOnAStableLink() throws {
        var configuration = RelayEngine.Configuration()
        configuration.summaryInterval = 10
        let mesh = SimulatedMesh(["a", "b"], configuration: configuration)
        mesh.link("a", "b")
        let lost = try mesh.send(from: "a", body: "lost", run: false)
        mesh.dropInFlight()
        mesh.advance(9)
        XCTAssertTrue(mesh.delivered("b").isEmpty, "no summary is due yet")
        mesh.advance(1)
        XCTAssertEqual(mesh.delivered("b").map(\.envelope.messageId), [lost.messageId])
    }

    func testNeighborsWithoutTheRelayGetNoEnvelopes() throws {
        let engine = RelayEngine(selfId: "phone-a")
        let ready = engine.neighborReady("old-build", now: 0)
        XCTAssertEqual(ready.count, 1)
        guard case .sendSummary = ready[0] else { return XCTFail("expected a summary") }
        let (_, actions) = try engine.originate(kind: "text", body: "x", now: 1)
        XCTAssertTrue(actions.isEmpty, "a phone that never sent a relay frame skips them anyway")
        XCTAssertEqual(engine.storedCount, 1)
    }

    func testLostNeighborStopsReceivingCopies() throws {
        let mesh = SimulatedMesh(["a", "b"])
        mesh.link("a", "b")
        mesh.unlink("a", "b")
        try mesh.send(from: "a")
        XCTAssertTrue(mesh.delivered("b").isEmpty)
        XCTAssertFalse(mesh["a"].neighbors.contains("b"))
    }

    // MARK: Bounds

    func testStorageIsBoundedAndEvictsClosestToExpiry() throws {
        var configuration = RelayEngine.Configuration()
        configuration.maxStored = 4
        let engine = RelayEngine(selfId: "phone-a", configuration: configuration)
        let (shortLived, _) = try engine.originate(kind: "text", body: "short", ttlMs: 10_000, now: 0)
        for index in 0..<9 {
            _ = try engine.originate(kind: "text", body: "\(index)", ttlMs: 600_000, now: 1)
        }
        XCTAssertEqual(engine.storedCount, 4)
        XCTAssertEqual(engine.statistics.evicted, 6)
        XCTAssertFalse(engine.isStored(shortLived.messageId))
    }

    func testSeenIdsAreBoundedAndForgottenAfterTheirLifetime() throws {
        var configuration = RelayEngine.Configuration()
        configuration.maxSeen = 3
        configuration.seenLifetime = 60
        let engine = RelayEngine(selfId: "phone-a", configuration: configuration)
        let ids = try (0..<4).map { _ in try engine.originate(kind: "text", body: "x", now: 0).0.messageId }
        XCTAssertFalse(engine.hasSeen(ids[0]))
        XCTAssertTrue(engine.hasSeen(ids[3]))
        XCTAssertEqual(engine.summary().have, Array(ids[1...].reversed()))
        _ = engine.tick(now: 61)
        XCTAssertFalse(engine.hasSeen(ids[3]))
        XCTAssertTrue(engine.summary().have.isEmpty)
    }

    func testDefaultLimitsFitTheFraming() throws {
        let path = (1...7).map { "relay-\($0)-" + String(repeating: "x", count: 50) }
        let largest = RelayEnvelope(
            originId: String(repeating: "o", count: 64), destinationId: String(repeating: "d", count: 64),
            kind: String(repeating: "k", count: 32), body: String(repeating: "é", count: RelayEnvelope.maxBodyBytes / 2),
            createdAt: 1_800_000_000_000, ageMs: 899_999, ttlMs: RelayEnvelope.maxTTLMs,
            hopsRemaining: 1, path: path)
        let encoded = try largest.encoded()
        XCTAssertLessThanOrEqual(encoded.count, RelayEnvelope.maxEncodedSize)
        XCTAssertNotNil(Framing.encode(encoded, type: .relayMessage))
        XCTAssertGreaterThan(RelayEngine.Configuration().seenLifetime * 1000, Double(RelayEnvelope.maxTTLMs))
    }

    func testResetForgetsEverything() throws {
        let engine = RelayEngine(selfId: "phone-a")
        _ = engine.neighborReady("phone-b", now: 0)
        let (sent, _) = try engine.originate(kind: "text", body: "x", now: 0)
        engine.reset()
        XCTAssertFalse(engine.hasSeen(sent.messageId))
        XCTAssertEqual(engine.storedCount, 0)
        XCTAssertTrue(engine.neighbors.isEmpty)
        XCTAssertEqual(engine.statistics, RelayStatistics())
    }

    // MARK: Reconnect backoff

    func testReconnectBackoffSchedule() {
        let delays = (1...7).map { ReconnectBackoff.delay(afterFailures: $0, jitter: 0) }
        XCTAssertEqual(delays, [5, 10, 20, 40, 60, 60, 60])
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: 0, jitter: 0), 5)
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: 10_000, jitter: 0), 60)
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: 1, jitter: 1.5), 6.5)
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: 1, jitter: 99), 7, "jitter is capped")
        for _ in 0..<100 {
            XCTAssertTrue((5...7).contains(ReconnectBackoff.delay(afterFailures: 1)))
        }
    }

    // MARK: Peer sightings

    func testSightingCarriesRawSamplesSinceThePreviousSnapshot() throws {
        var statistics = RSSIStatistics()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PeerSighting.take(from: &statistics, observerId: "a", peerId: "b", transportHandle: nil,
                                       channel: .connection, linkState: .ready, now: start))
        statistics.record(-60, at: start)
        statistics.record(127, at: start.addingTimeInterval(0.5))
        statistics.record(-64, at: start.addingTimeInterval(1))

        let first = try XCTUnwrap(PeerSighting.take(from: &statistics, observerId: "a", peerId: "b", transportHandle: nil,
                                                    channel: .connection, linkState: .ready, now: start.addingTimeInterval(1)))
        XCTAssertEqual(first.samples, [RSSISample(rssi: -60, at: start), RSSISample(rssi: -64, at: start.addingTimeInterval(1))])
        XCTAssertEqual(first.droppedSamples, 0)
        XCTAssertEqual(first.sampleCount, 2, "127 means unavailable and is not a sample")
        XCTAssertEqual(first.peerId, "b")
        XCTAssertEqual(first.lastSampleAt, start.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(first.sampleAge(at: start.addingTimeInterval(3))), 2, accuracy: 1e-9)
        XCTAssertNotNil(first.smoothedRSSI)
        XCTAssertNotNil(first.rssiStandardDeviation)

        let second = try XCTUnwrap(PeerSighting.take(from: &statistics, observerId: "a", peerId: "b", transportHandle: nil,
                                                     channel: .connection, linkState: .ready, now: start.addingTimeInterval(2)))
        XCTAssertTrue(second.samples.isEmpty, "each raw sample is reported once")
        XCTAssertEqual(second.smoothedRSSI, first.smoothedRSSI)
        XCTAssertEqual(second.sampleCount, 2)
    }

    func testSightingKeepsTheNewestSixteenSamples() throws {
        var statistics = RSSIStatistics()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<20 { statistics.record(-50 - index, at: start.addingTimeInterval(Double(index))) }
        let sighting = try XCTUnwrap(PeerSighting.take(from: &statistics, observerId: "a", peerId: nil, transportHandle: UUID(),
                                                       channel: .advertisement, linkState: .advertised, now: start))
        XCTAssertEqual(sighting.samples.count, RSSIStatistics.maxRecentSamples)
        XCTAssertEqual(sighting.droppedSamples, 4)
        XCTAssertEqual(sighting.samples.first?.rssi, -54)
        XCTAssertEqual(sighting.samples.last?.rssi, -69)
        XCTAssertNil(sighting.peerId)
        XCTAssertEqual(statistics.droppedRecentSamples, 0)
    }
}
