import Foundation
import XCTest
@testable import AgentDeck

/// Screens captured from Claude Code 2.1.312 and Codex 0.162.1 (Fixtures/screens, local paths replaced).
/// When an update changes what these agents draw, capture the new screens next to these and see what breaks.
final class ScreenFixtureTests: XCTestCase {
    private func screen(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/screens/\(name).txt"), encoding: .utf8)
    }

    func testClaudeFolderTrust() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("claude-trust")))
        XCTAssertEqual(m.options.map(\.label), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(m.selected, 0)  // 2.1.312 highlights "No, exit"
    }

    func testClaudePermission() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("claude-permission")))
        XCTAssertEqual(m.question, "Do you want to proceed?")
        XCTAssertEqual(m.options.map(\.label), ["Yes", "Yes, and always allow access to",
                                                 "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"])
        XCTAssertTrue(m.options[1].detail?.hasSuffix("from this project") ?? false)  // the wrapped rest of the label
        XCTAssertTrue(m.context?.contains("rm now.txt") ?? false)
        XCTAssertFalse(m.context?.contains("Tip:") ?? true)
    }

    func testCodexFolderTrust() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("codex-trust")))
        XCTAssertEqual(m.options.map(\.label), ["Trust and continue", "Back to Agent Command Center"])
    }

    func testCodexResumeDirectoryQuestion() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("codex-resume-cwd-menu")))
        XCTAssertEqual(m.options.map(\.label), ["Use session directory (/tmp/other-session/", "Use current directory (/tmp/",
                                                 "Always use session directory", "Always use current directory"])
        XCTAssertEqual(m.selected, 0)
    }

    /// Antigravity CLI 1.4.12 highlights with ">", like its input box and the prompts it echoes.
    func testAntigravityFolderTrust() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("agy-trust")))
        XCTAssertEqual(m.options.map(\.label), ["Yes, I trust this folder", "No, exit"])
        XCTAssertEqual(m.selected, 0)
    }

    func testAntigravityPermission() throws {
        let m = try XCTUnwrap(TerminalMenu.parse(try screen("agy-permission")))
        XCTAssertEqual(m.question, "Run this command?")
        XCTAssertEqual(m.options.count, 4)
        XCTAssertEqual(m.options.first?.label, "Yes, run command")
        XCTAssertEqual(m.options.last?.label, "No, cancel")
        XCTAssertTrue(m.context?.contains("date > now.txt") ?? false)
    }

    func testAntigravityScreensWithoutMenu() throws {
        for name in ["agy-idle", "agy-typed", "agy-working", "agy-replied", "agy-slash"] {
            XCTAssertNil(TerminalMenu.parse(try screen(name)), name)
        }
    }

    func testUnsentTextInAntigravityInputBox() throws {
        XCTAssertTrue(SessionInput.stillTyped("이 폴더의 파일 목록을 알려줘", in: try screen("agy-typed")))
        XCTAssertFalse(SessionInput.stillTyped("이 폴더의 파일 목록을 알려줘", in: try screen("agy-idle")))
        XCTAssertFalse(SessionInput.stillTyped("Run the shell command: date > now.txt", in: try screen("agy-replied")))
    }

    func testNoMenuWhenIdleWorkingOrDone() throws {
        for name in ["claude-idle", "claude-typed", "claude-working", "claude-replied", "codex-idle"] {
            XCTAssertNil(TerminalMenu.parse(try screen(name)), name)
        }
    }

    func testUnsentTextInClaudeInputBox() throws {
        XCTAssertTrue(SessionInput.stillTyped("이 저장소의 파일 목록을 알려줘", in: try screen("claude-typed")))
        XCTAssertFalse(SessionInput.stillTyped("이 저장소의 파일 목록을 알려줘", in: try screen("claude-idle")))
        // Sent and answered: the prompt is in the scrollback, the box is empty.
        let sent = "Run exactly this shell command with the Bash tool: date > now.txt"
        XCTAssertFalse(SessionInput.stillTyped(sent, in: try screen("claude-replied")))
    }

    func testWorkingSpinnerIsTheLiveStatus() throws {
        let live = LiveReply.parse(try screen("claude-working"), alreadyLogged: nil)
        XCTAssertEqual(live?.status?.hasPrefix("Cascading"), true)
    }

    /// Panels (2.1.314) are not menus, so a message sent into one closes it first instead of waiting behind it.
    func testPanelsAreNotMenus() throws {
        XCTAssertNil(TerminalMenu.parse(try screen("claude-status-panel")))
        XCTAssertNil(TerminalMenu.parse(try screen("claude-config-panel")))
        // The model picker is also "dialog open" in the registry, but it is a menu: left for the user to answer.
        XCTAssertEqual(TerminalMenu.parse(try screen("claude-model-menu"))?.selected, 1)
    }

    func testPanelFromRegistry() {
        XCTAssertTrue(ClaudeSource.isPanel(["status": "waiting", "waitingFor": "dialog open"]))
        // A dialog that asks for a choice is answered, not closed.
        XCTAssertFalse(ClaudeSource.isPanel(["waitingFor": "dialog open", "needs": "choose: retry on fallback model or edit prompt"]))
        XCTAssertFalse(ClaudeSource.isPanel(["status": "waiting", "waitingFor": "input needed"]))
        XCTAssertFalse(ClaudeSource.isPanel(["status": "idle"]))
    }
}
