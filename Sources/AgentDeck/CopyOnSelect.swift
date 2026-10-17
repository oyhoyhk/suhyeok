import AppKit
import SwiftTerm

/// Selecting text with the mouse copies it right away, like a terminal: the dialogue's messages, choice cards,
/// screen preview. The embedded agent terminals copy on their own: Claude Code sends its selection as OSC 52
/// through tmux and SwiftTerm puts it on the pasteboard; a shift-drag selects in SwiftTerm itself (`CopyingTerminalView`).
@MainActor
enum CopyOnSelect {
    private static var monitor: Any?
    /// The view under the last mouse-down, until that press is handled.
    private static var pressed: NSView?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            if e.type == .leftMouseDown { pressed = e.window?.contentView?.hitTest(e.locationInWindow) }
            // Text views select in a tracking loop that swallows the mouse-up, so also check right after the
            // mouse-down is handled: if the button is up by then, the loop has finished.
            let window = e.window
            DispatchQueue.main.async { finish(window) }
            return e
        }
        // The default highlight (dim blue, gray when inactive) barely shows on the dark dialogue. The field editor
        // resets its attributes whenever a text starts selecting, so set them on each selection change instead.
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil,
                                               queue: nil) { n in
            guard let text = n.object as? NSTextView, !text.isEditable,  // the draft field keeps the system look
                  text.selectedTextAttributes[.backgroundColor] as? NSColor != highlight else { return }
            text.selectedTextAttributes = [.backgroundColor: highlight, .foregroundColor: NSColor.black]
        }
    }

    /// The dialogue's gold accent, with black text on it.
    nonisolated private static let highlight = NSColor(srgbRed: 0.85, green: 0.68, blue: 0.25, alpha: 1)

    private static func finish(_ window: NSWindow?) {
        guard NSEvent.pressedMouseButtons & 1 == 0, let hit = pressed else { return }  // still dragging
        pressed = nil
        // Only when the press was on text (SwiftUI's selectable Text is a text field whose editor is the responder),
        // so a click elsewhere does not copy a selection left behind earlier.
        guard hit is NSText || hit is NSTextField, let responder = window?.firstResponder as? NSView,
              hit === responder || responder.isDescendant(of: hit) || hit.isDescendant(of: responder) else { return }
        if let text = responder as? NSTextView, text.isEditable { return }  // the draft field: selecting there is editing
        let copy = #selector(NSText.copy(_:))
        guard let target = NSApp.target(forAction: copy, to: nil, from: nil) else { return }
        let item = NSMenuItem(title: "", action: copy, keyEquivalent: "")
        if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { return }
        if let v = target as? NSUserInterfaceValidations, !v.validateUserInterfaceItem(item) { return }
        NSApp.sendAction(copy, to: target, from: item)
    }
}

/// SwiftTerm view that copies a shift-drag selection (made in the view, bypassing tmux) on release.
final class CopyingTerminalView: LocalProcessTerminalView {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if selectionActive { copy(self) }
    }
}
