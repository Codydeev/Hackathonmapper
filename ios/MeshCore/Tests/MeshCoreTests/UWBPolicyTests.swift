import Foundation
import XCTest
import MeshCore

final class UWBPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func peer(_ id: String, rssi: Double? = -70, anchor: Bool = false, unplaced: Bool = false,
                      measuringFor seconds: TimeInterval? = nil) -> UWBPeerCandidate {
        UWBPeerCandidate(id: id, rssi: rssi, isDirectionAnchor: anchor, touchesUnplaced: unplaced,
                         measuringSince: seconds.map { now.addingTimeInterval(-$0) })
    }

    func testRanksAnchorThenUnplacedThenRSSI() {
        let candidates = [
            peer("strong", rssi: -40),
            peer("weak", rssi: -90),
            peer("unplaced", rssi: -85, unplaced: true),
            peer("anchor", rssi: -95, anchor: true),
            peer("silent", rssi: nil)
        ]
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 1, now: now), ["anchor"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 2, now: now), ["anchor", "unplaced"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 3, now: now), ["anchor", "unplaced", "strong"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 4, now: now), ["anchor", "unplaced", "strong", "weak"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 10, now: now).count, 5)
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 0, now: now), [])
        XCTAssertEqual(UWBSessionPolicy.select([], budget: 4, now: now), [])
    }

    func testTiesAreDeterministicAndDuplicatesCountOnce() {
        let candidates = [peer("b", rssi: -60), peer("a", rssi: -60), peer("a", rssi: -30)]
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 1, now: now), ["a"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 2, now: now), ["a", "b"])
    }

    func testMeasuringSessionHoldsItsSlotAgainstSameClass() {
        // "held" is weaker but measured for 5 s, so a stronger newcomer of the same class waits.
        let candidates = [peer("newcomer", rssi: -50), peer("held", rssi: -80, measuringFor: 5)]
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 1, now: now), ["held"])
        // After the hold time it competes on rank again.
        let expired = [peer("newcomer", rssi: -50), peer("held", rssi: -80, measuringFor: 25)]
        XCTAssertEqual(UWBSessionPolicy.select(expired, budget: 1, now: now), ["newcomer"])
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 1, now: now, minHold: 3), ["newcomer"])
    }

    func testHigherClassDisplacesAHeldSession() {
        let anchor = [peer("anchor", rssi: -95, anchor: true), peer("held", rssi: -40, measuringFor: 5)]
        XCTAssertEqual(UWBSessionPolicy.select(anchor, budget: 1, now: now), ["anchor"])
        let unplaced = [peer("lost", rssi: -95, unplaced: true), peer("held", rssi: -40, measuringFor: 5)]
        XCTAssertEqual(UWBSessionPolicy.select(unplaced, budget: 1, now: now), ["lost"])
        // A held plain link displaces the weakest plain newcomer, never the higher-class one.
        let mixed = [peer("lost", unplaced: true), peer("x", rssi: -40), peer("y", rssi: -50),
                     peer("heldPlain", rssi: -99, measuringFor: 2)]
        XCTAssertEqual(UWBSessionPolicy.select(mixed, budget: 3, now: now), ["lost", "x", "heldPlain"])
        XCTAssertEqual(UWBSessionPolicy.select(mixed, budget: 1, now: now), ["lost"])
    }

    func testHeldSessionsNeverDisplaceEachOther() {
        let candidates = [peer("a", rssi: -50, measuringFor: 1), peer("b", rssi: -60, measuringFor: 1),
                          peer("c", rssi: -70, measuringFor: 1)]
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: 2, now: now), ["a", "b"])
    }

    func testBudgetShrinksAfterSessionLimit() {
        XCTAssertEqual(UWBSessionPolicy.initialBudget, 4)
        XCTAssertEqual(UWBSessionPolicy.reducedBudget(active: 4), 3)
        XCTAssertEqual(UWBSessionPolicy.reducedBudget(active: 2), 1)
        XCTAssertEqual(UWBSessionPolicy.reducedBudget(active: 1), 1)
        XCTAssertEqual(UWBSessionPolicy.reducedBudget(active: 0), 1)
        let candidates = (0..<6).map { peer("p\($0)", rssi: Double(-50 - $0)) }
        let budget = UWBSessionPolicy.reducedBudget(active: 4)
        XCTAssertEqual(UWBSessionPolicy.select(candidates, budget: budget, now: now), ["p0", "p1", "p2"])
    }
}
