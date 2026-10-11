import CryptoKit
import Foundation
import XCTest
@testable import AgentDeck

/// A stand-in for the market routes of the ledger Worker. It checks every device signature against the device
/// key with an independently built message (JSONSerialization, sorted keys), so a drift in the app's canonical
/// form fails here before it fails against the real server.
@MainActor
private final class FakeMarket {
    let serverKey = Curve25519.Signing.PrivateKey()
    var deviceKey: P256.Signing.PublicKey?
    var requests: [(method: String, path: String)] = []
    var packDir: URL
    var listing = ["id": "L1", "name": "Tester", "price": 300, "seller": ["tag": "abcd1234", "alias": "Owen"], "sales": 0,
                   "previews": ["portrait": "/ledger/v1/market/preview/L1/portrait.jpg", "sprite": "/ledger/v1/market/preview/L1/sprite.png"]] as [String: Any]
    var buyError: (Int, String)?
    var corruptPath: String?
    var uploaded: [String: Data] = [:]
    var submitted = false
    var times: [Int] = []

    init(packDir: URL) { self.packDir = packDir }

    var transport: LedgerSync.Transport { { [unowned self] req in try self.handle(req) } }

    private func ok(_ o: Any, _ status: Int = 200) throws -> (Data, Int) { (try JSONSerialization.data(withJSONObject: o), status) }

    private func envelope(_ body: [String: Any]) throws -> (Data, Int) {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), as: UTF8.self)
        return try ok(["body": text, "sig": try serverKey.signature(for: Data(text.utf8)).base64EncodedString()])
    }

    /// Verifies a device signature over {action, …fields, device, time}.
    private func check(_ action: String, _ fields: [String: Any], device: String, time: Int, sig: String) throws {
        var all = fields
        all["action"] = action; all["device"] = device; all["time"] = time
        let message = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys, .withoutEscapingSlashes])
        let s = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: sig)!)
        guard deviceKey!.isValidSignature(s, for: message) else { throw URLError(.userAuthenticationRequired) }
        times.append(time)
    }

    private func handle(_ req: URLRequest) throws -> (Data, Int) {
        let path = req.url!.path.replacingOccurrences(of: "/ledger/v1", with: "")
        requests.append((req.httpMethod ?? "GET", path))
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let manifest = try String(contentsOf: packDir.appendingPathComponent("manifest.json"), encoding: .utf8)
        let paths = ((try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any])["files"] as! [String: Any]).keys.sorted()
        switch (req.httpMethod ?? "GET", path) {
        case ("GET", "/pubkey"): return try ok(["alg": "Ed25519", "key": serverKey.publicKey.rawRepresentation.base64EncodedString()])
        case ("POST", "/register"):
            deviceKey = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: body["key"] as! String)!)
            return try ok(["device": "dev-1", "serverSeq": 1], 201)
        case ("GET", "/balance/dev-1"):
            return try envelope(["type": "balance", "device": "dev-1", "balance": 1000, "pendingClamp": 0, "pendingGenesis": 0,
                                 "pendingIncome": 0, "reservations": [], "deviceSeq": -1, "deviceHash": "", "revoked": false,
                                 "serverSeq": 1, "head": "h", "time": 1])
        case ("GET", "/market/listings"): return try ok(["listings": [listing]])
        case ("POST", "/market/buy"):
            try check("market.buy", ["listingId": body["listingId"]!, "price": body["price"]!], device: body["device"] as! String,
                      time: body["time"] as! Int, sig: body["sig"] as! String)
            if let (status, code) = buyError { return try ok(["error": code], status) }
            return try envelope(["type": "buy", "device": "dev-1", "listingId": "L1", "item": "market:L1", "amount": body["price"]!,
                                 "balance": 700, "seller": "dev-2", "sellerCredit": 270, "burned": 30, "serverSeq": 5, "head": "h", "time": 1])
        case ("POST", "/market/download/L1"):
            try check("market.download", ["listingId": "L1"], device: body["device"] as! String, time: body["time"] as! Int, sig: body["sig"] as! String)
            return try ok(["listingId": "L1", "token": "tok", "expiresAt": 9, "manifest": manifest,
                           "files": paths.map { ["path": $0, "sha256": "", "bytes": 0, "url": "/ledger/v1/market/files/tok/\($0)"] }])
        case ("POST", "/market/drafts"):
            let m = body["manifest"] as! String
            let sha = SHA256.hash(data: Data(m.utf8)).map { String(format: "%02x", $0) }.joined()
            try check("market.draft", ["alias": body["alias"]!, "description": body["description"]!, "manifestSha256": sha,
                                       "price": body["price"]!], device: body["device"] as! String, time: body["time"] as! Int, sig: body["sig"] as! String)
            return try ok(["listingId": "D1", "status": "draft", "serverSeq": 3, "missing": paths], 201)
        case ("POST", "/market/drafts/D1/submit"):
            try check("market.submit", ["listingId": "D1"], device: body["device"] as! String, time: body["time"] as! Int, sig: body["sig"] as! String)
            submitted = true
            return try ok(["listingId": "D1", "status": "pending", "reason": "", "serverSeq": 9])
        case ("POST", "/market/mine"):
            return try ok(["device": "dev-1", "balance": 10, "pendingIncome": 0,
                           "listings": [["id": "D1", "name": "Tester", "price": 300, "status": "rejected", "reason": "복제", "sales": 0, "earned": 0]]])
        default:
            if path.hasPrefix("/market/files/tok/") {
                let file = String(path.dropFirst("/market/files/tok/".count))
                var data = try Data(contentsOf: packDir.appendingPathComponent(file))
                if file == corruptPath { data.append(0) }
                return (data, 200)
            }
            if req.httpMethod == "PUT", path.hasPrefix("/market/drafts/D1/files/") {
                let file = String(path.dropFirst("/market/drafts/D1/files/".count))
                let data = req.httpBody ?? Data()
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try check("market.file", ["listingId": "D1", "path": file, "sha256": sha], device: req.value(forHTTPHeaderField: "x-ledger-device")!,
                          time: Int(req.value(forHTTPHeaderField: "x-ledger-time")!)!, sig: req.value(forHTTPHeaderField: "x-ledger-sig")!)
                uploaded[file] = data
                return try ok(["listingId": "D1", "path": file, "missing": []])
            }
            return (Data(), 404)
        }
    }
}

@MainActor
final class MarketServiceTests: XCTestCase {
    private var dir: URL!
    private var ledger: Ledger!
    private var server: FakeMarket!
    private var library: AssetLibrary!

    private var pack: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/ledger/test/asset-vectors/ok_minimal")
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("market-\(UUID().uuidString)")
        ledger = Ledger(url: dir.appendingPathComponent("ledger.jsonl"), signer: SoftwareSigner())
        try ledger.append(kind: .earn, source: "a", amount: 1000)
        server = FakeMarket(packDir: pack)
        library = AssetLibrary(root: dir.appendingPathComponent("assets"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func service() async throws -> MarketService {
        let sync = LedgerSync(ledger: ledger, stateURL: dir.appendingPathComponent("sync.json"), transport: server.transport, pinnedKey: "")
        try await sync.register(code: "C")
        return MarketService(sync: sync, ledger: ledger, library: library)
    }

    private func listing(_ m: MarketService) async throws -> MarketService.Listing { try await m.listings()[0] }

    func testBuyRecordsTheSpendAndInstallsTheCharacter() async throws {
        let m = try await service()
        let l = try await listing(m)
        XCTAssertEqual(l.seller.alias, "Owen")
        try await m.buy(l)
        XCTAssertTrue(m.owns("L1"))
        XCTAssertEqual(ledger.entries.last?.source, "market:L1")
        XCTAssertEqual(ledger.entries.last?.note, LedgerSync.marketNote)
        XCTAssertEqual(ledger.balance, 700)
        XCTAssertEqual(library.characters.map(\.id), ["market.L1"])
        // A market purchase is not a hire: the next hire still costs the first price.
        XCTAssertEqual(Recruit.nextPrice(roster: (0..<12).map { "hero\($0)" }, ledger: ledger), Recruit.price(recruited: 0))
    }

    func testRefusedPurchaseLeavesTheLedgerAlone() async throws {
        let m = try await service()
        server.buyError = (409, "insufficient")
        let l = try await listing(m)
        let before = ledger.entries.count
        do { try await m.buy(l); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? LedgerSync.Failure, .server(status: 409, code: "insufficient"))
        }
        XCTAssertEqual(ledger.entries.count, before)
        XCTAssertTrue(library.characters.isEmpty)
    }

    func testFailedDownloadKeepsThePurchaseAndCanBeRetried() async throws {
        let m = try await service()
        server.corruptPath = "sprite.png"
        let l = try await listing(m)
        do { try await m.buy(l); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? AssetLibrary.Failure, .invalid(["hash_mismatch"]))
        }
        XCTAssertTrue(m.owns("L1"))          // paid: the server has it
        XCTAssertTrue(library.characters.isEmpty)
        server.corruptPath = nil
        try await m.install("L1")            // "다시 받기"
        XCTAssertEqual(library.characters.count, 1)
        XCTAssertEqual(server.requests.filter { $0.path == "/market/buy" }.count, 1)
    }

    func testBuyingAgainAfterOwningOnlyReinstalls() async throws {
        let m = try await service()
        let l = try await listing(m)
        try await m.buy(l)
        try await m.buy(l)
        XCTAssertEqual(server.requests.filter { $0.path == "/market/buy" }.count, 1)
        XCTAssertEqual(ledger.entries.filter { $0.source == "market:L1" }.count, 1)
    }

    func testUploadSignsDraftFilesAndSubmitWithRisingTimes() async throws {
        let m = try await service()
        let id = try await m.upload(folder: pack, price: 300, alias: "Owen", description: "테스트 캐릭터")
        XCTAssertEqual(id, "D1")
        XCTAssertTrue(server.submitted)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: pack.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(Set(server.uploaded.keys), Set((manifest["files"] as! [String: Any]).keys))
        let draft = server.times.first!, submit = server.times.last!
        XCTAssertGreaterThan(submit, draft)  // the server refuses a submit in the same second as its draft
    }

    func testInvalidFolderNeverReachesTheServer() async throws {
        let m = try await service()
        let bad = pack.deletingLastPathComponent().appendingPathComponent("svg_sprite")
        do { try await m.upload(folder: bad, price: 300, alias: "", description: ""); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? MarketService.Failure, .invalidPack(["bad_format"]))
        }
        XCTAssertFalse(server.requests.contains { $0.path == "/market/drafts" })
    }

    func testMineShowsStatusAndReason() async throws {
        let m = try await service()
        let mine = try await m.mine()
        XCTAssertEqual(mine.listings.first?.status, "rejected")
        XCTAssertEqual(mine.listings.first?.reason, "복제")
    }
}
