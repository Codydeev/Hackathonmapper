import Foundation
import XCTest
@testable import MeshCore

/// The GhostCore contract: golden fixtures in contract/fixtures/ (shared with
/// website/scripts/ghostcore-check.ts) decode, validate and round-trip; the invalid ones are refused;
/// freshness, uncertainty, provenance and relay rules behave as ARCHITECTURE.md describes.
final class ContractTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/fixtures")

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    private func decode<T: GhostRecord>(_ type: T.Type, _ name: String) throws -> T {
        let record = try JSONDecoder().decode(T.self, from: try data(name))
        try record.validate()
        return record
    }

    private func roundTrip<T: GhostRecord>(_ type: T.Type, _ data: Data) throws {
        let record = try JSONDecoder().decode(T.self, from: data)
        try record.validate()
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(record)), record)
    }

    private static func type(for name: String) -> any GhostRecord.Type {
        switch name.split(separator: "-").first {
        case "peer": return PeerObservation.self
        case "position", "provenance": return PositionEstimate.self
        case "integrity": return IntegrityAssessment.self
        case "motion": return MotionObservation.self
        case "prediction": return Prediction.self
        default: return RelayMessage.self
        }
    }

    func testValidFixturesDecodeValidateAndRoundTrip() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(names.count, 9)
        for name in names {
            XCTAssertNoThrow(try roundTrip(Self.type(for: name), try data(name)), name)
        }
    }

    func testInvalidFixturesAreRefused() throws {
        let folder = Self.fixtures.appendingPathComponent("invalid")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, 10)
        for name in names {
            let wrapper = try JSONSerialization.jsonObject(with: try Data(contentsOf: folder.appendingPathComponent(name)))
                as? [String: Any]
            let record = try JSONSerialization.data(withJSONObject: wrapper?["record"] as Any)
            let type: any GhostRecord.Type = switch wrapper?["type"] as? String {
            case "PeerObservation": PeerObservation.self
            case "PositionEstimate": PositionEstimate.self
            case "IntegrityAssessment": IntegrityAssessment.self
            case "Prediction": Prediction.self
            default: RelayMessage.self
            }
            XCTAssertThrowsError(try roundTrip(type, record), name) { error in
                switch (wrapper?["expect"] as? String, error) {
                case ("decode", is DecodingError): break
                case (let field?, GhostCoreContractError.invalid(let failed)): XCTAssertEqual(failed, field, name)
                default: XCTFail("\(name): unexpected \(error)")
                }
            }
        }
    }

    func testIntegrityCannotSaySpoofed() {
        let words = IntegrityAssessment.Status.allCases.map(\.rawValue) + IntegrityAssessment.Reason.allCases.map(\.rawValue)
        XCTAssertFalse(words.contains { $0.lowercased().contains("spoof") || $0.lowercased().contains("attack") })
    }

    func testRejectedAssessmentKeepsTheRawFixAndMayNotAnchor() throws {
        let rejected = try decode(IntegrityAssessment.self, "integrity-rejected-jump.json")
        XCTAssertFalse(rejected.mayAnchorOthers)
        XCTAssertEqual(rejected.evaluatedFix?.method, .gnss)
        XCTAssertEqual(rejected.fixTimestamp, rejected.evaluatedFix?.timestamp)
        XCTAssertTrue(try decode(IntegrityAssessment.self, "integrity-trusted.json").mayAnchorOthers)
    }

    func testFreshnessAddsHoldTimesThenLocalAge() {
        let produced = Freshness(ageAtHandoff: 0.4, maxAge: 10)
        let relayed = produced.handedOn(heldFor: 1.1).handedOn(heldFor: 0.5)
        XCTAssertEqual(relayed.ageAtHandoff, 2.0, accuracy: 1e-9)
        XCTAssertEqual(relayed.age(receivedAt: 100, now: 103), 5.0, accuracy: 1e-9)
        XCTAssertFalse(relayed.isStale(receivedAt: 100, now: 108))
        XCTAssertTrue(relayed.isStale(receivedAt: 100, now: 108.5))
        // A receiver clock that reads earlier than the receipt never makes a record younger.
        XCTAssertEqual(relayed.age(receivedAt: 100, now: 99), 2.0, accuracy: 1e-9)
    }

    func testUncertaintyConversions() {
        XCTAssertEqual(PositionUncertainty.r95(fromSigma: 1), 2.4477, accuracy: 1e-4)
        XCTAssertEqual(PositionUncertainty.r95(fromRadius68: 10), 16.21, accuracy: 0.01)
        let isotropic = PositionUncertainty(covariance: FloorCovariance(xx: 4, xz: 0, zz: 4))
        XCTAssertEqual(isotropic.r95, 2 * 2.4477, accuracy: 1e-3)
        // An ellipse is covered by the circle around its long axis.
        let ellipse = FloorCovariance(xx: 9, xz: 0, zz: 1)
        XCTAssertEqual(PositionUncertainty(covariance: ellipse).r95, 3 * 2.4477, accuracy: 1e-3)
    }

    func testProvenanceFlagsPropagateAndContributorsMerge() {
        let gps = Provenance(producerId: "phone-a", algorithm: "corelocation@1", gnssDependent: true)
        let sim = Provenance(producerId: "phone-c", algorithm: "scenario@1", gnssDependent: false, simulated: true)
        let derived = Provenance.derived(producerId: "phone-b", algorithm: "ghostcore-proximity@1", from: [gps, sim])
        XCTAssertTrue(derived.gnssDependent)
        XCTAssertTrue(derived.simulated)
        XCTAssertEqual(derived.contributors, ["phone-b", "phone-a", "phone-c"])
        XCTAssertTrue(derived.contains(device: "phone-a"))
        XCTAssertNoThrow(try derived.validate())

        let many = (0..<30).map { Provenance(producerId: "p\($0)", algorithm: "x@1", gnssDependent: false) }
        let capped = Provenance.derived(producerId: "me", algorithm: "x@1", from: many)
        XCTAssertEqual(capped.contributors.count, GhostCoreContract.maxContributors)
        XCTAssertEqual(capped.contributors.first, "me")
        XCTAssertFalse(capped.gnssDependent)
    }

    func testRelayCopyKeepsIdentityAndRefusesLoops() throws {
        let message = try decode(RelayMessage.self, "relay-integrity.json")
        let copy = try XCTUnwrap(message.relayed(by: "phone-a", heldFor: 0.3))
        XCTAssertEqual(copy.messageId, message.messageId)
        XCTAssertEqual(copy.originId, message.originId)
        XCTAssertEqual(copy.epochId, message.epochId)
        XCTAssertEqual(copy.sequence, message.sequence)
        XCTAssertEqual(copy.payload, message.payload)
        XCTAssertEqual(copy.hopsRemaining, message.hopsRemaining - 1)
        XCTAssertEqual(copy.path, ["phone-b", "phone-a"])
        XCTAssertEqual(copy.freshness.ageAtHandoff, message.freshness.ageAtHandoff + 0.3, accuracy: 1e-9)
        XCTAssertNoThrow(try copy.validate())
        XCTAssertNil(message.relayed(by: "phone-b", heldFor: 0), "already on the path")
        XCTAssertNil(message.relayed(by: "phone-c", heldFor: 0), "back to its origin")
        XCTAssertEqual(copy.source, .fusion)
        XCTAssertEqual(copy.provenance.producerId, "phone-c")
    }

    func testRelayMessagesFitOneMeshPacket() throws {
        for name in ["relay-integrity.json", "relay-observations.json"] {
            let message = try decode(RelayMessage.self, name)
            XCTAssertLessThanOrEqual(try message.encoded().count, GhostCoreContract.maxRelayBytes, name)
            XCTAssertEqual(try RelayMessage.decode(try message.encoded()), message)
        }
        // Sixteen full snapshots do not fit; the relay has to split them.
        let observation = try decode(PeerObservation.self, "peer-observation.json")
        let message = try decode(RelayMessage.self, "relay-observations.json")
        let full = RelayMessage(messageId: message.messageId, originId: message.originId, epochId: message.epochId,
                                sequence: 58, timestamp: message.timestamp, frameId: message.frameId,
                                hopsRemaining: 4, freshness: message.freshness,
                                payload: .observations(Array(repeating: observation, count: 16)))
        XCTAssertThrowsError(try full.encoded()) { XCTAssertEqual($0 as? GhostCoreContractError, .tooLarge) }
    }

    func testPredictionTravelsWithoutItsCloud() throws {
        let prediction = try decode(Prediction.self, "prediction-kalman.json")
        XCTAssertEqual(prediction.horizon, 60, accuracy: 1e-9)
        let make = { (p: Prediction) in
            RelayMessage(originId: "phone-a", epochId: UUID().uuidString, sequence: 1, timestamp: p.timestamp,
                         frameId: p.frameId, hopsRemaining: 4, freshness: Freshness(maxAge: 15), payload: .prediction(p))
        }
        XCTAssertThrowsError(try make(prediction).validate())
        XCTAssertNoThrow(try make(prediction.withoutCloud).validate())
        let asPosition = prediction.asPositionEstimate
        XCTAssertNoThrow(try asPosition.validate())
        XCTAssertEqual(asPosition.kind, .predicted)
        XCTAssertEqual(asPosition.dashboardSource, .none)
    }

    func testOnlyMeasuredGNSSReachesTheDashboardAsGPS() throws {
        XCTAssertEqual(try decode(PositionEstimate.self, "position-gnss-raw.json").dashboardSource, .gps)
        XCTAssertEqual(try decode(PositionEstimate.self, "position-ble-ambiguous.json").dashboardSource, .none)
        let provenance = Provenance(producerId: "phone-a", algorithm: "typed@1", gnssDependent: false)
        let typed = PositionEstimate(subjectId: "phone-a", timestamp: 1_793_001_600, frameId: "hervanta-v1",
                                     kind: .declared, method: .manual, position: Position(x: 1, y: 0, z: 2),
                                     uncertainty: PositionUncertainty(r95: 2), source: .manual,
                                     freshness: Freshness(maxAge: 30), provenance: provenance)
        XCTAssertNoThrow(try typed.validate())
        XCTAssertEqual(typed.dashboardSource, .manual)
        // Wire v4 has a uwb source; a measured UWB fix is not a typed spot.
        let ranged = PositionEstimate(subjectId: "phone-a", timestamp: 1_793_001_600, frameId: "hervanta-v1",
                                      kind: .measured, method: .uwb, position: Position(x: 1, y: 0, z: 2),
                                      uncertainty: PositionUncertainty(r95: 0.5), source: .uwb,
                                      freshness: Freshness(maxAge: 30), provenance: provenance)
        XCTAssertNoThrow(try ranged.validate())
        XCTAssertEqual(ranged.dashboardSource, .uwb)
    }

    func testFrameIdsFollowTheDashboardPattern() {
        XCTAssertTrue(GhostCoreContract.isValidFrameId("hervanta-v1"))
        XCTAssertTrue(GhostCoreContract.isValidFrameId("demo.room_2"))
        XCTAssertFalse(GhostCoreContract.isValidFrameId(""))
        XCTAssertFalse(GhostCoreContract.isValidFrameId("hervanta v1"))
        XCTAssertFalse(GhostCoreContract.isValidFrameId("hervantä"))
        XCTAssertFalse(GhostCoreContract.isValidFrameId(String(repeating: "a", count: 65)))
    }
}
