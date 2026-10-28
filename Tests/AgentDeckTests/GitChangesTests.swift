import Foundation
import XCTest
@testable import AgentDeck

final class GitChangesTests: XCTestCase {
    private var repo: String!

    override func setUp() {
        repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("gc-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        sh("git init -q -b main && git config user.email t@t && git config user.name t"
           + " && printf 'one\\ntwo\\nthree\\n' > keep.txt && echo bye > gone.txt && echo x > 'a b.txt'"
           + " && git add -A && git commit -qm init")
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: repo) }

    @discardableResult
    private func sh(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let out = Pipe()
        p.standardOutput = out
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testParseNumbersBothSides() {
        let diff = """
        diff --git a/s.swift b/s.swift
        index 1..2 100644
        --- a/s.swift
        +++ b/s.swift
        @@ -10,3 +10,3 @@ func f() {
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        \\ No newline at end of file
        diff --git a/img.png b/img.png
        new file mode 100644
        Binary files /dev/null and b/img.png differ
        """
        let files = GitChanges.parse(diff)
        XCTAssertEqual(files.map(\.path), ["s.swift", "img.png"])
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines[1].old, 11); XCTAssertNil(lines[1].new)
        XCTAssertEqual(lines[2].new, 11); XCTAssertNil(lines[2].old)
        XCTAssertEqual(lines[3].old, 12); XCTAssertEqual(lines[3].new, 12)
        XCTAssertEqual(files[0].added, 1); XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[1].status, .added); XCTAssertTrue(files[1].binary)
    }

    func testLoadFindsChangedDeletedAndUntrackedFiles() throws {
        sh("printf 'one\\nTWO\\nthree\\n' > keep.txt && rm gone.txt && echo hi > '새 파일.txt' && echo y >> 'a b.txt'")
        let snap = try GitChanges.load(cwd: repo).get()
        let byPath = Dictionary(uniqueKeysWithValues: snap.files.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), ["keep.txt", "gone.txt", "새 파일.txt", "a b.txt"])
        XCTAssertEqual(byPath["keep.txt"]?.status, .modified)
        XCTAssertEqual(byPath["gone.txt"]?.status, .deleted)
        XCTAssertEqual(byPath["새 파일.txt"]?.status, .untracked)
        XCTAssertEqual(byPath["새 파일.txt"]?.hunks.first?.lines.map(\.text), ["hi"])
        XCTAssertEqual(byPath["keep.txt"]?.hunks.first?.lines.filter { $0.kind == .added }.map(\.text), ["TWO"])
    }

    func testCommitOnlyPicksChosenFiles() throws {
        sh("echo changed > keep.txt && rm gone.txt && echo new > fresh.txt && echo other > other.txt && echo z >> 'a b.txt'")
        let summary = try GitChanges.commit(root: repo, paths: ["gone.txt", "fresh.txt", "a b.txt"], message: "pick some").get()
        XCTAssertTrue(summary.hasSuffix("pick some"))
        XCTAssertEqual(sh("git show --name-status --format= HEAD").split(separator: "\n").sorted(),
                       ["A\tfresh.txt", "D\tgone.txt", "M\ta b.txt"])
        // Left alone: still changed or untracked, not staged.
        XCTAssertEqual(sh("git diff --cached --name-only"), "")
        XCTAssertEqual(sh("git diff --name-only"), "keep.txt")
        XCTAssertEqual(sh("git ls-files --others --exclude-standard"), "other.txt")
    }

    func testCommitShowsGitRefusal() {
        sh("echo changed > keep.txt && mkdir -p .git/hooks && printf '#!/bin/sh\\necho lint failed >&2\\nexit 1\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit")
        guard case .failure(let f) = GitChanges.commit(root: repo, paths: ["keep.txt"], message: "m") else { return XCTFail("committed") }
        XCTAssertTrue(f.message.contains("lint failed"))
    }

    func testNotARepo() {
        guard case .failure = GitChanges.load(cwd: NSTemporaryDirectory()) else { return XCTFail("loaded") }
    }

    func testCommentMessage() {
        let c = [ReviewComment(path: "a.swift", line: .init(kind: .added, old: nil, new: 42, text: "  let x = 1"), body: "이름을 바꿀 것"),
                 ReviewComment(path: "b.swift", line: .init(kind: .removed, old: 7, new: nil, text: "old()"), body: "되살릴 것")]
        let m = ReviewComment.message(c)
        XCTAssertTrue(m.contains("1. a.swift:42\n   > let x = 1\n   이름을 바꿀 것"))
        XCTAssertTrue(m.contains("2. b.swift:7 (지운 줄)\n   > old()\n   되살릴 것"))
    }
}
