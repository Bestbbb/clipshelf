import XCTest
@testable import ClipShelf

final class PinboardTabReorderPlanTests: XCTestCase {
    func testMovesAcrossSeveralBoardsWithCompleteFrozenOrder() throws {
        let ids = (0..<6).map { _ in UUID() }
        let plan = try XCTUnwrap(PinboardTabReorderPlan.moving(ids[1], in: ids, toInsertionIndex: 5))
        XCTAssertEqual(plan.ids, [ids[0], ids[2], ids[3], ids[4], ids[1], ids[5]])
        XCTAssertEqual(plan.expectedOrder, ids)
    }

    func testFirstAndLastInsertionBoundaries() throws {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(try XCTUnwrap(PinboardTabReorderPlan.moving(ids[3], in: ids, toInsertionIndex: 0)).ids,
                       [ids[3], ids[0], ids[1], ids[2]])
        XCTAssertEqual(try XCTUnwrap(PinboardTabReorderPlan.moving(ids[0], in: ids, toInsertionIndex: ids.count)).ids,
                       [ids[1], ids[2], ids[3], ids[0]])
    }

    func testBothSidesOfOriginalSlotAreNoMovement() {
        let ids = (0..<4).map { _ in UUID() }
        for index in ids.indices {
            XCTAssertNil(PinboardTabReorderPlan.moving(ids[index], in: ids, toInsertionIndex: index))
            XCTAssertNil(PinboardTabReorderPlan.moving(ids[index], in: ids, toInsertionIndex: index + 1))
        }
    }

    func testInvalidOrPartialIdentityCannotProduceAnOrder() {
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertNil(PinboardTabReorderPlan.moving(UUID(), in: ids, toInsertionIndex: 0))
        XCTAssertNil(PinboardTabReorderPlan.moving(ids[0], in: [ids[0], ids[0]], toInsertionIndex: 2))
        XCTAssertNil(PinboardTabReorderPlan.moving(ids[0], in: ids, toInsertionIndex: -1))
        XCTAssertNil(PinboardTabReorderPlan.moving(ids[0], in: ids, toInsertionIndex: 4))
        XCTAssertNil(PinboardTabReorderPlan.moving(ids[0], in: [], toInsertionIndex: 0))
        XCTAssertNil(PinboardTabReorderPlan.moving(ids[0], in: [ids[0]], toInsertionIndex: 1))
    }

    func testEveryMovePreservesAllOtherRelativePositions() throws {
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            for insertion in 0...ids.count {
                guard let plan = PinboardTabReorderPlan.moving(id, in: ids, toInsertionIndex: insertion) else { continue }
                XCTAssertEqual(plan.ids.count, ids.count)
                XCTAssertEqual(Set(plan.ids), Set(ids))
                XCTAssertEqual(plan.ids.filter { $0 != id }, ids.filter { $0 != id })
                XCTAssertEqual(plan.expectedOrder, ids)
            }
        }
    }
}
