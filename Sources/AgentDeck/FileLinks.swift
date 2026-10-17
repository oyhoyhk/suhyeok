import AppKit
import SwiftTerm
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

/// With ⌘ held, the pointer turns into a hand over a file link, as in cmux and Ghostty.
/// SwiftUI has no per-link hover, so an app-wide monitor hit-tests the character under the mouse: selectable
/// Text keeps an NSTextField (an NSTextView while selecting) holding the same string and links, and the
/// embedded terminal finds links with SwiftTerm's own detector, the one its ⌘-click uses.
@MainActor
enum CommandHover {
    private static var showing = false

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { event in
            // After dispatch, so the views' own cursor updates for this event do not undo ours.
            DispatchQueue.main.async { update() }
            return event
        }
    }

    private static func update() {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number), let content = window.contentView else { return reset(nil) }
        let command = NSEvent.modifierFlags.contains(.command)
        if command { window.acceptsMouseMovedEvents = true }  // moves while ⌘ is held must reach the monitor
        let point = window.convertPoint(fromScreen: mouse)
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        if command, let hit, overLink(hit, at: point) {
            NSCursor.pointingHand.set()
            showing = true
        } else {
            reset(hit)
        }
    }

    private static func reset(_ hit: NSView?) {
        guard showing else { return }
        showing = false
        (hit is NSText || hit is NSTextField || hit is TerminalView ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// `point` is in window coordinates.
    private static func overLink(_ view: NSView, at point: NSPoint) -> Bool {
        if let term = view as? TerminalView ?? view.superview as? TerminalView { return terminalLink(term, at: point) }
        if let tv = view as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage {
            let p = tv.convert(point, from: nil)
            return link(in: storage, lm, tc, at: NSPoint(x: p.x - tv.textContainerOrigin.x, y: p.y - tv.textContainerOrigin.y))
        }
        guard let field = view as? NSTextField ?? view.subviews.lazy.compactMap({ $0 as? NSTextField }).first,
              let cell = field.cell else { return false }
        let rect = cell.titleRect(forBounds: field.bounds)
        let storage = NSTextStorage(attributedString: field.attributedStringValue)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: rect.width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 2  // the field's own inset; measured to match what SwiftUI draws
        lm.addTextContainer(tc)
        let p = field.convert(point, from: nil)
        return link(in: storage, lm, tc, at: NSPoint(x: p.x - rect.minX, y: p.y - rect.minY))
    }

    private static func link(in storage: NSTextStorage, _ lm: NSLayoutManager, _ tc: NSTextContainer, at p: NSPoint) -> Bool {
        guard storage.length > 0 else { return false }
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return false }
        let url = storage.attribute(.link, at: lm.characterIndexForGlyph(at: glyph), effectiveRange: nil)
        return (url as? URL)?.isFileURL == true || (url as? String).flatMap(URL.init(string:))?.isFileURL == true
    }

    /// Same cell math as SwiftTerm's mouse hit (its own is internal); links it would open on ⌘-click.
    private static func terminalLink(_ term: TerminalView, at point: NSPoint) -> Bool {
        let font = term.font
        let scale = term.window?.backingScaleFactor ?? 2
        let width = (font.advancement(forGlyph: font.glyph(withName: "W")).width * scale).rounded() / scale
        let height = ceil((font.ascender - font.descender + font.leading) * scale) / scale
        let p = term.convert(point, from: nil)
        let pos = Position(col: Int(p.x / width), row: Int((term.frame.height - p.y) / height))
        guard pos.col >= 0, pos.row >= 0, pos.col < term.getTerminal().cols, pos.row < term.getTerminal().rows,
              let link = term.getTerminal().link(at: .screen(pos), mode: .explicitAndImplicit) else { return false }
        if let url = URL(string: link), url.scheme != nil { return url.isFileURL }
        return FileManager.default.fileExists(atPath: (link as NSString).expandingTildeInPath)
    }
}
