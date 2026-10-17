import XCTest
@testable import AgentDeck

final class MobileFilesTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = (NSTemporaryDirectory() as NSString).appendingPathComponent("mobilefiles-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/proj/out", withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: home + "/proj/old.txt"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: home + "/proj/old.txt")
        try Data("video".utf8).write(to: URL(fileURLWithPath: home + "/proj/out/demo.mp4"))
        try Data().write(to: URL(fileURLWithPath: home + "/proj/.secret"))
        try fm.createDirectory(atPath: home + "/proj/node_modules", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/proj/escape", withDestinationPath: "/etc")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func testOnlyPathsInsideHomeResolve() {
        let real = (home as NSString).resolvingSymlinksInPath
        XCTAssertEqual(MobileFiles.resolve(home + "/proj/old.txt", home: home), real + "/proj/old.txt")
        XCTAssertEqual(MobileFiles.resolve(home + "/proj/../proj/old.txt", home: home), real + "/proj/old.txt")
        XCTAssertNil(MobileFiles.resolve("/etc/hosts", home: home))
        XCTAssertNil(MobileFiles.resolve(home + "/../etc", home: home))
        XCTAssertNil(MobileFiles.resolve(home + "/proj/escape/hosts", home: home), "a symlink out of home is not followed")
        XCTAssertNil(MobileFiles.resolve(home + "x/a", home: home), "a sibling folder sharing the prefix is outside")
        XCTAssertNil(MobileFiles.resolve("relative/path", home: home))
        XCTAssertNil(MobileFiles.resolve(nil, home: home))
    }

    func testListingIsNewestFirstWithoutHiddenOrToolingEntries() throws {
        let listing = try XCTUnwrap(MobileFiles.list(home + "/proj", home: home))
        let entries = try XCTUnwrap(listing["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(entries.compactMap { $0["name"] as? String }), ["escape", "out", "old.txt"])
        XCTAssertEqual(entries.last?["name"] as? String, "old.txt", "the hour-old file comes last")
        XCTAssertFalse(entries.contains { ($0["name"] as? String)?.hasPrefix(".") == true })
        XCTAssertFalse(entries.contains { $0["name"] as? String == "node_modules" })
        XCTAssertEqual(entries.first { $0["name"] as? String == "out" }?["dir"] as? Bool, true)
        XCTAssertEqual(listing["parent"] as? String, (home as NSString).resolvingSymlinksInPath)
        XCTAssertNil(MobileFiles.list(home, home: home)?["parent"], "home has no parent to go up to")
        XCTAssertNil(MobileFiles.list("/etc", home: home))
    }

    func testRangeHeaders() {
        XCTAssertEqual(MobileFiles.span(nil, size: 100), .whole)
        XCTAssertEqual(MobileFiles.span("bytes=0-", size: 100), .part(0...99))
        XCTAssertEqual(MobileFiles.span("bytes=10-19", size: 100), .part(10...19))
        XCTAssertEqual(MobileFiles.span("bytes=90-500", size: 100), .part(90...99))
        XCTAssertEqual(MobileFiles.span("bytes=-30", size: 100), .part(70...99))
        XCTAssertEqual(MobileFiles.span("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(MobileFiles.span("bytes=20-10", size: 100), .unsatisfiable)
        XCTAssertEqual(MobileFiles.span("bytes=0-1,5-6", size: 100), .whole)
        XCTAssertEqual(MobileFiles.span("items=0-1", size: 100), .whole)
    }

    func testTextIsNeverServedAsAPage() {
        XCTAssertEqual(MobileFiles.mimeType("a/notes.md"), "text/plain; charset=utf-8")
        XCTAssertEqual(MobileFiles.mimeType("a/clip.mp4"), "video/mp4")
        XCTAssertEqual(MobileFiles.mimeType("a/blob.unknownext"), "application/octet-stream")
    }

    func testChatPathsMapTokensToFilesAndFolders() {
        let text = "결과물은 `out/demo.mp4`에 있고, 폴더 \(home!)/proj/out 와 없는 파일 nothing/here.mp4 는 링크 안 됨."
        let paths = FileLinks.paths(in: text, cwd: home + "/proj")
        XCTAssertEqual(paths["out/demo.mp4"], home + "/proj/out/demo.mp4")
        XCTAssertEqual(paths[home + "/proj/out"], home + "/proj/out/")
        XCTAssertNil(paths["nothing/here.mp4"])
    }
}
