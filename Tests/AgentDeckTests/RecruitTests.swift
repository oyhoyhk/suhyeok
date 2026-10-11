import Foundation
import XCTest
@testable import AgentDeck

final class RecruitTests: XCTestCase {
    private var ledger: Ledger!
    private let roster = (0..<12).map { "hero\($0)" }

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recruit-\(UUID().uuidString).jsonl")
        ledger = Ledger(url: url, signer: SoftwareSigner())
    }

    private func fund(_ n: Int) throws { try ledger.append(kind: .earn, source: "log", amount: n) }

    func testStartsWithFreeCharacters() {
        XCTAssertEqual(Recruit.unlocked(roster: roster, ledger: ledger), Set(0..<Recruit.freeCount))
    }

    func testRecruitSpendsAndUnlocks() throws {
        try fund(Recruit.price(recruited: 0) * 2)
        try Recruit.hire("hero8", roster: roster, ledger: ledger)
        XCTAssertEqual(ledger.balance, Recruit.price(recruited: 0))
        XCTAssertEqual(Recruit.unlocked(roster: roster, ledger: ledger).count, Recruit.freeCount + 1)
        XCTAssertTrue(Recruit.unlocked(roster: roster, ledger: ledger).contains(8))
    }

    func testPriceRisesWithEachHire() throws {
        try fund(10_000)
        try Recruit.hire("hero8", roster: roster, ledger: ledger)
        XCTAssertEqual(Recruit.nextPrice(roster: roster, ledger: ledger), Recruit.price(recruited: 1))
        XCTAssertGreaterThan(Recruit.price(recruited: 1), Recruit.price(recruited: 0))
    }

    func testCannotHireTwiceOrHireFreeOrUnknown() throws {
        try fund(10_000)
        try Recruit.hire("hero8", roster: roster, ledger: ledger)
        XCTAssertThrowsError(try Recruit.hire("hero8", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .alreadyHired) }
        XCTAssertThrowsError(try Recruit.hire("hero0", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .alreadyHired) }
        XCTAssertThrowsError(try Recruit.hire("nobody", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .unknown) }
    }

    func testNotEnoughCrystalsLeavesLedgerUntouched() throws {
        try fund(Recruit.price(recruited: 0) - 1)
        let before = ledger.entries.count
        XCTAssertThrowsError(try Recruit.hire("hero8", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Ledger.Failure, .insufficient) }
        XCTAssertEqual(ledger.entries.count, before)
    }

    func testServerConfirmationGatesTheSpend() throws {
        try fund(10_000)
        struct Offline: Error {}
        let before = ledger.entries.count
        XCTAssertThrowsError(try Recruit.hire("hero8", roster: roster, ledger: ledger, confirm: { _, _ in throw Offline() }))
        XCTAssertEqual(ledger.entries.count, before)

        var asked: (String, Int)?
        try Recruit.hire("hero8", roster: roster, ledger: ledger, confirm: { asked = ($0, $1) })
        XCTAssertEqual(asked?.0, "hero8")
        XCTAssertEqual(asked?.1, Recruit.price(recruited: 0))
    }
}
