import Foundation
import Network
import UniformTypeIdentifiers

/// The phone's Files tab and file links (MobileServer /api/files, /api/file): folder listings and the bytes of a file,
/// in ranges so a video plays while it downloads. Paired phones only, and only inside the home folder.
enum MobileFiles {
    /// `path` (absolute or `~/…`) with symlinks resolved, when it lies inside the home folder; nil otherwise.
    static func resolve(_ path: String?, home: String = NSHomeDirectory()) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let full = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        guard full.hasPrefix("/") else { return nil }
        let real = (full as NSString).resolvingSymlinksInPath
        let root = (home as NSString).resolvingSymlinksInPath
        return real == root || real.hasPrefix(root + "/") ? real : nil
    }

    /// Folders the agents work in (SessionStore.knownFolders) that still exist, for the tab's first screen.
    static func roots(_ folders: [String], home: String = NSHomeDirectory()) -> [String] {
        folders.filter { f in
            var dir: ObjCBool = false
            return resolve(f, home: home) != nil && FileManager.default.fileExists(atPath: f, isDirectory: &dir) && dir.boolValue
        }
    }

    /// Names never listed: hidden files and folders that only hold tooling.
    private static let skipped: Set<String> = ["node_modules", "__pycache__", "DerivedData"]

    /// A folder's entries, newest first, so what an agent just made is on top. nil when it is not a readable folder.
    static func list(_ dir: String, home: String = NSHomeDirectory(), limit: Int = 500) -> [String: Any]? {
        guard let real = resolve(dir, home: home) else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: real), includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return nil }
        let entries = urls.filter { !skipped.contains($0.lastPathComponent) }.compactMap { u -> (Date, [String: Any])? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            let date = v.contentModificationDate ?? .distantPast
            return (date, ["name": u.lastPathComponent, "path": u.path, "dir": v.isDirectory ?? false,
                           "size": v.fileSize ?? 0, "mtime": date.timeIntervalSince1970])
        }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        let root = (home as NSString).resolvingSymlinksInPath
        var out: [String: Any] = ["dir": real, "entries": entries]
        if real != root { out["parent"] = (real as NSString).deletingLastPathComponent }
        return out
    }

    /// The bytes a `Range: bytes=…` header asks for, within a file of `size` bytes.
    enum Span: Equatable { case whole, part(ClosedRange<Int64>), unsatisfiable }

    static func span(_ header: String?, size: Int64) -> Span {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .whole }  // several ranges: send it all
        let spec = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard spec.count == 2 else { return .whole }
        if spec[0].isEmpty {  // "-500": the last 500 bytes
            guard let n = Int64(spec[1]), n > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - n)...(size - 1))
        }
        guard let start = Int64(spec[0]), start >= 0 else { return .whole }
        guard start < size else { return .unsatisfiable }
        let end = Int64(spec[1]).map { min($0, size - 1) } ?? size - 1
        return end >= start ? .part(start...end) : .unsatisfiable
    }

    static func mimeType(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["md", "txt", "log", "csv", "json", "yaml", "yml", "swift", "kt", "py", "js", "ts", "sh"].contains(ext) {
            return "text/plain; charset=utf-8"  // shown as text on the phone, never run as a page
        }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Sends `length` bytes of an open file after `head`, one chunk each time the connection has taken the last one.
/// Runs on the connection's queue; it holds the only references to the handle and the count.
final class FileSender: @unchecked Sendable {
    private let c: NWConnection, handle: FileHandle
    private var left: Int64

    init(_ c: NWConnection, _ handle: FileHandle, _ length: Int64) { self.c = c; self.handle = handle; left = length }

    func start(_ head: Data) { c.send(content: head, completion: .contentProcessed(next)) }

    private func next(_ error: NWError?) {
        guard error == nil, left > 0, let chunk = try? handle.read(upToCount: Int(min(left, 256 * 1024))), !chunk.isEmpty else {
            try? handle.close()
            c.cancel()
            return
        }
        left -= Int64(chunk.count)
        c.send(content: chunk, completion: .contentProcessed(next))
    }
}
