import CryptoKit
import Foundation

/// The character market (server/ledger/market.js): browse approved characters, buy with crystals, download and
/// install them, and sell your own packs. Every device request is signed with the ledger key.
@MainActor
final class MarketService {
    struct Seller: Decodable, Equatable { let tag: String; let alias: String? }
    struct Previews: Decodable, Equatable { let portrait: String?; let sprite: String? }
    struct Listing: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let description: String?
        let price: Int
        let seller: Seller
        let sales: Int?
        let previews: Previews?
    }
    struct MyListing: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let price: Int
        let status: String   // draft | pending | approved | rejected | delisted | withdrawn
        let reason: String?
        let sales: Int?
        let earned: Int?
    }
    struct Purchase: Decodable, Identifiable, Equatable { let id: String; let name: String; let price: Int; let status: String }
    struct Mine: Decodable { let balance: Int; let pendingIncome: Int; let listings: [MyListing]; let purchases: [Purchase]? }

    enum Failure: Error, Equatable {
        case invalidPack([String])
        case unexpected
    }

    let sync: LedgerSync
    let ledger: Ledger
    let library: AssetLibrary
    private var lastTime = 0

    init(sync: LedgerSync, ledger: Ledger, library: AssetLibrary) {
        self.sync = sync
        self.ledger = ledger
        self.library = library
    }

    /// Request times must rise strictly per device (the server's replay guard): never reuse a second.
    private func nextTime() -> Int {
        lastTime = max(Int(Date().timeIntervalSince1970), lastTime + 1)
        return lastTime
    }

    private static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: browsing

    func listings() async throws -> [Listing] {
        struct List: Decodable { let listings: [Listing] }
        let list: List = try sync.decode(try await sync.call("GET", "/market/listings"))
        return list.listings
    }

    func image(_ hostPath: String) async -> Data? { try? await sync.fetch(hostPath: hostPath) }

    /// Bought, as the local ledger records it (the server holds the authoritative owners list).
    func owns(_ listingId: String) -> Bool {
        ledger.entries.contains { $0.kind == LedgerEntry.Kind.spend.rawValue && $0.source == LedgerSync.marketItemPrefix + listingId }
    }

    // MARK: buying

    /// Server first (it deducts and pays the seller), then the local spend, then download and install. A failed
    /// download leaves the purchase in place; `install` can simply be retried.
    func buy(_ listing: Listing) async throws {
        try await sync.bookOpenReservations(note: Recruit.note)  // a purchase the app died in the middle of
        if !owns(listing.id) {
            let t = nextTime()
            let s = try sync.signed("market.buy", [("listingId", listing.id), ("price", listing.price)], time: t)
            struct Bought: Decodable { let type: String; let listingId: String; let amount: Int }
            let body = try Self.json(["device": s.device, "listingId": listing.id, "price": listing.price, "time": t, "sig": s.sig])
            let b: Bought = try sync.verified(try await sync.call("POST", "/market/buy", body: body))
            guard b.type == "buy", b.listingId == listing.id, b.amount == listing.price else { throw Failure.unexpected }
            if !owns(listing.id) {
                try ledger.append(kind: .spend, source: LedgerSync.marketItemPrefix + listing.id, amount: -listing.price,
                                  rule: Hunt.rule, note: LedgerSync.marketNote)
            }
        }
        try await install(listing.id)
    }

    func install(_ listingId: String) async throws {
        let t = nextTime()
        let s = try sync.signed("market.download", [("listingId", listingId)], time: t)
        struct File: Decodable { let path: String; let url: String }
        struct Download: Decodable { let manifest: String; let files: [File] }
        let body = try Self.json(["device": s.device, "time": t, "sig": s.sig])
        let d: Download = try sync.decode(try await sync.call("POST", "/market/download/\(listingId)", body: body))
        var files: [String: Data] = [:]
        for f in d.files where AssetPack.classify(f.path) != nil {
            files[f.path] = try await sync.fetch(hostPath: f.url)
        }
        try library.install(listingId: listingId, manifest: Data(d.manifest.utf8), files: files)
    }

    // MARK: selling

    /// Checks the folder like the server will, then: draft → every file → submit (for review).
    @discardableResult
    func upload(folder: URL, price: Int, alias: String, description: String,
                progress: (Int, Int) -> Void = { _, _ in }) async throws -> String {
        let issues = AssetPack.validate(folder: folder)
        guard issues.isEmpty else { throw Failure.invalidPack(AssetPack.codes(issues)) }
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard let manifest = String(data: manifestData, encoding: .utf8) else { throw Failure.invalidPack(["bad_manifest"]) }

        let t = nextTime()
        let s = try sync.signed("market.draft", [("alias", alias), ("description", description),
                                                 ("manifestSha256", Self.sha(manifestData)), ("price", price)], time: t)
        struct Draft: Decodable { let listingId: String; let missing: [String] }
        let body = try Self.json(["device": s.device, "manifest": manifest, "price": price, "alias": alias,
                                  "description": description, "time": t, "sig": s.sig])
        let draft: Draft = try sync.decode(try await sync.call("POST", "/market/drafts", body: body))
        do {
            try await finish(draft: draft.listingId, missing: draft.missing, folder: folder, progress: progress)
        } catch {
            // An abandoned draft counts against the seller's open listings: give it back.
            try? await withdraw(draft.listingId)
            throw error
        }
        return draft.listingId
    }

    private func finish(draft listingId: String, missing: [String], folder: URL, progress: (Int, Int) -> Void) async throws {
        for (i, path) in missing.enumerated() where AssetPack.classify(path) != nil {
            progress(i, missing.count)
            let data = try Data(contentsOf: folder.appendingPathComponent(path))
            let ft = Int(Date().timeIntervalSince1970)
            let fs = try sync.signed("market.file", [("listingId", listingId), ("path", path), ("sha256", Self.sha(data))], time: ft)
            _ = try await sync.call("PUT", "/market/drafts/\(listingId)/files/\(path)", body: data,
                                    contentType: "application/octet-stream",
                                    headers: ["x-ledger-device": fs.device, "x-ledger-time": String(ft), "x-ledger-sig": fs.sig])
        }
        progress(missing.count, missing.count)

        let st = nextTime()
        let ss = try sync.signed("market.submit", [("listingId", listingId)], time: st)
        _ = try await sync.call("POST", "/market/drafts/\(listingId)/submit",
                                body: try Self.json(["device": ss.device, "time": st, "sig": ss.sig]))
    }

    /// Takes back a draft that was never submitted.
    func withdraw(_ listingId: String) async throws {
        let t = nextTime()
        let s = try sync.signed("market.withdraw", [("listingId", listingId)], time: t)
        _ = try await sync.call("POST", "/market/drafts/\(listingId)/withdraw",
                                body: try Self.json(["device": s.device, "time": t, "sig": s.sig]))
    }

    func mine() async throws -> Mine {
        let t = Int(Date().timeIntervalSince1970)
        let s = try sync.signed("market.mine", [], time: t)
        return try sync.decode(try await sync.call("POST", "/market/mine", body: try Self.json(["device": s.device, "time": t, "sig": s.sig])))
    }
}
