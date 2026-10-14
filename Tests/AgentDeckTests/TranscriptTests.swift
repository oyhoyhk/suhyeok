import Foundation
import XCTest
@testable import AgentDeck

/// "!" shell-mode turns are logged as <bash-input>/<bash-stdout> user records; the chat must show them.
final class TranscriptTests: XCTestCase {
    func testShellModeCommandAndOutputAreShown() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<bash-input>tsh status</bash-input>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<bash-stdout>logged in</bash-stdout><bash-stderr>warn</bash-stderr>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<bash-input>true</bash-input>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<bash-stdout></bash-stdout><bash-stderr></bash-stderr>"}}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bang-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let items = TranscriptRenderer.items(path: url.path, agent: .claude).map { [$0.role == .me ? "me" : "result", $0.text] }
        XCTAssertEqual(items, [["me", "! tsh status"], ["result", "logged in\nwarn"],
                               ["me", "! true"], ["result", "(출력 없음)"]])
    }

    /// Pasted text is logged wrapped in <pasted_content id="…"> tags; the chat shows it unwrapped, as typed,
    /// so the pending bubble matches it and the tags never show.
    func testPastedContentIsUnwrapped() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"\n\n<pasted_content id=\"dc3d\">\nbutler status x\n| a | b |\n</pasted_content id=\"dc3d\">"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"이거 봐\n\n<pasted_content id=\"a1\">\nlog line\n</pasted_content id=\"a1\">"}]}}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let items = TranscriptRenderer.items(path: url.path, agent: .claude).map { [$0.role == .me ? "me" : "other", $0.text] }
        XCTAssertEqual(items, [["me", "butler status x\n| a | b |"], ["me", "이거 봐\n\nlog line"]])
    }
}
