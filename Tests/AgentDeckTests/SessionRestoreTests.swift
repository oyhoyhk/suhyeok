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
        XCTAssertEqual(live, [.init(agent: "Claude", cwd: "/repo/sh-a", conversation: "conv-a", title: "title-claude-1")])
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
}
