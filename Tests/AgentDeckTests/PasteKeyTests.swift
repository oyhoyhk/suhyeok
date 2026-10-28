import AppKit
import XCTest
@testable import AgentDeck

final class PasteKeyTests: XCTestCase {
    private func key(_ chars: String, _ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testCommandV() {
        XCTAssertTrue(PasteCatcher.CatcherView.isV(key("v", 9)))    // ABC / US
        XCTAssertTrue(PasteCatcher.CatcherView.isV(key("ㅍ", 9)))   // Korean 2-set: the V key types ㅍ
        XCTAssertTrue(PasteCatcher.CatcherView.isV(key("v", 47)))   // Dvorak: V sits on another key
        XCTAssertFalse(PasteCatcher.CatcherView.isV(key("k", 9)))   // Dvorak ⌘K on the V key's position
        XCTAssertFalse(PasteCatcher.CatcherView.isV(key("c", 8)))
    }
}
