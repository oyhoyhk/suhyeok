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

    func testRecruitSpendsAndUnlocks() async throws {
        try fund(Recruit.price(recruited: 0) * 2)
        try await Recruit.hire("hero8", roster: roster, ledger: ledger)
        XCTAssertEqual(ledger.balance, Recruit.price(recruited: 0))
        XCTAssertEqual(Recruit.unlocked(roster: roster, ledger: ledger).count, Recruit.freeCount + 1)
        XCTAssertTrue(Recruit.unlocked(roster: roster, ledger: ledger).contains(8))
    }

    func testPriceRisesWithEachHire() async throws {
        try fund(10_000)
        try await Recruit.hire("hero8", roster: roster, ledger: ledger)
        XCTAssertEqual(Recruit.nextPrice(roster: roster, ledger: ledger), Recruit.price(recruited: 1))
        XCTAssertGreaterThan(Recruit.price(recruited: 1), Recruit.price(recruited: 0))
    }

    func testCannotHireTwiceOrHireFreeOrUnknown() async throws {
        try fund(10_000)
        try await Recruit.hire("hero8", roster: roster, ledger: ledger)
        await assertThrows(try await Recruit.hire("hero8", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .alreadyHired) }
        await assertThrows(try await Recruit.hire("hero0", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .alreadyHired) }
        await assertThrows(try await Recruit.hire("nobody", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Recruit.Failure, .unknown) }
    }

    func testNotEnoughCrystalsLeavesLedgerUntouched() async throws {
        try fund(Recruit.price(recruited: 0) - 1)
        let before = ledger.entries.count
        await assertThrows(try await Recruit.hire("hero8", roster: roster, ledger: ledger)) { XCTAssertEqual($0 as? Ledger.Failure, .insufficient) }
        XCTAssertEqual(ledger.entries.count, before)
    }

    func testServerConfirmationGatesTheSpend() async throws {
        try fund(10_000)
        struct Offline: Error {}
        let before = ledger.entries.count
        await assertThrows(try await Recruit.hire("hero8", roster: roster, ledger: ledger, confirm: { _, _ in throw Offline() }))
        XCTAssertEqual(ledger.entries.count, before)

        var asked: (String, Int)?
        try await Recruit.hire("hero8", roster: roster, ledger: ledger, confirm: { asked = ($0, $1) })
        XCTAssertEqual(asked?.0, "hero8")
        XCTAssertEqual(asked?.1, Recruit.price(recruited: 0))
    }

    func testAssignerOnlyUsesUnlockedCharacters() {
        var assigner = CharacterAssigner()
        let sessions = (0..<10).map {
            AgentSession(id: "s\($0)", agent: .claude, name: "", cwd: "/", status: .busy, startedAt: Date(timeIntervalSince1970: Double($0)),
                         updatedAt: nil, lastUser: nil, lastAssistant: nil, estimated: false)
        }
        let allowed = Set(0..<Recruit.freeCount)
        let picks = assigner.update(sessions, allowed: allowed, rosterCount: 32)
        XCTAssertEqual(picks.count, 10)
        XCTAssertTrue(picks.values.allSatisfy(allowed.contains))
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T, _ check: (Error) -> Void = { _ in },
                                 line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected an error", line: line) } catch { check(error) }
    }
}
