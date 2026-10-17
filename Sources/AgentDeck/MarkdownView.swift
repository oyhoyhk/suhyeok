import SwiftUI
import WebKit

/// Block-level markdown for agent replies: headings, lists, quotes, rules, tables, code blocks and mermaid
/// diagrams. Inline styling (bold, code, links) goes through AttributedString.
struct MarkdownView: View {
    let text: String
    /// Base for relative file paths, which become ⌘-click links (see FileLinks).
    var cwd: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.group(MarkdownBlock.parse(text)).enumerated()), id: \.offset) { _, part in
                switch part {
                case .prose(let blocks): Text(prose(blocks)).fixedSize(horizontal: false, vertical: true)
                case .block(let block): view(for: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs of text blocks (headings, paragraphs, lists, quotes) go into one Text, because a drag selects
    /// inside a single Text only; code, tables, rules and diagrams stay views of their own.
    private enum Part { case prose([MarkdownBlock]), block(MarkdownBlock) }

    private static func group(_ blocks: [MarkdownBlock]) -> [Part] {
        var out: [Part] = []
        for b in blocks {
            switch b {
            case .heading, .paragraph, .list, .quote:
                if case .prose(let run)? = out.last { out[out.count - 1] = .prose(run + [b]) } else { out.append(.prose([b])) }
            default: out.append(.block(b))
            }
        }
        return out
    }

    private func prose(_ blocks: [MarkdownBlock]) -> AttributedString {
        var out = AttributedString()
        // A blank line in a small font: about the 8pt gap the separate views had.
        var gap = AttributedString("\n\n")
        gap.font = .system(size: 5)
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += gap }
            switch block {
            case .heading(let level, let t):
                var h = inline(t)
                h.font = level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline
                out += h
            case .paragraph(let t):
                out += inline(t)
            case .list(let items):
                for (j, item) in items.enumerated() {
                    var marker = AttributedString(String(repeating: "    ", count: item.indent) + item.marker + " ")
                    marker.foregroundColor = .secondary
                    out += (j > 0 ? AttributedString("\n") : AttributedString()) + marker + inline(item.text)
                }
            case .quote(let t):
                var q = inline(t.split(separator: "\n", omittingEmptySubsequences: false).map { "▎ " + $0 }.joined(separator: "\n"))
                q.foregroundColor = .secondary
                out += q
            default: break
            }
        }
        return out
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .rule:
            Divider()
        case .code(let lang, let body):
            if lang == "mermaid" {
                MermaidView(source: body)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(FileLinks.link(AttributedString(body), cwd: cwd))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in Text(inline(h)).bold() }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { i in
                                Text(inline(i < r.count ? r[i] : "")).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .heading, .paragraph, .list, .quote:
            EmptyView()  // drawn by prose(_:)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        FileLinks.link((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s), cwd: cwd)
    }
}

enum MarkdownBlock {
    struct Item { let indent: Int; let marker: String; let text: String }
    case heading(Int, String)
    case paragraph(String)
    case list([Item])
    case quote(String)
    case rule
    case code(String, String)
    case table([String], [[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var i = 0
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                out.append(.code(lang, body.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }
            if let m = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                out.append(.heading(t[m].filter { $0 == "#" }.count, String(t[m.upperBound...])))
                i += 1; continue
            }
            if t.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flush(); out.append(.rule); i += 1; continue }
            // Table: a "|" row followed by a |---|---| separator.
            if t.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flush()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                out.append(.table(header, rows))
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }
            if line.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil {
                flush()
                var items: [Item] = []
                while i < lines.count, let m = lines[i].range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                    let l = lines[i]
                    let indent = l.prefix { $0 == " " }.count / 2
                    let mk = l[m].trimmingCharacters(in: .whitespaces)
                    var body = String(l[m.upperBound...])
                    i += 1
                    // Continuation lines indented under the item.
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                          lines[i].hasPrefix("  "), lines[i].range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) == nil {
                        body += " " + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                    }
                    items.append(Item(indent: indent, marker: ["-", "*", "+"].contains(mk) ? "•" : mk, text: body))
                }
                out.append(.list(items))
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }
}

/// A mermaid diagram rendered offline with the bundled mermaid.min.js; height follows the drawing.
struct MermaidView: View {
    let source: String
    @State private var height: CGFloat = 160

    var body: some View {
        MermaidWeb(source: source, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MermaidWeb: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "size")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        load(web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != source { load(web); context.coordinator.loaded = source }
    }

    private func load(_ web: WKWebView) {
        guard let js = Self.mermaidJS else { return }
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html,body{margin:0;background:transparent;color:#ddd;font:13px -apple-system}
            .mermaid{display:flex;justify-content:center;padding:8px}
            .err{color:#f6a;font:12px ui-monospace;white-space:pre-wrap;padding:8px}</style>
            <script>\(js)</script></head><body>
            <pre class="mermaid">\(escaped)</pre>
            <script>
            mermaid.initialize({startOnLoad:false, theme:'dark', securityLevel:'strict'});
            mermaid.run().catch(e => { document.body.innerHTML = '<div class="err">\(String(localized: "다이어그램 오류")): ' + (e.message||e) + '</div>'; })
              .finally(() => setTimeout(() => webkit.messageHandlers.size.postMessage(document.body.scrollHeight), 50));
            </script></body></html>
            """
        // Inlined: a file:// base URL does not give a WKWebView read access to the bundled script.
        web.loadHTMLString(html, baseURL: nil)
    }

    private static let mermaidJS: String? = {
        guard let url = Art.dir?.appendingPathComponent("web/mermaid.min.js") else { return nil }
        // "</script>" inside the bundle would end the inline tag early.
        return (try? String(contentsOf: url, encoding: .utf8))?.replacingOccurrences(of: "</script>", with: "<\\/script>")
    }()

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MermaidWeb
        var loaded: String?
        init(_ p: MermaidWeb) { parent = p; loaded = p.source }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if ProcessInfo.processInfo.environment["SUHYEOK_DEBUG"] != nil { print("mermaid height", m.body) }
            if let h = m.body as? Double { DispatchQueue.main.async { self.parent.height = min(max(CGFloat(h) + 4, 60), 900) } }
            else if let h = m.body as? Int { DispatchQueue.main.async { self.parent.height = min(max(CGFloat(h) + 4, 60), 900) } }
        }
    }
}
