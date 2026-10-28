import AppKit
import SwiftTerm
import SwiftUI

/// Keeps one attached terminal view per hosted session, so switching tabs keeps scrollback and cursor state.
@MainActor
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalHost()
    private var views: [String: LocalProcessTerminalView] = [:]
    /// The container each terminal was last put in. A container SwiftUI has not removed yet (the pane a session just
    /// left, e.g. when two split panes swap) must not take the terminal back, or it leaves with it.
    private var owners: [String: Owner] = [:]
    private final class Owner { weak var container: NSView?; init(_ c: NSView) { container = c } }

    func claim(_ name: String, for container: NSView) { owners[name] = Owner(container) }

    /// True for the container that last claimed the terminal, or any container once that one is gone.
    func mayHold(_ name: String, in container: NSView) -> Bool {
        guard let owner = owners[name]?.container else { return true }
        return owner === container
    }

    func view(for name: String) -> LocalProcessTerminalView {
        if let v = views[name] { return v }
        let v = CopyingTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
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
        TerminalHost.shared.claim(name, for: container)
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Re-attach a terminal that was replaced (its tmux client ended), but never pull one out of a newer pane.
        guard TerminalHost.shared.mayHold(name, in: container) else { return }
        if container.subviews.first !== TerminalHost.shared.view(for: name) {
            TerminalHost.shared.claim(name, for: container)
            attach(to: container)
        }
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
