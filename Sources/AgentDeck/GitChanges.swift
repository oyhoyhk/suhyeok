import Foundation

/// What changed in a session's git checkout since the last commit, read for the review panel, and committing it.
enum GitChanges {
    struct Line: Hashable {
        enum Kind { case context, added, removed }
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    struct Hunk: Hashable {
        let header: String
        var lines: [Line]
    }

    enum Status: String {
        case modified = "M", added = "A", deleted = "D", untracked = "U"
    }

    struct FileDiff: Identifiable, Hashable {
        var id: String { path }
        let path: String
        var status: Status
        var hunks: [Hunk] = []
        var binary = false
        /// Lines left out because the file's diff is too long to draw.
        var cut = 0
        var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    }

    struct Snapshot: Equatable {
        let root: String
        var files: [FileDiff]
        /// Untracked files beyond the ones listed (an unignored build folder can hold thousands).
        var moreUntracked = 0
    }

    static let maxLines = 2000
    static let maxUntracked = 200
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbad4904"

    /// Changes in the checkout holding `cwd`: tracked files against HEAD (staged or not) plus untracked files.
    static func load(cwd: String) -> Result<Snapshot, Worktree.Failure> {
        guard case (true, let top) = git(cwd, ["rev-parse", "--show-toplevel"]) else {
            return .failure(.init(message: String(localized: "git 저장소가 아님")))
        }
        let root = top.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = git(root, ["rev-parse", "--verify", "-q", "HEAD"]).ok ? "HEAD" : emptyTree  // no commits yet
        let (ok, diff) = git(root, ["diff", "--no-color", "--no-ext-diff", "--no-renames", "-U3", base])
        guard ok else { return .failure(.init(message: diff.trimmingCharacters(in: .whitespacesAndNewlines))) }
        var snap = Snapshot(root: root, files: parse(diff))
        let others = git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).out
            .split(separator: "\0").map(String.init)
        for path in others.prefix(maxUntracked) { snap.files.append(untracked(path, root: root)) }
        snap.moreUntracked = max(0, others.count - maxUntracked)
        snap.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return .success(snap)
    }

    /// Splits `git diff` output into files and hunks, numbering each line on both sides.
    static func parse(_ diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var old = 0, new = 0, drawn = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git a/") {
                // Without renames both sides name the same path: "a/<p> b/<p>".
                let rest = line.dropFirst("diff --git a/".count)
                files.append(FileDiff(path: String(rest.prefix((rest.count - 3) / 2)), status: .modified))
                drawn = 0
                continue
            }
            guard !files.isEmpty else { continue }
            let i = files.count - 1
            if files[i].hunks.isEmpty {
                if line.hasPrefix("new file mode") { files[i].status = .added }
                else if line.hasPrefix("deleted file mode") { files[i].status = .deleted }
                else if line.hasPrefix("Binary files") { files[i].binary = true }
            }
            if line.hasPrefix("@@") {
                // "@@ -12,3 +12,4 @@ context": where each side starts.
                let nums = line.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0 }
                old = nums.first ?? 0; new = nums.last ?? 0
                files[i].hunks.append(Hunk(header: line, lines: []))
                continue
            }
            guard let h = files[i].hunks.indices.last else { continue }
            guard line.first == "+" || line.first == "-" || line.first == " " else { continue }  // "\ No newline at end of file"
            if drawn >= maxLines { files[i].cut += 1; continue }
            drawn += 1
            switch line.first {
            case "+": files[i].hunks[h].lines.append(Line(kind: .added, old: nil, new: new, text: String(line.dropFirst()))); new += 1
            case "-": files[i].hunks[h].lines.append(Line(kind: .removed, old: old, new: nil, text: String(line.dropFirst()))); old += 1
            case " ": files[i].hunks[h].lines.append(Line(kind: .context, old: old, new: new, text: String(line.dropFirst()))); old += 1; new += 1
            default: break
            }
        }
        return files
    }

    /// A file git does not track yet, shown as all added.
    private static func untracked(_ path: String, root: String) -> FileDiff {
        var f = FileDiff(path: path, status: .untracked)
        guard let data = FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(path)) else { return f }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else { f.binary = true; return f }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        f.cut = max(0, lines.count - maxLines)
        let shown = lines.prefix(maxLines).enumerated().map { Line(kind: .added, old: nil, new: $0.offset + 1, text: $0.element) }
        if !shown.isEmpty { f.hunks = [Hunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: shown)] }
        return f
    }

    /// Commits only `paths` (new, changed or deleted), leaving anything else staged or not as it was.
    /// Returns the commit's one-line summary, or git's own words (hook output included) when it refuses.
    static func commit(root: String, paths: [String], message: String) -> Result<String, Worktree.Failure> {
        guard !paths.isEmpty else { return .failure(.init(message: String(localized: "커밋할 파일을 고를 것"))) }
        let (added, addOut) = git(root, ["add", "-A", "--"] + paths, mergeErrors: true)
        guard added else { return .failure(.init(message: addOut.trimmingCharacters(in: .whitespacesAndNewlines))) }
        let (ok, out) = git(root, ["commit", "-q", "-m", message, "--"] + paths, mergeErrors: true)
        guard ok else { return .failure(.init(message: out.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return .success(git(root, ["log", "-1", "--format=%h %s"]).out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs git in `dir` with paths taken literally (no globs) and printed unquoted (Korean names stay readable).
    private static func git(_ dir: String, _ args: [String], mergeErrors: Bool = false) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=false", "--literal-pathspecs", "-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = mergeErrors ? out : FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// A note on one line of the diff, sent to the agent with the others as a single instruction.
struct ReviewComment: Identifiable, Hashable {
    var id: String { "\(path)|\(line.old ?? -1)|\(line.new ?? -1)" }
    let path: String
    let line: GitChanges.Line
    var body: String

    /// One message for the agent: where each note points, the line itself, and the note.
    static func message(_ comments: [ReviewComment]) -> String {
        var out = String(localized: "변경사항 리뷰 코멘트 \(comments.count)개 — 반영해 줘.")
        for (n, c) in comments.enumerated() {
            let at = c.line.new.map { "\(c.path):\($0)" } ?? "\(c.path):\(c.line.old ?? 0) " + String(localized: "(지운 줄)")
            out += "\n\n\(n + 1). \(at)\n   > \(c.line.text.trimmingCharacters(in: .whitespaces))\n   \(c.body)"
        }
        return out
    }
}
