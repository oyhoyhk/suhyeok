import Foundation
import XCTest
@testable import AgentDeck

final class PersonaTests: XCTestCase {
    private func session(_ n: Int) -> AgentSession {
        AgentSession(id: "s\(n)", agent: .claude, name: "", cwd: "/", status: .busy, startedAt: Date(timeIntervalSince1970: Double(n)),
                     updatedAt: nil, lastUser: nil, lastAssistant: nil, estimated: false)
    }

    func testAgentIsCalledByItsCharactersKoreanName() {
        let roster = [Character(id: "mage", name: "Mira", ko: "미라"), Character(id: "market.x", name: "Zed")]
        let sessions = (0..<3).map(session)
        let names = AgentNames.assign(sessions, assignments: ["s0": 0, "s1": 1, "s2": 0], roster: roster)
        XCTAssertEqual(names, ["s0": "미라", "s1": "Zed", "s2": "미라 2"])
    }

    func testEnglishUIUsesTheEnglishNameWithTheSameNumbering() {
        let roster = [Character(id: "mage", name: "Mira", ko: "미라"), Character(id: "market.x", name: "Zed")]
        let names = AgentNames.assign((0..<3).map(session), assignments: ["s0": 0, "s1": 1, "s2": 0], roster: roster, english: true)
        XCTAssertEqual(names, ["s0": "Mira", "s1": "Zed", "s2": "Mira 2"])
    }

    func testPinnedSessionKeepsItsCharacterAndOthersMoveAside() {
        var assigner = CharacterAssigner()
        let first = assigner.update([session(0)], rosterCount: 4)
        let taken = first["s0"]!
        // A later session launched with the same character takes it; the unpinned one draws another.
        let next = assigner.update([session(0), session(1)], pinned: ["s1": taken], rosterCount: 4)
        XCTAssertEqual(next["s1"], taken)
        XCTAssertNotEqual(next["s0"], taken)
    }

    func testTwoSessionsPinnedToOneCharacterDoNotShareIt() {
        var assigner = CharacterAssigner()
        // s1 started first; s2 (say, an agent it launched) claims the same character.
        let picks = assigner.update([session(2), session(1)], pinned: ["s1": 0, "s2": 0], rosterCount: 4)
        XCTAssertEqual(picks["s1"], 0)
        XCTAssertNotEqual(picks["s2"], 0)
    }

    func testDescendsFollowsTheProcessTree() {
        XCTAssertTrue(SessionTree.descends(getpid(), from: getpid()))
        XCTAssertTrue(SessionTree.descends(getpid(), from: getppid()))
        XCTAssertFalse(SessionTree.descends(getppid(), from: getpid()))
    }

    func testBackToBackLaunchesFollowTheLineup() {
        let lineup = [5, 2, 9, 0]
        var starting = Set<Int>()
        var picked: [Int] = []
        for _ in lineup { let i = SessionStore.pick(lineup: lineup, live: [], starting: starting)!; starting.insert(i); picked.append(i) }
        XCTAssertEqual(picked, lineup)  // launches before any refresh take the lineup in order, no repeats
        XCTAssertEqual(SessionStore.pick(lineup: lineup, live: [5], starting: [2]), 9)
        XCTAssertEqual(SessionStore.pick(lineup: [0], live: [0], starting: [0]), 0)  // more agents than characters
    }

    func testRandomLaunchesTakeFreeCharactersInAnyOrder() {
        let lineup = Array(0..<20)
        var orders = Set<[Int]>()
        for _ in 0..<5 {
            var starting = Set<Int>(), picked: [Int] = []
            for _ in lineup {
                let i = SessionStore.pick(lineup: lineup, live: [3], starting: starting, random: true)!
                if picked.count < lineup.count - 1 { XCTAssertNotEqual(i, 3) }  // live characters wait until all are taken
                starting.insert(i); picked.append(i)
            }
            XCTAssertEqual(Set(picked).count, lineup.count)  // no repeats while free ones remain
            orders.insert(picked)
        }
        XCTAssertGreaterThan(orders.count, 1)  // not the lineup order every time
        XCTAssertEqual(SessionStore.pick(lineup: [7], live: [7], starting: [7], random: true), 7)
    }

    func testRandomAssignerSpreadsSessionsAndKeepsThem() {
        let sessions = (0..<6).map {
            AgentSession(id: "r\($0)", agent: .claude, name: "", cwd: "/", status: .busy,
                         startedAt: Date(timeIntervalSince1970: Double($0)), updatedAt: nil, lastUser: nil,
                         lastAssistant: nil, estimated: false)
        }
        var assigner = CharacterAssigner()
        let first = assigner.update(sessions, random: true, rosterCount: 30)
        XCTAssertEqual(Set(first.values).count, 6)  // no two live sessions share a character
        XCTAssertNotEqual(first.values.sorted(), Array(0..<6))  // not simply the first six
        XCTAssertEqual(assigner.update(sessions, random: true, rosterCount: 30), first)  // refreshes keep them
    }

    func testLineupKeepsSavedOrderAndAppendsNewCharacters() {
        let roster = ["a", "b", "c", "market.x"].map { Character(id: $0, name: $0) }
        XCTAssertEqual(Lineup.order(roster, saved: ["c", "gone", "a", "c"]), [2, 0, 1, 3])
        XCTAssertEqual(Lineup.order(roster, saved: []), [0, 1, 2, 3])
    }

    func testAssignerGivesNewSessionsTheLineupInOrder() {
        var assigner = CharacterAssigner()
        let picks = assigner.update([session(0), session(1), session(2)], order: [3, 1, 0, 2], rosterCount: 4)
        XCTAssertEqual([picks["s0"], picks["s1"], picks["s2"]], [3, 1, 0])  // oldest session first
    }

    func testInstructionsCarryTheVoiceAndItsLimits() {
        XCTAssertNil(Persona.instructions(for: Character(id: "market.x", name: "Zed")))
        let text = Persona.instructions(for: Character(id: "cat", name: "Mochi", ko: "모찌", tone: "문장 끝을 '~냥'으로 맺음"))!
        XCTAssertTrue(text.contains("모찌"))
        XCTAssertTrue(text.contains("'~냥'"))
        XCTAssertTrue(text.contains("commit messages"))
    }

    func testTomlStringEscapesQuotesBackslashesAndNewlines() {
        XCTAssertEqual(TmuxEngine.tomlString("a \"b\" \\ c\nd"), #""a \"b\" \\ c\nd""#)
    }

    func testBundledRosterHasAVoiceForEveryCharacter() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../art/roster.json")
        let roster = try JSONDecoder().decode([Character].self, from: Data(contentsOf: url))
        XCTAssertEqual(roster.count, 32)
        XCTAssertTrue(roster.allSatisfy { $0.ko != nil && !($0.tone ?? "").isEmpty })
        XCTAssertTrue(roster.allSatisfy { !($0.roleEn ?? "").isEmpty })  // the class shown in English
    }
}
