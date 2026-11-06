import Foundation
import XCTest
@testable import AgentDeck

final class SubagentTests: XCTestCase {
    private var dir: URL!
    private var transcript: String { dir.appendingPathComponent("s1.jsonl").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try "{}\n".write(toFile: transcript, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Shapes from a live session (Claude Code 2.1.310, 2026-11-05): a running subagent's newest assistant entry calls
    /// a tool and is followed by request records; a finished one ends with end_turn text.
    private func agent(_ id: String, stop: String, content: String, description: String?, age: TimeInterval = 0,
                       finished: Bool = false) throws {
        let path = dir.appendingPathComponent("s1/subagents/agent-\(id).jsonl").path
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"\#(stop)","content":[\#(content)]}}"#,
            #"{"type":"api-request","agentId":"\#(id)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
        if let description {
            try #"{"agentType":"general-purpose","description":"\#(description)"\#(finished ? #","finished":true"# : "")}"#
                .write(toFile: path.replacingOccurrences(of: ".jsonl", with: ".meta.json"), atomically: true, encoding: .utf8)
        }
    }

    private let bash = #"{"type":"tool_use","name":"Bash","input":{"command":"ls","description":"Check mesh helper signatures"}}"#

    func testRunningSubagentShowsItsTaskAndTool() throws {
        try agent("a1", stop: "tool_use", content: bash, description: "Expand gameplay loop")
        let work = ClaudeSource.subagents(transcript: transcript)
        XCTAssertEqual(work.map(\.title), ["Expand gameplay loop"])
        XCTAssertEqual(work.first?.action?.kind, .shell)
        XCTAssertEqual(work.first?.action?.detail, "Bash · Check mesh helper signatures")
    }

    func testFinishedSubagentIsHidden() throws {
        try agent("a2", stop: "end_turn", content: #"{"type":"text","text":"done"}"#, description: "Review")
        XCTAssertTrue(ClaudeSource.subagents(transcript: transcript).isEmpty)
    }

    func testMetaFinishedIsHiddenEvenMidTool() throws {
        // Claude Code adds "finished": true to the meta file when a subagent ends (seen 2026-11-06); it wins over the log tail.
        try agent("a5", stop: "tool_use", content: bash, description: "Stopped", finished: true)
        XCTAssertTrue(ClaudeSource.subagents(transcript: transcript).isEmpty)
    }

    func testSubagentSilentTooLongIsHidden() throws {
        // A stopped subagent never writes end_turn; its log just stops growing.
        try agent("a3", stop: "tool_use", content: bash, description: "Stopped", age: ClaudeSource.subagentStale + 60)
        XCTAssertTrue(ClaudeSource.subagents(transcript: transcript).isEmpty)
    }

    func testMissingMetaFallsBackToGenericTitle() throws {
        try agent("a4", stop: "tool_use", content: bash, description: nil)
        XCTAssertEqual(ClaudeSource.subagents(transcript: transcript).map(\.title), [String(localized: "서브에이전트")])
    }

    func testNoSubagentFolder() {
        XCTAssertTrue(ClaudeSource.subagents(transcript: dir.appendingPathComponent("none.jsonl").path).isEmpty)
    }
}
