import Foundation
import XCTest
@testable import AgentDeck

final class WalletTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("ledger.jsonl") }
    private let signer = SoftwareSigner()
    private var earned: [String: Int] = [:]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wallet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func wallet() -> Wallet {
        Wallet(ledger: Ledger(url: url, signer: signer)) { [unowned self] in self.earned[$0] ?? 0 }
    }

    private func kinds(_ w: Wallet) -> [String] { w.ledger.entries.dropFirst().map(\.kind) }

    func testSamePathFromTwoSessionsPaysOnce() {
        earned = ["a.jsonl": 12]
        let w = wallet()
        XCTAssertEqual(w.settle(paths: ["a.jsonl", "a.jsonl"]).map(\.amount), [12])
        XCTAssertEqual(w.ledger.balance, 12)
    }

    func testPaysOnlyTheDifference() {
        earned = ["a.jsonl": 10]
        let w = wallet()
        w.settle(paths: ["a.jsonl"])
        earned["a.jsonl"] = 12
        XCTAssertEqual(w.settle(paths: ["a.jsonl"]).map(\.amount), [2])
        XCTAssertEqual(w.settle(paths: ["a.jsonl"]), [])
        XCTAssertEqual(w.ledger.balance, 12)
    }

    func testShrunkLogPaysNothing() {
        earned = ["a.jsonl": 10]
        let w = wallet()
        w.settle(paths: ["a.jsonl"])
        earned["a.jsonl"] = 4
        XCTAssertEqual(w.settle(paths: ["a.jsonl"]), [])
        XCTAssertEqual(w.ledger.balance, 10)
    }

    func testBrokenLedgerPaysNothing() throws {
        earned = ["a.jsonl": 10]
        wallet().settle(paths: ["a.jsonl"])
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = lines[1].replacingOccurrences(of: "\"amount\":10", with: "\"amount\":11")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        earned["a.jsonl"] = 20
        let w = wallet()
        XCTAssertEqual(w.settle(paths: ["a.jsonl"]), [])
    }

    func testRestartDoesNotPayTwice() {
        earned = ["a.jsonl": 10, "b.jsonl": 3]
        wallet().settle(paths: ["a.jsonl", "b.jsonl"])
        let w = wallet()  // fresh memory, same ledger file
        XCTAssertEqual(w.settle(paths: ["a.jsonl", "b.jsonl"]), [])
        XCTAssertEqual(w.ledger.balance, 13)
    }

    // MARK: migration

    func testMigrationRecordsGenesisPerLogThenMarksComplete() {
        earned = ["a": 5, "b": 0, "c": 7]
        let w = wallet()
        XCTAssertFalse(w.isMigrated)
        w.migrate(paths: ["a", "b", "c"])
        XCTAssertTrue(w.isMigrated)
        XCTAssertEqual(kinds(w), ["genesis", "genesis", "genesis", "genesis"])  // 3 logs + completion mark
        XCTAssertEqual(w.ledger.balance, 12)
        XCTAssertEqual(w.settle(paths: ["a", "b", "c"]), [])
    }

    func testInterruptedMigrationResumes() {
        earned = ["a": 5, "b": 1, "c": 7]
        let w = wallet()
        var n = 0
        w.migrate(paths: ["a", "b", "c"], shouldContinue: { n += 1; return n <= 1 })
        XCTAssertFalse(w.isMigrated)
        XCTAssertEqual(w.ledger.balance, 5)

        let resumed = wallet()
        resumed.migrate(paths: ["a", "b", "c"])
        XCTAssertTrue(resumed.isMigrated)
        XCTAssertEqual(resumed.ledger.balance, 13)
        XCTAssertEqual(resumed.ledger.entries.filter { $0.source == "a" }.count, 1)
    }

    func testLogsAfterMigrationEarnInsteadOfGenesis() {
        earned = ["a": 5]
        let w = wallet()
        w.migrate(paths: ["a"])
        earned["new"] = 4
        XCTAssertEqual(w.settle(paths: ["new"]).map(\.kind), ["earn"])
        w.migrate(paths: ["a", "new", "later"])  // already complete: a no-op
        XCTAssertEqual(w.ledger.entries.filter { $0.source == "later" }, [])
    }

    func testLiveSettleDuringMigrationIsNotPaidTwice() {
        earned = ["live": 6, "old": 2]
        let w = wallet()
        w.settle(paths: ["live"])          // a running session pays before migration reaches it
        w.migrate(paths: ["old", "live"])
        XCTAssertEqual(w.ledger.balance, 8)
        XCTAssertEqual(w.ledger.entries.filter { $0.source == "live" }.map(\.kind), ["earn"])
    }

    func testTranscriptDiscovery() throws {
        let home = dir.appendingPathComponent("home")
        let fm = FileManager.default
        let claude = home.appendingPathComponent(".claude/projects/-Users-a-proj")
        let codex = home.appendingPathComponent(".codex/sessions/2026/10/01")
        try fm.createDirectory(at: claude.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        for f in [claude.appendingPathComponent("s1.jsonl"), claude.appendingPathComponent("s1/subagents/x.jsonl"),
                  codex.appendingPathComponent("rollout-1.jsonl"), codex.appendingPathComponent("notes.txt")] {
            fm.createFile(atPath: f.path, contents: Data())
        }
        // The temp dir sits behind /var → /private/var, so compare the part below "home".
        let found = Wallet.transcripts(home: home).map { String($0[$0.range(of: "/home")!.upperBound...]) }.sorted()
        XCTAssertEqual(found, ["/.claude/projects/-Users-a-proj/s1.jsonl", "/.codex/sessions/2026/10/01/rollout-1.jsonl"])
    }
}
