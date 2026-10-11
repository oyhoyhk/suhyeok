import Foundation
import XCTest
@testable import AgentDeck

/// The app's real client code against the real ledger Worker running in `wrangler dev` (local workerd, local
/// D1 and R2). Skipped unless LEDGER_E2E_BASE (e.g. http://localhost:8797/ledger/v1) and LEDGER_E2E_ADMIN are set.
///
///   cd server/ledger && npx wrangler dev --local --port 8797 --persist-to <scratch dir>
///   LEDGER_E2E_BASE=http://localhost:8797/ledger/v1 LEDGER_E2E_ADMIN=<token> swift test --filter MarketEndToEndTests
@MainActor
final class MarketEndToEndTests: XCTestCase {
    private var base = ""
    private var admin = ""
    private var dir: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let b = env["LEDGER_E2E_BASE"], let a = env["LEDGER_E2E_ADMIN"] else { throw XCTSkip("set LEDGER_E2E_BASE and LEDGER_E2E_ADMIN") }
        base = b; admin = a
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func adminCall(_ method: String, _ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(admin)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertLessThan((resp as! HTTPURLResponse).statusCode, 300, String(decoding: data, as: UTF8.self))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// A device with its own ledger, registered with a fresh admin code.
    private func device(_ name: String) async throws -> (Ledger, LedgerSync, AssetLibrary) {
        let d = dir.appendingPathComponent(name)
        let ledger = Ledger(url: d.appendingPathComponent("ledger.jsonl"), signer: SoftwareSigner())
        var state = LedgerSync.State()
        state.base = base
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: d.appendingPathComponent("sync.json"))
        let sync = LedgerSync(ledger: ledger, stateURL: d.appendingPathComponent("sync.json"), pinnedKey: "")
        let code = try await adminCall("POST", "/admin/codes")["code"] as! String
        try await sync.register(code: code)
        return (ledger, sync, AssetLibrary(root: d.appendingPathComponent("assets")))
    }

    func testUploadApproveBuyInstallAndIncome() async throws {
        let pack = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/ledger/test/asset-vectors/ok_knight")

        // Seller uploads the knight; the operator approves it.
        let (sellerLedger, sellerSync, sellerLib) = try await device("seller")
        try sellerLedger.append(kind: .earn, source: "s", amount: 1)
        try await sellerSync.sync()
        let seller = MarketService(sync: sellerSync, ledger: sellerLedger, library: sellerLib)
        let id = try await seller.upload(folder: pack, price: 300, alias: "오윤환", description: "번개 기사\n테스트")
        _ = try await adminCall("POST", "/admin/market/\(id)/approve")

        // Buyer gets crystals through approved history, then buys and installs.
        let (buyerLedger, buyerSync, buyerLib) = try await device("buyer")
        try buyerLedger.append(kind: .genesis, source: "history", amount: 1000)
        try await buyerSync.sync()
        let dev = buyerSync.state.device!
        _ = try await adminCall("POST", "/admin/devices/\(dev)/genesis/approve")
        let buyer = MarketService(sync: buyerSync, ledger: buyerLedger, library: buyerLib)
        let listing = try await buyer.listings().first { $0.id == id }!
        XCTAssertEqual(listing.seller.alias, "오윤환")
        try await buyer.buy(listing)
        XCTAssertEqual(buyerLib.characters.map(\.id), ["market.\(id)"])
        XCTAssertNotNil(buyerLib.file(forArtName: "frames/market.\(id)/attack_3"))
        try await buyerSync.sync()  // the local spend consumes the server reservation: no second charge
        let serverBuyer = try await buyerSync.balance()
        XCTAssertEqual(serverBuyer.balance, 700)
        XCTAssertEqual(buyerLedger.balance, 700)

        // The seller's next sync books 90% as income; local and server balances agree.
        try await sellerSync.sync()
        XCTAssertEqual(sellerLedger.entries.last?.kind, "income")
        XCTAssertEqual(sellerLedger.entries.last?.amount, 270)
        try await sellerSync.sync()  // sends the income entry
        let s = try await sellerSync.balance()
        XCTAssertEqual(s.balance, sellerLedger.balance)
        XCTAssertEqual(s.pendingIncome, 0)

        let verify = try await adminCall("GET", "/admin/verify")
        XCTAssertEqual(verify["ok"] as? Bool, true)
        XCTAssertEqual(verify["burned"] as? Int, 30)
    }
}
