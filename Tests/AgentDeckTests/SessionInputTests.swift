import XCTest
@testable import AgentDeck

final class SessionInputTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)

    private func claude(_ box: String) -> String {
        "⏺ 이전 답변\n\n\(rule)\n❯ \(box)\n\(rule)\n   ◆ Opus 5.5 │ ~/project\n  ⏵⏵ bypass permissions on"
    }

    func testMessageLeftInClaudeInputBoxIsDetected() {
        let text = "길드 결정 메뉴에서 각 캐릭터에 호버하면 정보를 보여줘"
        XCTAssertTrue(SessionInput.stillTyped(text, in: claude(text)))
        // Wrapped across lines in the box.
        XCTAssertTrue(SessionInput.stillTyped(text, in: claude("길드 결정 메뉴에서 각 캐릭터에 호버하면\n  정보를 보여줘")))
        XCTAssertTrue(SessionInput.stillTyped(text, in: claude("[Pasted text #1 +12 lines]")))
    }

    func testSubmittedMessageIsNotDetected() {
        let text = "운영서버 배포해줘"
        // Submitted: echoed above the box, box empty.
        let screen = "> \(text)\n\n✢ Swirling…\n\(rule)\n❯ \n\(rule)\n  ⏵⏵ bypass permissions on"
        XCTAssertFalse(SessionInput.stillTyped(text, in: screen))
        XCTAssertFalse(SessionInput.stillTyped(text, in: "zsh: plain shell\n$ "))
    }

    func testCodexPromptLine() {
        let text = "테스트 돌려줘"
        XCTAssertTrue(SessionInput.stillTyped(text, in: "• 작업 완료\n\n› 테스트 돌려줘\n\n  ⏎ send   ⌃J newline"))
        XCTAssertFalse(SessionInput.stillTyped(text, in: "› 테스트 돌려줘\n\n• 작업 중\n\n› Ask Codex to do anything\n  ⏎ send"))
    }

    /// AskUserQuestion with previews draws the focused option's preview in a box to the right of the options
    /// (captured from Claude Code v2.1.296): the box is not part of the labels or their descriptions.
    func testMenuWithPreviewPane() {
        let screen = """
         ☐ Format

        이 지적, 어떻게 볼까요?

        ❯ 1. 한 번에 3개 (추천)           ┌──────────────────────────────────────────┐
          2. 지금처럼 2단계 질문          │ ┌ demo ┐                                 │
                                          │ ( ) 맞는 지적 · 계속 알려줘              │
                                          │ → 근거(file:line 등)                     │
                                          └──────────────────────────────────────────┘

                                          Notes: press n to add notes

        \(rule)
          Chat about this

        Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
        """
        let menu = TerminalMenu.parse(screen)
        XCTAssertEqual(menu?.options, [.init(label: "한 번에 3개 (추천)", detail: nil),
                                       .init(label: "지금처럼 2단계 질문", detail: nil)])
        XCTAssertEqual(menu?.selected, 0)
        XCTAssertEqual(menu?.question, "이 지적, 어떻게 볼까요?")
    }

    /// A multi-select question followed by more questions ends with "Next", not "Submit" (Claude Code v2.1.300).
    func testMultiSelectWithMoreQuestionsKeepsNextRow() {
        let screen = """
        \(rule)
        ←  ☐ Fruits  ☐ Color  ✔ Submit  →

        Which fruits do you like?

        ❯ 1. [ ] Apple
                 Crisp and slightly tart
          2. [ ] Banana
                 Soft and sweet
          3. [ ] Cherry
                 Small and juicy
          4. [ ] Type something
             Next
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let menu = TerminalMenu.parse(screen)
        XCTAssertEqual(menu?.options.map(\.label),
                       ["[ ] Apple", "[ ] Banana", "[ ] Cherry", "[ ] Type something", "Next", "Chat about this"])
        XCTAssertEqual(menu?.selected, 0)
        XCTAssertEqual(menu?.question, "Which fruits do you like?")
    }
}
