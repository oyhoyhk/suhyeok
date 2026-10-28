import Foundation
import XCTest
@testable import AgentDeck

final class SessionRestoreTests: XCTestCase {
    private var savedPath: String!

    override func setUp() {
        savedPath = SessionRestore.path
        SessionRestore.path = (NSTemporaryDirectory() as NSString).appendingPathComponent("restore-\(UUID().uuidString.prefix(8))/open.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (SessionRestore.path as NSString).deletingLastPathComponent)
        SessionRestore.path = savedPath
    }

    private func session(_ id: String, hosted: String?, conversation: String?, log: Bool = true) -> AgentSession {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(id).jsonl")
        if log { FileManager.default.createFile(atPath: path, contents: Data()) } else { try? FileManager.default.removeItem(atPath: path) }
        return AgentSession(id: id, agent: .claude, name: "title-\(id)", cwd: "/x", status: .idle, startedAt: nil, updatedAt: nil,
                            lastUser: nil, lastAssistant: nil, estimated: false, transcriptPath: path, hostedName: hosted,
                            conversationId: conversation)
    }

    private func hosted(_ name: String, _ agent: Agent?) -> TmuxEngine.Hosted {
        TmuxEngine.Hosted(name: name, agent: agent, cwd: "/repo/\(name)", title: name, created: Date())
    }

    func testLiveKeepsAgentsWithAConversation() {
        let live = SessionRestore.live(
            hosted: [hosted("sh-a", .claude), hosted("sh-b", .claude), hosted("sh-shell", nil), hosted("sh-c", .claude),
                     hosted("sh-d", .claude)],
            sessions: [session("claude-1", hosted: "sh-a", conversation: "conv-a"),
                       session("claude-2", hosted: "sh-b", conversation: nil),                  // no conversation yet
                       session("claude-3", hosted: nil, conversation: "elsewhere"),             // another terminal
                       session("claude-4", hosted: "sh-d", conversation: "conv-d", log: false)])  // nothing said yet
        XCTAssertEqual(live, [.init(agent: "Claude", cwd: "/repo/sh-a", conversation: "conv-a", title: "title-claude-1",
                                    log: (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-1.jsonl"))])
    }

    func testMergedKeepsUnansweredClosedSessions() {
        let a = SessionRestore.Entry(agent: "Claude", cwd: "/a", conversation: "a", title: "A")
        let b = SessionRestore.Entry(agent: "Codex", cwd: "/b", conversation: "b", title: "B")
        let fresh = SessionRestore.Entry(agent: "Claude", cwd: "/n", conversation: "n", title: "N")
        XCTAssertEqual(SessionRestore.merged(live: [fresh, a], pending: [a, b]), [fresh, a, b])
    }

    func testSaveAndLoad() {
        XCTAssertEqual(SessionRestore.load(), [])
        let e = [SessionRestore.Entry(agent: "Claude", cwd: "/한글 폴더", conversation: "c1", title: "로그인 버그")]
        SessionRestore.save(e)
        XCTAssertEqual(SessionRestore.load(), e)
    }

    func testLiveKeepsOneEntryPerConversation() {
        // The same conversation open in two panes (a second process resumed it): reopening both would fork it.
        let live = SessionRestore.live(hosted: [hosted("sh-a", .claude), hosted("sh-b", .claude)],
                                       sessions: [session("claude-1", hosted: "sh-a", conversation: "same"),
                                                  session("claude-2", hosted: "sh-b", conversation: "same")])
        XCTAssertEqual(live.map(\.conversation), ["same"])
    }

    func testResumeFlagsKeepClaudeModelAndEffort() throws {
        let dir = (SessionRestore.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"}}"#
            .write(toFile: dir + "/c1.json", atomically: true, encoding: .utf8)
        let e = SessionRestore.Entry(agent: "Claude", cwd: "/x", conversation: "c1", title: "t")
        XCTAssertEqual(SessionRestore.resumeFlags(e, statusDir: dir), ["--model", "claude-opus-5-5", "--effort", "high"])
        let unknown = SessionRestore.Entry(agent: "Claude", cwd: "/x", conversation: "none", title: "t")
        XCTAssertEqual(SessionRestore.resumeFlags(unknown, statusDir: dir), [])  // nothing known: the defaults, as before
    }

    func testResumeFlagsKeepCodexModelAndEffort() throws {
        let dir = (SessionRestore.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rollout = dir + "/rollout.jsonl"
        try [#"{"type":"turn_context","payload":{"model":"gpt-old","effort":"low"}}"#,
             #"{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"medium"}}"#]
            .joined(separator: "\n").appending("\n").write(toFile: rollout, atomically: true, encoding: .utf8)
        let e = SessionRestore.Entry(agent: "Codex", cwd: "/x", conversation: "t1", title: "t", log: rollout)
        XCTAssertEqual(SessionRestore.resumeFlags(e), ["-m", "gpt-6-astra", "-c", "model_reasoning_effort=\"medium\""])
    }

    func testOldRecordWithoutLogStillLoads() throws {
        let dir = (SessionRestore.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"[{"agent":"Claude","cwd":"/a","conversation":"c","title":"T"}]"#.write(toFile: SessionRestore.path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionRestore.load(), [.init(agent: "Claude", cwd: "/a", conversation: "c", title: "T")])
    }
}
