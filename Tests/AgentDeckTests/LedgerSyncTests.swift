import CryptoKit
import Foundation
import XCTest
@testable import AgentDeck

/// A stand-in for the ledger Worker: records requests and answers with receipts signed by its own key.
private final class FakeServer {
    let key = Curve25519.Signing.PrivateKey()
    var requests: [(method: String, path: String, body: [String: Any])] = []
    var clamp = 0
    var forgeSignature = false
    var error: (Int, String)?
    var receiptSeqOffset = 0
    var outstandingClamp = 0      // the server's running pendingClamp, absorbed by adjust entries
    var outstandingIncome = 0     // sales credited to this device but not yet in its ledger
    var reservations: [[String: Any]] = []

    var transport: LedgerSync.Transport {
        { [unowned self] req in try self.handle(req) }
    }

    private func signed(_ body: [String: Any]) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), as: UTF8.self)
        var sig = try key.signature(for: Data(text.utf8))
        if forgeSignature { sig = try Curve25519.Signing.PrivateKey().signature(for: Data(text.utf8)) }
        return try JSONSerialization.data(withJSONObject: ["body": text, "sig": sig.base64EncodedString()])
    }

    private func handle(_ req: URLRequest) throws -> (Data, Int) {
        let path = req.url!.path.replacingOccurrences(of: "/ledger/v1", with: "")
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        requests.append((req.httpMethod ?? "", path, body))
        if let (status, code) = error { return (try JSONSerialization.data(withJSONObject: ["error": code]), status) }
        switch path {
        case "/pubkey":
            return (try JSONSerialization.data(withJSONObject: ["alg": "Ed25519", "key": key.publicKey.rawRepresentation.base64EncodedString()]), 200)
        case "/register":
            return (try JSONSerialization.data(withJSONObject: ["device": "dev-1", "serverSeq": 1]), 201)
        case "/sync":
            let entries = body["entries"] as! [[String: Any]]
            let last = entries.last!
            let reported = entries.filter { $0["kind"] as? String != "income" }.compactMap { $0["amount"] as? Int }.filter { $0 > 0 }.reduce(0, +)
            let absorbed = entries.filter { $0["kind"] as? String == "adjust" }.compactMap { $0["amount"] as? Int }.reduce(0) { $0 - $1 }
            outstandingIncome -= entries.filter { $0["kind"] as? String == "income" }.compactMap { $0["amount"] as? Int }.reduce(0, +)
            outstandingClamp = max(0, outstandingClamp - absorbed) + clamp
            return (try signed(["type": "sync", "device": "dev-1", "fromSeq": entries[0]["seq"]!,
                                "deviceSeq": (last["seq"] as! Int) + receiptSeqOffset, "deviceHash": last["hash"]!,
                                "reported": reported, "accepted": reported - clamp, "clamped": clamp, "pending": 0,
                                "balance": reported - clamp, "pendingClamp": outstandingClamp, "pendingIncome": outstandingIncome,
                                "serverSeq": 9, "head": "h", "time": 1]), 200)
        case "/balance/dev-1":
            return (try signed(["type": "balance", "device": "dev-1", "balance": 0, "pendingClamp": outstandingClamp,
                                "pendingGenesis": 0, "reservations": reservations, "pendingIncome": outstandingIncome,
                                "deviceSeq": 0, "deviceHash": "h",
                                "revoked": false, "serverSeq": 1, "head": "h", "time": 1]), 200)
        case "/spend":
            return (try signed(["type": "spend", "device": "dev-1", "item": body["item"]!, "amount": body["amount"]!,
                                "balance": 0, "serverSeq": 10, "head": "h", "time": 1]), 200)
        default:
            return (Data(), 404)
        }
    }
}

@MainActor
final class LedgerSyncTests: XCTestCase {
    private var dir: URL!
    private var ledger: Ledger!
    private let server = FakeServer()
    private var stateURL: URL { dir.appendingPathComponent("ledger-sync.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        ledger = Ledger(url: dir.appendingPathComponent("ledger.jsonl"), signer: SoftwareSigner())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func client() -> LedgerSync { LedgerSync(ledger: ledger, stateURL: stateURL, transport: server.transport, pinnedKey: "") }

    private func registered() async throws -> LedgerSync {
        let c = client()
        try await c.register(code: "AAAA-BBBB-CCCC")
        return c
    }

    func testRegisterSendsDeviceKeyAndPinsServerKey() async throws {
        _ = try await registered()
        let reg = server.requests.first { $0.path == "/register" }!
        XCTAssertEqual(reg.body["code"] as? String, "AAAA-BBBB-CCCC")
        XCTAssertEqual(reg.body["key"] as? String, ledger.signer!.publicKey.x963Representation.base64EncodedString())

        let reloaded = client()  // state survives a restart
        XCTAssertEqual(reloaded.state.device, "dev-1")
        XCTAssertEqual(reloaded.state.serverKey, server.key.publicKey.rawRepresentation.base64EncodedString())
    }

    func testChangedServerKeyIsRefused() async throws {
        _ = try await registered()
        let impostor = FakeServer()
        let c = LedgerSync(ledger: ledger, stateURL: stateURL, transport: impostor.transport, pinnedKey: "")
        await assertThrows(try await c.register(code: "X")) { XCTAssertEqual($0 as? LedgerSync.Failure, .keyChanged) }
    }

    func testSyncSendsUnconfirmedEntriesOnce() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 5)
        try ledger.append(kind: .earn, source: "b", amount: 2)
        let r = try await c.sync()
        XCTAssertEqual(r?.deviceSeq, 2)
        let sent = server.requests.last!.body["entries"] as! [[String: Any]]
        XCTAssertEqual(sent.map { $0["seq"] as! Int }, [0, 1, 2])
        XCTAssertNotNil(sent[0]["key"])
        XCTAssertNil(sent[1]["key"])  // key appears on the opening entry only; the server rejects it elsewhere

        let before = server.requests.filter { $0.path == "/sync" }.count
        let again = try await c.sync()
        XCTAssertNil(again)
        XCTAssertEqual(server.requests.filter { $0.path == "/sync" }.count, before)  // only a balance check, no resend
    }

    func testClampIsBookedAsAdjustAndSentNextTime() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 50)
        server.clamp = 20
        try await c.sync()
        XCTAssertEqual(ledger.entries.last?.kind, "adjust")
        XCTAssertEqual(ledger.entries.last?.amount, -20)
        XCTAssertEqual(ledger.balance, 30)

        server.clamp = 0
        try await c.sync()
        let sent = server.requests.last!.body["entries"] as! [[String: Any]]
        XCTAssertEqual(sent.map { $0["kind"] as! String }, ["adjust"])
    }

    func testClampMissedLocallyIsBookedFromTheNextReceipt() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 50)
        server.clamp = 20
        try await c.sync()
        // Simulate the adjust having been lost (crash after the ack was saved): drop it from the ledger file.
        let url = ledger.url
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.removeLast()
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        ledger = Ledger(url: url, signer: ledger.signer)
        let again = LedgerSync(ledger: ledger, stateURL: stateURL, transport: server.transport, pinnedKey: "")
        XCTAssertEqual(ledger.balance, 50)

        server.clamp = 0
        try ledger.append(kind: .earn, source: "a", amount: 1)
        try await again.sync()
        XCTAssertEqual(ledger.entries.last?.kind, "adjust")
        XCTAssertEqual(ledger.entries.last?.amount, -20)  // the server still owes nothing for the lost 20
        XCTAssertEqual(ledger.balance, 31)
    }

    func testOrphanedReservationIsBookedBeforeTheNextHire() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 500)
        server.reservations = [["item": "hero8", "amount": 100, "serverSeq": 4]]
        let booked = try await c.bookOpenReservations(note: "영입")
        XCTAssertEqual(booked, 1)
        XCTAssertEqual(ledger.entries.last?.source, "hero8")
        XCTAssertEqual(ledger.entries.last?.amount, -100)
        let second = try await c.bookOpenReservations(note: "영입")
        XCTAssertEqual(second, 0)  // already in the ledger
    }

    func testMarketSaleIsBookedAsIncomeEvenWithNothingToSend() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 5)
        try await c.sync()
        server.outstandingIncome = 270  // someone bought this device's character
        let r = try await c.sync()     // nothing new locally: the client asks for the signed balance
        XCTAssertNil(r)
        XCTAssertEqual(ledger.entries.last?.kind, "income")
        XCTAssertEqual(ledger.entries.last?.amount, 270)
        XCTAssertEqual(ledger.balance, 275)

        try await c.sync()  // sends the income entry; the server's outstanding income drops to 0
        XCTAssertEqual(server.outstandingIncome, 0)
        let again = try await c.sync()
        XCTAssertNil(again)
        XCTAssertEqual(ledger.balance, 275)  // never booked twice
    }

    func testForgedReceiptIsRejectedAndNotAcknowledged() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 5)
        server.forgeSignature = true
        await assertThrows(try await c.sync()) { XCTAssertEqual($0 as? LedgerSync.Failure, .badSignature) }
        XCTAssertNil(c.state.ackSeq)
    }

    func testReceiptForOtherEntriesIsRejected() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 5)
        server.receiptSeqOffset = 1
        await assertThrows(try await c.sync()) { XCTAssertEqual($0 as? LedgerSync.Failure, .unexpected) }
        XCTAssertNil(c.state.ackSeq)
    }

    func testServerErrorCodeIsSurfaced() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 5)
        server.error = (409, "chain_break")
        await assertThrows(try await c.sync()) { XCTAssertEqual($0 as? LedgerSync.Failure, .server(status: 409, code: "chain_break")) }
    }

    func testLargeBacklogGoesInBatches() async throws {
        let c = try await registered()
        for i in 0..<620 { try ledger.append(kind: .genesis, source: "log\(i)", amount: 1) }
        let r = try await c.sync()
        XCTAssertEqual(r?.deviceSeq, 620)
        XCTAssertEqual(server.requests.filter { $0.path == "/sync" }.map { ($0.body["entries"] as! [Any]).count }, [200, 200, 200, 21])
    }

    func testServerWithAnotherKeyThanThePinnedOneIsRefused() async throws {
        let c = LedgerSync(ledger: ledger, stateURL: stateURL, transport: server.transport, pinnedKey: LedgerSync.pinnedServerKey)
        await assertThrows(try await c.register(code: "X")) { XCTAssertEqual($0 as? LedgerSync.Failure, .keyChanged) }
        XCTAssertFalse(server.requests.contains { $0.path == "/register" })
    }

    func testUnregisteredClientDoesNotCall() async {
        await assertThrows(try await client().sync()) { XCTAssertEqual($0 as? LedgerSync.Failure, .notRegistered) }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testSpendRequestIsSignedByTheDeviceKey() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 500)
        try await Recruit.hire("hero8", roster: (0..<12).map { "hero\($0)" }, ledger: ledger,
                               confirm: { try await c.confirmSpend(item: $0, amount: $1, time: Date(timeIntervalSince1970: 1_760_142_000)) })
        let req = server.requests.last { $0.path == "/spend" }!.body
        let message = #"{"action":"spend","amount":100,"device":"dev-1","item":"hero8","time":1760142000}"#
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: req["sig"] as! String)!)
        XCTAssertTrue(ledger.signer!.publicKey.isValidSignature(sig, for: Data(message.utf8)))
        XCTAssertEqual(ledger.entries.last?.kind, "spend")
    }

    func testRefusedSpendLeavesLedgerUntouched() async throws {
        let c = try await registered()
        try ledger.append(kind: .earn, source: "a", amount: 500)
        server.error = (409, "insufficient")
        let before = ledger.entries.count
        await assertThrows(try await Recruit.hire("hero8", roster: (0..<12).map { "hero\($0)" }, ledger: ledger,
                                                  confirm: { try await c.confirmSpend(item: $0, amount: $1) }))
        XCTAssertEqual(ledger.entries.count, before)
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T, _ check: (Error) -> Void = { _ in },
                                 line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected an error", line: line) } catch { check(error) }
    }
}
