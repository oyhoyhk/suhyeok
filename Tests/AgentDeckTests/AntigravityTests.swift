import Foundation
import SQLite3
import XCTest
@testable import AgentDeck

/// A conversation database shaped like agy 1.4.12's (steps and gen_metadata hold protobuf), built from scratch so
/// no real conversation (paths, system prompt) lands in the repo.
final class AntigravityTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("agy-\(UUID().uuidString.prefix(8)).db")
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    /// Length-delimited field: key (number, wire type 2), length, bytes.
    private func field(_ number: Int, _ body: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(body.count) + body }
    private func field(_ number: Int, _ text: String) -> [UInt8] { field(number, Array(text.utf8)) }
    private func varint(_ n: Int) -> [UInt8] {
        var n = n, out: [UInt8] = []
        repeat { out.append(UInt8(n & 0x7f) | (n > 0x7f ? 0x80 : 0)); n >>= 7 } while n > 0
        return out
    }

    private func makeDB(steps: [(Int, [UInt8])], model: String? = nil) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, step_payload blob)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob)", nil, nil, nil)
        func insert(_ sql: String, _ a: Int, _ b: Int?, _ blob: [UInt8]) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(a))
            if let b { sqlite3_bind_int(stmt, 2, Int32(b)) }
            blob.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, b == nil ? 2 : 3, $0.baseAddress, Int32(blob.count), nil) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        for (i, s) in steps.enumerated() { insert("INSERT INTO steps VALUES (?, ?, ?)", i, s.0, s.1) }
        // An integer field before the strings, as in the real records, must be skipped over.
        if let model { insert("INSERT INTO gen_metadata VALUES (?, ?)", 0, nil, field(1, [0x08, 0x96, 0x01] + field(21, model))) }
    }

    private var conversation: [(Int, [UInt8])] {
        [(14, [0x08, 14] + field(19, field(2, "이 폴더 파일 목록"))),
         (15, field(20, field(3, "thinking…") + field(7, field(2, "run_command") + field(3, #"{"CommandLine":"ls","toolSummary":"List files"}"#)))),
         (132, field(140, field(2, field(1, "a.txt\nb.txt")))),
         (15, field(20, field(1, "파일 두 개: a.txt, b.txt")))]
    }

    func testStepsBecomeChatEntries() {
        makeDB(steps: conversation)
        let items = TranscriptRenderer.items(path: path, agent: .antigravity)
        XCTAssertEqual(items.map(\.role), [.me, .tool, .result, .agent])
        XCTAssertEqual(items[0].text, "이 폴더 파일 목록")
        XCTAssertEqual(items[1].text, "run_command · List files")
        XCTAssertEqual(items[2].text, "  ⎿ a.txt\n  ⎿ b.txt")
        XCTAssertEqual(items[3].text, "파일 두 개: a.txt, b.txt")
    }

    func testMalformedPayloadYieldsNothing() {
        makeDB(steps: [(14, [0x9a, 0x01, 0xff, 0xff])])  // field 19 claiming more bytes than there are
        XCTAssertTrue(AntigravitySource.entries(path: path).isEmpty)
    }

    func testRestoreKeepsTheModel() {
        makeDB(steps: conversation, model: "Gemini 3.8 Flash (Low)")
        let e = SessionRestore.Entry(agent: "Antigravity", cwd: "/x", conversation: "c1", title: "t", log: path)
        XCTAssertEqual(SessionRestore.resumeFlags(e), ["--model", "Gemini 3.8 Flash (Low)"])
    }

    func testAgyToolsAnimate() {
        XCTAssertEqual(AgentAction.tool("run_command", input: ["CommandLine": "ls"]).kind, .shell)
        XCTAssertEqual(AgentAction.tool("read_file", input: ["Path": "/a/b.txt"]).detail, "read_file · b.txt")
        XCTAssertEqual(AgentAction.tool("edit_file", input: [:]).kind, .editing)
    }
}
