import AppKit
import SwiftTerm
import SwiftUI

/// Keeps one attached terminal view per hosted session, so switching tabs keeps scrollback and cursor state.
@MainActor
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalHost()
    private var views: [String: LocalProcessTerminalView] = [:]

    func view(for name: String) -> LocalProcessTerminalView {
        if let v = views[name] { return v }
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        v.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        v.processDelegate = self
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "ko_KR.UTF-8"
        env.removeValue(forKey: "TMUX")  // never nest into a tmux the app was started from
        if let tmux = TmuxEngine.tmux {
            // The view is only a client; the session keeps running on the tmux server when it detaches.
            v.startProcess(executable: tmux, args: TmuxEngine.base + ["attach-session", "-t", name],
                           environment: env.map { "\($0.key)=\($0.value)" })
        }
        views[name] = v
        return v
    }

    func drop(_ name: String) {
        views[name]?.process?.terminate()
        views.removeValue(forKey: name)
    }

    // The tmux client exits when its session is killed; forget the view so a new attach starts clean.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            if let name = self.views.first(where: { $0.value === source })?.key { self.views.removeValue(forKey: name) }
        }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct EmbeddedTerminal: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== TerminalHost.shared.view(for: name) { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let term = TerminalHost.shared.view(for: name)
        term.removeFromSuperview()
        term.frame = container.bounds
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
    }
}
