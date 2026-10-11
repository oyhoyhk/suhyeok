import CryptoKit
import Foundation
import XCTest
@testable import AgentDeck

final class LedgerTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("ledger.jsonl") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func writeLines(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: canonical form

    func testCanonicalMatchesSharedVectors() throws {
        let vectors = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/ledger/test/vectors.json")
        struct Fields: Decodable { let seq, time, amount, rule: Int; let kind, source, note, prev: String; let key: String? }
        struct Case: Decodable { let fields: Fields; let canonical: String; let hash: String }
        struct File: Decodable { let cases: [Case] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: vectors))
        XCTAssertEqual(file.cases.count, 3)
        for c in file.cases {
            let f = c.fields
            let e = LedgerEntry(seq: f.seq, time: f.time, kind: f.kind, source: f.source, amount: f.amount, rule: f.rule,
                                note: f.note, key: f.key, prev: f.prev, hash: "", sig: "")
            XCTAssertEqual(e.canonical, c.canonical)
            XCTAssertEqual(e.computedHash, c.hash)
        }
    }

    // MARK: append and verify

    func testAppendThreeEntries() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        try ledger.append(kind: .earn, source: "b.jsonl", amount: 7)
        try ledger.append(kind: .spend, source: "knight", amount: -4)
        XCTAssertEqual(ledger.balance, 8)

        let reloaded = Ledger(url: url, signer: ledger.signer)
        XCTAssertEqual(reloaded.status, .ok)
        XCTAssertEqual(reloaded.balance, 8)
        XCTAssertEqual(reloaded.entries.count, 4)  // opening entry + 3
        XCTAssertEqual(reloaded.entries[0].kind, LedgerEntry.Kind.open.rawValue)
        XCTAssertEqual(reloaded.entries[0].prev, String(repeating: "0", count: 64))
        XCTAssertNotNil(reloaded.entries[0].key)
    }

    func testEditedAmountBreaksAtThatEntry() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        try ledger.append(kind: .earn, source: "b.jsonl", amount: 7)
        var l = try lines()
        l[2] = l[2].replacingOccurrences(of: "\"amount\":7", with: "\"amount\":700")
        try writeLines(l)
        XCTAssertEqual(Ledger(url: url, signer: nil).status, .broken(seq: 2))
    }

    func testReorderedEntriesBreak() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        try ledger.append(kind: .earn, source: "b.jsonl", amount: 7)
        var l = try lines()
        l.swapAt(1, 2)
        try writeLines(l)
        XCTAssertEqual(Ledger(url: url, signer: nil).status, .broken(seq: 1))
    }

    func testRecomputedChainWithoutKeyFailsSignature() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        try ledger.append(kind: .earn, source: "b.jsonl", amount: 7)
        // An attacker rewrites the amount and recomputes every hash, but cannot re-sign.
        var entries = ledger.entries
        entries[1].amount = 500
        var prev = entries[0].hash
        for i in 1..<entries.count {
            entries[i].prev = prev
            entries[i].hash = entries[i].computedHash
            prev = entries[i].hash
        }
        try writeLines(entries.map(\.line))
        XCTAssertEqual(Ledger(url: url, signer: nil).status, .broken(seq: 1))
    }

    func testEntrySignedByAnotherKeyBreaks() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        // Someone else's key appends a properly chained, properly self-signed entry.
        let intruder = Ledger(url: url, signer: SoftwareSigner())
        XCTAssertEqual(intruder.status, .readOnly(.keyMismatch))
        XCTAssertThrowsError(try intruder.append(kind: .earn, source: "x", amount: 99))

        var entries = ledger.entries
        let other = SoftwareSigner()
        var forged = LedgerEntry(seq: 2, time: 1, kind: "earn", source: "x", amount: 99, rule: 1, note: "",
                                 key: nil, prev: entries[1].hash, hash: "", sig: "")
        forged.hash = forged.computedHash
        forged.sig = try other.sign(Data(forged.canonical.utf8)).base64EncodedString()
        entries.append(forged)
        try writeLines(entries.map(\.line))
        XCTAssertEqual(Ledger(url: url, signer: nil).status, .broken(seq: 2))
    }

    func testTornLastLineIsIgnoredAndOverwritten() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"amount\":9,\"ki".utf8))
        try h.close()

        let reloaded = Ledger(url: url, signer: ledger.signer)
        XCTAssertEqual(reloaded.status, .ok)
        XCTAssertEqual(reloaded.balance, 5)
        try reloaded.append(kind: .earn, source: "b.jsonl", amount: 1)
        let again = Ledger(url: url, signer: nil)
        XCTAssertTrue(again.isVerified)
        XCTAssertEqual(again.balance, 6)
    }

    func testOverspendIsRejected() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 10)
        XCTAssertThrowsError(try ledger.append(kind: .spend, source: "knight", amount: -20)) {
            XCTAssertEqual($0 as? Ledger.Failure, .insufficient)
        }
        XCTAssertEqual(ledger.balance, 10)
        XCTAssertEqual(Ledger(url: url, signer: nil).entries.count, 2)
    }

    func testNoKeyMeansReadOnlyButVerifiable() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        let keyless = Ledger(url: url, signer: nil)
        XCTAssertEqual(keyless.status, .readOnly(.noKey))
        XCTAssertTrue(keyless.isVerified)
        XCTAssertThrowsError(try keyless.append(kind: .earn, source: "b", amount: 1))
    }

    func testBrokenLedgerRefusesAppendAndCanStartOver() throws {
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 5)
        var l = try lines()
        l[1] = l[1].replacingOccurrences(of: "\"amount\":5", with: "\"amount\":6")
        try writeLines(l)

        let broken = Ledger(url: url, signer: ledger.signer)
        XCTAssertEqual(broken.status, .broken(seq: 1))
        XCTAssertThrowsError(try broken.append(kind: .earn, source: "b", amount: 1))

        let archived = try broken.startOver()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertEqual(broken.status, .ok)
        XCTAssertEqual(broken.balance, 0)
        try broken.append(kind: .earn, source: "b", amount: 1)
        XCTAssertEqual(Ledger(url: url, signer: nil).balance, 1)
    }

    // MARK: Secure Enclave

    func testSecureEnclaveSignerRoundTrip() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this Mac")
        let signer = try SecureEnclaveSigner()
        XCTAssertEqual(signer.strength, .secureEnclave)
        let ledger = Ledger(url: url, signer: signer)
        try ledger.append(kind: .earn, source: "a.jsonl", amount: 3)
        let reloaded = Ledger(url: url, signer: nil)
        XCTAssertTrue(reloaded.isVerified)
        XCTAssertEqual(reloaded.balance, 3)
    }
}
