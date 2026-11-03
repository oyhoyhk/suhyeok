import Foundation
import XCTest
@testable import AgentDeck

final class ActivityTests: XCTestCase {
    private func session(_ status: SessionStatus, since ago: TimeInterval, work: Bool? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .claude, name: "s", cwd: "/x", status: status, startedAt: nil,
                     updatedAt: Date(timeIntervalSinceNow: -ago), lastUser: nil, lastAssistant: nil, estimated: false,
                     backgroundWork: work)
    }

    func testBackgroundWorkIsWorkingHoweverLong() {
        XCTAssertEqual(session(.shell, since: 20 * 60, work: true).activity, .working)
        XCTAssertEqual(session(.shell, since: 3 * 86400, work: true).activity, .working)
    }

    func testWaitLoopsAloneAreNotWork() {
        XCTAssertEqual(session(.shell, since: 60, work: false).activity, .waiting)
        XCTAssertEqual(session(.shell, since: 20 * 60, work: false).activity, .resting)
    }

    func testUnknownShellCountsAsWorkUntilTheLimit() {
        XCTAssertEqual(session(.shell, since: Activity.waitLoopLimit - 60).activity, .working)
        XCTAssertEqual(session(.shell, since: Activity.waitLoopLimit + 60).activity, .resting)
    }

    func testIdleIsUnchanged() {
        XCTAssertEqual(session(.idle, since: 60).activity, .waiting)
        XCTAssertEqual(session(.idle, since: 20 * 60).activity, .resting)
    }
}

final class BackgroundShellsTests: XCTestCase {
    // Shapes from a live process table (2026-11-03): an experiment, a pgrep wait loop, a stdin read, and an MCP server.
    private let ps = """
      100     1 05-00:20:03 claude --dangerously-skip-permissions
      200   100    17:02 /bin/zsh -c source /Users/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'python3 run.py > full.jsonl'
      201   200    17:01 /opt/homebrew/bin/python3 run.py
      300   100 04-07:55:10 /bin/zsh -c source /Users/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'until ! pgrep -f "render.sh . render"; do sleep 20; done'
      301   300    00:05 sleep 20
      400   100 05-12:33:28 /bin/zsh -c source /Users/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'cat > /dev/null; python3 -I -'
      401   400 05-12:33:28 cat
      500   100 07-17:17:14 node /Users/u/node_modules/.bin/../agentation-mcp/dist/cli.js server
    """

    func testElapsed() {
        XCTAssertEqual(BackgroundShells.elapsed("00:05"), 5)
        XCTAssertEqual(BackgroundShells.elapsed("17:02"), 17 * 60 + 2)
        XCTAssertEqual(BackgroundShells.elapsed("08:25:48"), 8 * 3600 + 25 * 60 + 48)
        XCTAssertEqual(BackgroundShells.elapsed("05-00:20:03"), 5 * 86400 + 20 * 60 + 3)
        XCTAssertNil(BackgroundShells.elapsed("bogus"))
    }

    func testClassifiesShellsOfOneClaudeProcess() {
        let shells = BackgroundShells.shells(of: 100, in: BackgroundShells.parse(ps))
        XCTAssertEqual(shells.map(\.pid), [200, 300, 400])  // the MCP server is not a Bash command
        XCTAssertEqual(shells.map(\.waiting), [false, true, true])
        XCTAssertEqual(shells[1].tree, [300, 301])
        XCTAssertEqual(shells[2].age, 477_208)  // 5-12:33:28
        XCTAssertEqual(BackgroundShells.working(shells), true)
        XCTAssertEqual(BackgroundShells.working(Array(shells.dropFirst())), false)
        XCTAssertNil(BackgroundShells.working([]))
    }

    func testScriptIsTheCommandInsideTheWrapper() {
        let shells = BackgroundShells.shells(of: 100, in: BackgroundShells.parse(ps))
        XCTAssertEqual(BackgroundShells.script(shells[1].command), #"until ! pgrep -f "render.sh . render"; do sleep 20; done'"#)
    }
}

final class ReapTests: XCTestCase {
    /// A stand-in claude process with one Bash-style wait loop and one real job; only the loop dies.
    func testReapKillsOnlyOldWaitLoops() throws {
        let log = (NSTemporaryDirectory() as NSString).appendingPathComponent("reap-\(UUID().uuidString.prefix(8)).log")
        let saved = (BackgroundShells.logPath, BackgroundShells.reaping, UserDefaults.standard.object(forKey: "waitLoopHours"))
        defer {
            BackgroundShells.logPath = saved.0; BackgroundShells.reaping = saved.1
            UserDefaults.standard.set(saved.2, forKey: "waitLoopHours")
            try? FileManager.default.removeItem(atPath: log)
        }
        BackgroundShells.logPath = log
        BackgroundShells.reaping = true
        UserDefaults.standard.set(0.0001, forKey: "waitLoopHours")  // 0.36 s

        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", """
            /bin/zsh -c ': /.claude/shell-snapshots/x; sleep 30; :' &
            /bin/zsh -c ': /.claude/shell-snapshots/x; /usr/bin/yes > /dev/null; :' &
            wait
            """]
        try parent.run()
        defer { parent.terminate() }
        Thread.sleep(forTimeInterval: 2.5)

        let before = BackgroundShells.shells(of: parent.processIdentifier, in: BackgroundShells.table())
        XCTAssertEqual(before.map(\.waiting).sorted { !$0 && $1 }, [false, true])
        let s = AgentSession(id: "claude-test", agent: .claude, name: "t", cwd: "/x", status: .shell, startedAt: nil, updatedAt: nil,
                             lastUser: nil, lastAssistant: nil, estimated: false, pid: parent.processIdentifier)
        BackgroundShells.reap([s])
        Thread.sleep(forTimeInterval: 0.5)

        let after = BackgroundShells.shells(of: parent.processIdentifier, in: BackgroundShells.table())
        XCTAssertEqual(after.map(\.waiting), [false])  // the job is left alone
        for pid in after.flatMap(\.tree) { kill(pid, SIGTERM) }
        let entry = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(entry.contains("claude-test /x · pid "), entry)
        XCTAssertTrue(entry.contains("wait loop past 0h · SIGTERM"), entry)
    }
}
