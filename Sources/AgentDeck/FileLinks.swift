import AppKit
import SwiftUI

/// File paths in chat text become links, opened with ⌘-click like in cmux.
/// Only paths that exist on disk are linked, so ordinary words with slashes stay plain.
enum FileLinks {
    /// `~/a/b`, `/a/b`, `./a`, `a/b.swift`, `README.md`, each optionally followed by `:line[:col]`.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w/.~-])(?:~?/|\.{1,2}/)?[\w@가-힣.+-]+(?:/[\w@가-힣.+-]+)*(?::\d+(?::\d+)?)?"#)

    static func link(_ s: AttributedString, cwd: String?) -> AttributedString {
        let text = String(s.characters)
        guard text.contains("/") || text.contains(".") else { return s }
        var out = s
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var token = String(text[r])
            while token.hasSuffix(".") { token.removeLast() }  // sentence end
            var url = target(token, cwd: cwd)
            if url == nil {  // a Korean particle stuck to the path: "README.md와"
                token = token.replacingOccurrences(of: "[가-힣]+$", with: "", options: .regularExpression)
                url = target(token, cwd: cwd)
            }
            guard let url else { continue }
            let lower = text.distance(from: text.startIndex, to: r.lowerBound)
            let start = out.characters.index(out.startIndex, offsetBy: lower)
            let end = out.characters.index(start, offsetBy: token.count)
            out[start..<end].link = url
        }
        return out
    }

    private static func target(_ token: String, cwd: String?) -> URL? {
        let path = token.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        guard path.contains("/") || path.contains(".") else { return nil }
        return resolve(path, cwd: cwd)
    }

    private static func resolve(_ path: String, cwd: String?) -> URL? {
        var full = (path as NSString).expandingTildeInPath
        if !full.hasPrefix("/") {
            guard let cwd, !cwd.isEmpty else { return nil }
            full = (cwd as NSString).appendingPathComponent(full)
        }
        full = (full as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: full) ? URL(fileURLWithPath: full) : nil
    }

    /// File links open only with ⌘ held; other links keep their usual behavior.
    static let openAction = OpenURLAction { url in
        guard url.isFileURL else { return .systemAction }
        if NSEvent.modifierFlags.contains(.command) { NSWorkspace.shared.open(url) }
        return .handled
    }
}
