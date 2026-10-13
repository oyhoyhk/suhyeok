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
}
