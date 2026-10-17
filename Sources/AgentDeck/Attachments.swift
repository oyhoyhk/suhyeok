import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// As in Claude Code: long pastes, images and files go into the input as short tokens
/// ("[Pasted text #1 +42 lines]", "[Image #1]", "[File report.pdf]") so the input stays light.
/// Tokens become the full text or a file path only when the message is sent.
struct Attachments {
    private var byToken: [String: String] = [:]
    private var texts = 0, images = 0

    static let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Suhyeok/attachments"
    /// Shorter pastes go in as they are.
    static let longText = 1000, longLines = 10
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]

    /// The token for what is on the pasteboard, or nil to let the normal paste happen (short text).
    mutating func paste(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return add(files: urls)
        }
        if let s = pb.string(forType: .string) {
            let token = add(text: Self.readable(s))
            return token == s ? nil : token
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            return add(imageData: data)
        }
        return nil
    }

    /// Long text becomes a token; short text is returned unchanged.
    mutating func add(text s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).count
        guard s.count > Self.longText || lines > Self.longLines else { return s }
        texts += 1
        let token = "[Pasted text #\(texts) +\(lines) lines]"
        byToken[token] = s
        return token
    }

    mutating func add(files urls: [URL]) -> String {
        urls.map { url in
            let isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
            if isImage { images += 1 }
            let token = isImage ? "[Image #\(images) \(url.lastPathComponent)]" : "[File \(url.lastPathComponent)]"
            byToken[token] = Self.shellPath(url.path)
            return token
        }.joined(separator: " ")
    }

    /// Image bytes (a screenshot copied to the clipboard, an image dragged from a browser) are saved as PNG.
    mutating func add(imageData data: Data) -> String? {
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        images += 1
        let path = Self.dir + "/paste-\(f.string(from: Date()))-\(images).png"
        guard FileManager.default.createFile(atPath: path, contents: png) else { images -= 1; return nil }
        let token = "[Image #\(images)]"
        byToken[token] = Self.shellPath(path)
        return token
    }

    /// Files sent from the phone: the user's temporary folder, not kept with the Mac's own attachments.
    static let phoneDir = FileManager.default.temporaryDirectory.appendingPathComponent("Suhyeok-phone").path
    /// Phone files older than this are deleted on the next upload, so they do not pile up.
    static let phoneKeep: TimeInterval = 3 * 86400

    /// A file sent from the phone, saved under its own name in a folder of its own (two photos are often both
    /// "image.jpg"). Returns the path as it goes into a message, or nil when it could not be written.
    static func savePhone(_ data: Data, name: String) -> String? {
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(atPath: phoneDir)) ?? [] {
            let p = phoneDir + "/" + old
            if let made = (try? fm.attributesOfItem(atPath: p))?[.creationDate] as? Date, Date().timeIntervalSince(made) > phoneKeep {
                try? fm.removeItem(atPath: p)
            }
        }
        var clean = String(readable(name).map { "/:\\".contains($0) || $0.isNewline ? "_" : $0 })
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { clean = "file" }
        if clean.count > 120 { clean = String(clean.suffix(120)) }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let folder = phoneDir + "/phone-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        guard (try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil,
              fm.createFile(atPath: folder + "/" + clean, contents: data) else { return nil }
        return shellPath(folder + "/" + clean)
    }

    /// The message as the agent should get it: every token replaced by its text or path.
    func expand(_ text: String) -> String {
        byToken.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// Percent-escaped non-ASCII in pasted text (Korean in a copied file:// or web URL) shown as the letters.
    /// Only UTF-8 multibyte escapes are decoded, so %20, %2F, %26 and the like keep their meaning.
    static func readable(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let re = try! NSRegularExpression(pattern: "(?:%[C-Fc-f][0-9A-Fa-f](?:%[89ABab][0-9A-Fa-f])+)+")
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out), let decoded = out[r].removingPercentEncoding else { continue }
            out.replaceSubrange(r, with: decoded)
        }
        return out.precomposedStringWithCanonicalMapping  // macOS file names come decomposed (NFD)
    }

    /// Paths as a terminal writes a dropped file (spaces escaped), which Claude Code reads as an attachment.
    private static func shellPath(_ p: String) -> String {
        p.replacingOccurrences(of: " ", with: "\\ ")
    }

    /// Lets the user pick files, as a drop would.
    mutating func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return add(files: panel.urls)
    }
}

/// Catches ⌘V while the text field it sits behind is being edited, so a paste can become a token
/// instead of pouring a long text or an image into the field. Placed as the field's background.
struct PasteCatcher: NSViewRepresentable {
    /// Returns what to insert, or nil to let the normal paste happen.
    let onPaste: (NSPasteboard) -> String?

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) { v.onPaste = onPaste }

    final class CatcherView: NSView {
        var onPaste: ((NSPasteboard) -> String?)?
        private var monitor: Any?

        private var responderWatch: NSKeyValueObservation?
        /// The field editor whose drop types this view took away, and what they were.
        private weak var mutedEditor: NSTextView?
        private var mutedTypes: [NSPasteboard.PasteboardType] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            responderWatch = nil
            restoreDrops()
            guard let window else { return }
            // While this field is being edited, the window's shared field editor sits on top of it and takes file
            // drops as plain path text. Turn its drops off then, so they reach the dialogue's drop handler.
            responderWatch = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.updateDrops(w) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      e.charactersIgnoringModifiers == "v",
                      let editor = self.ownEditor(w),
                      let insert = self.onPaste?(Self.pasteboard)
                else { return e }
                // A space after a token, so the next paste or word does not run into it.
                editor.insertText(insert + (insert.hasSuffix("]") ? " " : ""), replacementRange: editor.selectedRange())
                return nil
            }
        }

        /// Snapshot tests paste from a private pasteboard so the user's clipboard is left alone.
        static var pasteboard: NSPasteboard {
            ProcessInfo.processInfo.environment["SUHYEOK_TEST_PASTEBOARD"].map { NSPasteboard(name: .init($0)) } ?? .general
        }

        /// The field editor, when it is editing the field this catcher sits behind.
        private func ownEditor(_ w: NSWindow) -> NSTextView? {
            guard let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView,
                  field.convert(field.bounds, to: nil).intersects(convert(bounds, to: nil)) else { return nil }
            return editor
        }

        private func updateDrops(_ w: NSWindow) {
            guard let editor = ownEditor(w) else { restoreDrops(); return }
            guard editor !== mutedEditor else { return }
            restoreDrops()
            mutedTypes = editor.registeredDraggedTypes
            mutedEditor = editor
            editor.unregisterDraggedTypes()
        }

        /// Other fields in the window share the editor; give it its drops back when this field is done.
        private func restoreDrops() {
            if let e = mutedEditor, !mutedTypes.isEmpty { e.registerForDraggedTypes(mutedTypes) }
            mutedEditor = nil
            mutedTypes = []
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never takes clicks from the field

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension Attachments {
    /// Tokens for files and images dropped on the dialogue; delivered on the main queue.
    static func dropped(_ providers: [NSItemProvider], into apply: @escaping (_ add: (inout Attachments) -> String?) -> Void) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { apply { $0.add(files: [url]) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { apply { $0.add(imageData: data) } }
                }
            }
        }
    }
}
