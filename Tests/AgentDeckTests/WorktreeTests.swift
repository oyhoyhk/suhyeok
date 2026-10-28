import Foundation
import XCTest
@testable import AgentDeck

final class WorktreeTests: XCTestCase {
    private var tmp: String!
    private var repo: String!
    private var savedRoot: String!

    override func setUp() {
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("wt-\(UUID().uuidString.prefix(8))")
        repo = (tmp as NSString).appendingPathComponent("myrepo")
        try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        savedRoot = Worktree.root
        Worktree.root = (tmp as NSString).appendingPathComponent("worktrees")
        sh("git init -q -b main && git config user.email t@t && git config user.name t"
           + " && printf '.env\\nconfig/local.json\\n' > .gitignore && echo a > a.txt"
           + " && printf '.env\\nconfig/local.json\\nmissing.txt\\n' > .worktreeinclude"
           + " && echo SECRET=1 > .env && mkdir config && echo '{}' > config/local.json"
           + " && git add -A && git commit -qm init")
    }

    override func tearDown() {
        Worktree.root = savedRoot
        try? FileManager.default.removeItem(atPath: tmp)
    }

    @discardableResult
    private func sh(_ cmd: String, in dir: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir ?? repo)
        let out = Pipe()
        p.standardOutput = out
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testCreatesCheckoutOnNewBranchOutsideRepoWithIncludedFiles() throws {
        let sub = (repo as NSString).appendingPathComponent("config")
        let path = try Worktree.create(from: sub, branch: "suhyeok/abc123").get()
        XCTAssertEqual(path, (Worktree.root as NSString).appendingPathComponent("myrepo/abc123"))
        XCTAssertEqual(sh("git branch --show-current", in: path), "suhyeok/abc123")
        XCTAssertEqual(try String(contentsOfFile: path + "/.env", encoding: .utf8), "SECRET=1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/config/local.json"))
        XCTAssertTrue(Worktree.isManaged(path))
        XCTAssertEqual(Worktree.project(of: path), "myrepo")
        XCTAssertEqual(Worktree.project(of: path + "/src"), "myrepo")
        XCTAssertEqual(Worktree.project(of: repo), "myrepo")
    }

    func testSecondCheckoutWithSameFolderNameGetsSuffix() throws {
        let first = try Worktree.create(from: repo, branch: "suhyeok/x").get()
        let second = try Worktree.create(from: repo, branch: "other/x").get()
        XCTAssertEqual((first as NSString).lastPathComponent, "x")
        XCTAssertEqual((second as NSString).lastPathComponent, "other-x")
        let third = try Worktree.create(from: repo, branch: "x").get()
        XCTAssertEqual((third as NSString).lastPathComponent, "x-2")
    }

    func testFailsOutsideRepoAndOnExistingBranch() throws {
        let plain = (tmp as NSString).appendingPathComponent("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertNil(Worktree.repoRoot(of: plain))
        guard case .failure = Worktree.create(from: plain, branch: "suhyeok/a") else { return XCTFail("created outside a repo") }
        guard case .failure(let f) = Worktree.create(from: repo, branch: "main") else { return XCTFail("reused branch main") }
        XCTAssertTrue(f.message.contains("main"), f.message)
    }

    func testRemoveKeepsBranchAndCommitsWhenClean() throws {
        let path = try Worktree.create(from: repo, branch: "suhyeok/done").get()
        sh("echo b > b.txt && git add b.txt && git commit -qm work", in: path)
        XCTAssertNil(Worktree.remove(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(sh("git log -1 --format=%s suhyeok/done"), "work")
    }

    func testDefaultBranchFollowsPromptWords() {
        XCTAssertEqual(Worktree.defaultBranch(for: "Fix login bug in the API now"), "suhyeok/fix-login-bug-in")
        XCTAssertEqual(Worktree.defaultBranch(for: "로그인 버그 고쳐"), "suhyeok/logeu-in-beogeu-gochyeo")
        let random = Worktree.defaultBranch(for: "!!! ...")
        XCTAssertTrue(random.hasPrefix("suhyeok/") && random.count == "suhyeok/".count + 6, random)
    }

    func testFindsCheckoutForFoldersInsideIt() throws {
        let path = try Worktree.create(from: repo, branch: "suhyeok/deep").get()
        XCTAssertEqual(Worktree.checkout(containing: path + "/config"), path)
        XCTAssertNil(Worktree.checkout(containing: Worktree.root + "/myrepo"))
        XCTAssertNil(Worktree.checkout(containing: repo))
        XCTAssertNil(Worktree.remove(path + "/config"), "removing from a subfolder removes the whole checkout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testListsCheckoutsWithBranchAndChanges() throws {
        let clean = try Worktree.create(from: repo, branch: "suhyeok/clean").get()
        let dirty = try Worktree.create(from: repo, branch: "suhyeok/dirty").get()
        sh("echo changed > a.txt && echo new > new.txt", in: dirty)
        let all = Worktree.all()
        XCTAssertEqual(all.map(\.path), [clean, dirty])
        XCTAssertEqual(all.map(\.branch), ["suhyeok/clean", "suhyeok/dirty"])
        XCTAssertEqual(all.map(\.changes), [0, 2])
        XCTAssertEqual(all.map(\.repo), ["myrepo", "myrepo"])
    }

    func testRemoveRefusesUncommittedChanges() throws {
        let path = try Worktree.create(from: repo, branch: "suhyeok/dirty").get()
        sh("echo changed > a.txt", in: path)
        XCTAssertNotNil(Worktree.remove(path))
        XCTAssertEqual(sh("cat a.txt", in: path), "changed")
        XCTAssertNotNil(Worktree.remove(repo), "only managed checkouts can be removed")
    }
}
