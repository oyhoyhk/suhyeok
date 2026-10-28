import Foundation

/// Git worktrees for new sessions: each one gets its own checkout and branch, so agents working on the same repo
/// at once never share files. Checkouts live outside the repo, at `~/.suhyeok/worktrees/<repo>/<name>`.
enum Worktree {
    static let branchPrefix = "suhyeok/"
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".suhyeok/worktrees").path

    struct Failure: Error { let message: String }

    /// Top folder of the git checkout that contains `dir`, or nil when `dir` is not in a git repo.
    static func repoRoot(of dir: String) -> String? {
        guard case .success(let out) = git(["-C", dir, "rev-parse", "--show-toplevel"]) else { return nil }
        let top = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    /// Branch named after the first words of the prompt (Korean romanized, e.g. "로그인 버그" → `suhyeok/logeu-in-beogeu`),
    /// or a random id when the prompt gives no letters.
    static func defaultBranch(for prompt: String = "") -> String {
        let latin = prompt.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? prompt
        let words = latin.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(4)
        var slug = ""
        for w in words where slug.count + w.count < 32 { slug += (slug.isEmpty ? "" : "-") + w }
        return branchPrefix + (slug.isEmpty ? String(UUID().uuidString.lowercased().prefix(6)) : slug)
    }

    /// True when `cwd` is one of the checkouts 수혁 made, or a folder inside one.
    static func isManaged(_ cwd: String) -> Bool { checkout(containing: cwd) != nil }

    /// The managed checkout (`<root>/<repo>/<name>`) that `cwd` is in.
    static func checkout(containing cwd: String) -> String? {
        guard cwd.hasPrefix(root + "/") else { return nil }
        let parts = cwd.dropFirst(root.count + 1).split(separator: "/").prefix(2)
        return parts.count == 2 ? root + "/" + parts.joined(separator: "/") : nil
    }

    struct Entry: Identifiable, Hashable {
        let path: String
        let repo: String
        /// nil when the folder is no longer a git checkout.
        let branch: String?
        /// Uncommitted changes and untracked files, as `git status --porcelain` counts them.
        let changes: Int
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Every checkout under `root`, by repo then name.
    static func all() -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        for repo in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !repo.hasPrefix(".") {
            let dir = (root as NSString).appendingPathComponent(repo)
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard case .success(let status) = git(["-C", path, "status", "--porcelain", "--branch"]) else {
                    out.append(Entry(path: path, repo: repo, branch: nil, changes: 0)); continue
                }
                let lines = status.split(separator: "\n")
                // First line: "## suhyeok/x" or "## suhyeok/x...origin/x [ahead 1]".
                let head = lines.first.map { String($0.dropFirst(3).prefix { $0 != "." && $0 != " " }) }
                out.append(Entry(path: path, repo: repo, branch: head, changes: max(lines.count - 1, 0)))
            }
        }
        return out
    }

    /// Project name for display and grouping: a managed checkout belongs to its repo, not to its own folder name.
    static func project(of cwd: String) -> String {
        if cwd.hasPrefix(root + "/"), let repo = cwd.dropFirst(root.count + 1).split(separator: "/").first { return String(repo) }
        return (cwd as NSString).lastPathComponent
    }

    /// Adds a worktree of the repo containing `dir` on a new branch from its current HEAD, copies the gitignored
    /// files listed in the repo's `.worktreeinclude`, and returns the new checkout's path.
    static func create(from dir: String, branch: String) -> Result<String, Failure> {
        guard let repo = repoRoot(of: dir) else { return .failure(Failure(message: String(localized: "git 저장소가 아님"))) }
        let base = (root as NSString).appendingPathComponent((repo as NSString).lastPathComponent)
        let folder = (branch.hasPrefix(branchPrefix) ? String(branch.dropFirst(branchPrefix.count)) : branch)
            .replacingOccurrences(of: "/", with: "-")
        var path = (base as NSString).appendingPathComponent(folder)
        var n = 2
        while FileManager.default.fileExists(atPath: path) { path = (base as NSString).appendingPathComponent("\(folder)-\(n)"); n += 1 }
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        if case .failure(let f) = git(["-C", repo, "worktree", "add", "-b", branch, path]) { return .failure(f) }
        copyIncluded(from: repo, to: path)
        return .success(path)
    }

    /// Removes a managed checkout. Git refuses while it has uncommitted changes or untracked files, so nothing is
    /// lost; the branch is kept, with any commits the agent made.
    static func remove(_ path: String) -> Failure? {
        guard let path = checkout(containing: path) else { return Failure(message: String(localized: "수혁이 만든 워크트리가 아님")) }
        guard case .success(let common) = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]) else {
            return Failure(message: String(localized: "워크트리를 찾지 못함"))
        }
        let repo = ((common.trimmingCharacters(in: .whitespacesAndNewlines)) as NSString).deletingLastPathComponent
        if case .failure(let f) = git(["-C", repo, "worktree", "remove", path]) { return f }
        return nil
    }

    /// `.worktreeinclude` lists gitignored files (e.g. `.env`) a fresh checkout needs, one literal path per line.
    private static func copyIncluded(from repo: String, to path: String) {
        guard let list = try? String(contentsOfFile: (repo as NSString).appendingPathComponent(".worktreeinclude"), encoding: .utf8)
        else { return }
        for line in list.split(separator: "\n") {
            let rel = line.trimmingCharacters(in: .whitespaces)
            guard !rel.isEmpty, !rel.hasPrefix("#"), !rel.contains("..") else { continue }
            let src = (repo as NSString).appendingPathComponent(rel), dst = (path as NSString).appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst) else { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(atPath: src, toPath: dst)
        }
    }

    /// Runs git, keeping stderr so a refusal can be shown to the user.
    private static func git(_ args: [String]) -> Result<String, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(Failure(message: error.localizedDescription)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(Failure(message: msg.isEmpty ? "git \(args.dropFirst(2).first ?? "") failed" : msg))
        }
        return .success(String(data: data, encoding: .utf8) ?? "")
    }
}
