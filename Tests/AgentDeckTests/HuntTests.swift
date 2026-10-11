import Foundation
import XCTest
@testable import AgentDeck

final class HuntTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    /// A private copy, so each test scans from a fresh incremental state.
    private func copy(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try FileManager.default.copyItem(at: fixture(name), to: url)
        return url
    }

    func testClaudeSessionEarnsActivityTurnsAndCommits() throws {
        let p = HuntClock.progress(path: try copy("claude-session.jsonl").path)
        XCTAssertEqual(Int(p.activeSeconds), 20 * 60)
        XCTAssertEqual(p.crystals, 2)   // 20 active minutes in the low ground
        XCTAssertEqual(p.turns, 2)      // turn_duration records, not the repeated end_turn
        XCTAssertEqual(p.commits, 1)    // the failed commit and `git log --grep='git commit'` do not count
        XCTAssertEqual(p.earned, 2 + 2 * Hunt.turnBonus + 1 * Hunt.commitBonus)
        XCTAssertEqual(p.mana, 160)     // output tokens, one count per message id
    }

    func testCodexRolloutEarnsTurns() throws {
        let p = HuntClock.progress(path: try copy("codex-rollout.jsonl").path)
        XCTAssertEqual(p.turns, 2)
        XCTAssertEqual(p.commits, 0)
        XCTAssertEqual(p.crystals, 1)   // 16 active minutes
        XCTAssertEqual(p.earned, 1 + 2 * Hunt.turnBonus)
        XCTAssertEqual(p.mana, 90)      // last cumulative output total
    }

    func testIncrementalScanMatchesFullScan() throws {
        let full = HuntClock.progress(path: try copy("claude-session.jsonl").path)

        let lines = try String(contentsOf: fixture("claude-session.jsonl"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        // Cut between a tool_use and its tool_result, so the pending commit must survive the gap.
        try (lines[0..<2].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = HuntClock.progress(path: url.path)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(lines[2...].joined(separator: "\n").utf8))
        try h.close()
        let incremental = HuntClock.progress(path: url.path)

        XCTAssertEqual(incremental.earned, full.earned)
        XCTAssertEqual(incremental.commits, full.commits)
        XCTAssertEqual(incremental.turns, full.turns)
        XCTAssertEqual(incremental.mana, full.mana)
    }

    func testGitCommitCommandMatching() {
        XCTAssertTrue(HuntClock.isCommit("git commit -m x"))
        XCTAssertTrue(HuntClock.isCommit("cd a && git add . && git commit -q -m \"y\""))
        XCTAssertTrue(HuntClock.isCommit("git -C repo commit -m wip"))
        XCTAssertFalse(HuntClock.isCommit("git log --grep='git commit'"))
        XCTAssertFalse(HuntClock.isCommit("git commit --dry-run"))
        XCTAssertFalse(HuntClock.isCommit("git commit-tree abc"))
    }
}
