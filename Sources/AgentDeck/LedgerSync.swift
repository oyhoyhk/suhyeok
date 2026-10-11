import CryptoKit
import Foundation

/// Talks to the pickuma ledger server (suhyeok.pickuma.com/ledger/v1): registers this Mac's ledger key,
/// sends new ledger entries, and books the server's cuts back into the local ledger so both balances agree.
/// Every server answer is an Ed25519-signed `{body, sig}`; nothing is trusted without the pinned server key.
/// Main-actor bound: its state is read by the UI while syncs run (network waits do not block the main thread).
@MainActor
final class LedgerSync {
    /// The production ledger server's key (base64 raw Ed25519, deployed 2026-10-11). A server answering with any
    /// other key is refused, so a look-alike server cannot hand out receipts.
    nonisolated static let pinnedServerKey = "QoECpfdKjZ5Dw6XUVfSHoxuBvmoGjvgcQ1C82GwYG2g="
    nonisolated static let defaultBase = "https://suhyeok.pickuma.com/ledger/v1"
    nonisolated static let clampSource = "#server-clamp"
    nonisolated static let batchSize = 200  // matches the server's MAX_BATCH

    struct State: Codable, Equatable {
        var base = LedgerSync.defaultBase
        var device: String?
        var serverKey: String?
        var ackSeq: Int?      // last ledger entry the server confirmed
        var ackHash: String?
        /// Server ledger head hashes seen in signed receipts (server seq → hash), to cross-check public anchors.
        var heads: [String: String] = [:]
    }

    struct Receipt: Decodable, Equatable {
        let type: String
        let device: String
        let deviceSeq: Int
        let deviceHash: String
        let accepted: Int
        let clamped: Int
        let pending: Int      // genesis awaiting the admin
        let balance: Int
        let pendingClamp: Int
        let serverSeq: Int
        let head: String
    }

    /// One public anchor of the server ledger head (GET /anchors).
    struct AnchorInfo: Decodable, Identifiable, Equatable {
        let id: Int
        let seq: Int
        let hash: String
        let status: String   // pending | confirmed (the server's view; the app verifies for itself)
        let height: Int?
        let submittedAt: Int
    }

    enum Failure: Error, Equatable {
        case notRegistered, noKey, keyChanged, badSignature, unexpected
        case server(status: Int, code: String)
    }

    /// One HTTP exchange; swapped for a fake in tests.
    typealias Transport = (URLRequest) async throws -> (Data, Int)

    let ledger: Ledger
    private let stateURL: URL
    private let transport: Transport
    private let pinnedKey: String  // empty: trust the key seen at first registration (tests, other servers)
    private(set) var state: State

    init(ledger: Ledger, stateURL: URL, transport: @escaping Transport = LedgerSync.urlSession,
         pinnedKey: String = LedgerSync.pinnedServerKey) {
        self.ledger = ledger
        self.stateURL = stateURL
        self.transport = transport
        self.pinnedKey = pinnedKey
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
    }

    var isRegistered: Bool { state.device != nil }

    nonisolated static let urlSession: Transport = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: registration

    /// Registers this Mac with a one-time code from the admin. Pins the server key on first use.
    func register(code: String) async throws {
        guard let signer = ledger.signer else { throw Failure.noKey }
        struct Pub: Decodable { let key: String }
        let pub: Pub = try decode(try await call("GET", "/pubkey"))
        let pinned = pinnedKey.isEmpty ? state.serverKey : pinnedKey
        if let pinned, pinned != pub.key { throw Failure.keyChanged }

        struct Registered: Decodable { let device: String }
        let body = ["code": code, "key": signer.publicKey.x963Representation.base64EncodedString()]
        let reg: Registered = try decode(try await call("POST", "/register", json: body))
        state = State(base: state.base, device: reg.device, serverKey: pub.key)
        save()
    }

    // MARK: settlement

    /// Sends every entry the server has not confirmed (in batches). After each receipt, books an `adjust` entry for
    /// whatever the server cut that the ledger has not answered yet. Returns the last receipt, or nil when there was
    /// nothing to send.
    @discardableResult
    func sync() async throws -> Receipt? {
        guard let device = state.device else { throw Failure.notRegistered }
        var last: Receipt?
        // Only what existed when this sync began: the adjust entries it writes go out next time.
        let end = ledger.entries.last?.seq ?? -1
        while true {
            let unsent = ledger.entries.filter { $0.seq > (state.ackSeq ?? -1) && $0.seq <= end }
            guard !unsent.isEmpty else { return last }
            let batch = Array(unsent.prefix(Self.batchSize))
            let payload = try JSONEncoder().encode(SyncBody(device: device, entries: batch))
            let r: Receipt = try verified(try await call("POST", "/sync", body: payload))
            guard r.type == "sync", r.device == device, r.deviceSeq == batch.last!.seq, r.deviceHash == batch.last!.hash
            else { throw Failure.unexpected }
            state.ackSeq = r.deviceSeq
            state.ackHash = r.deviceHash
            state.heads[String(r.serverSeq)] = r.head
            if state.heads.count > 200, let oldest = state.heads.keys.compactMap(Int.init).min() {
                state.heads[String(oldest)] = nil
            }
            save()
            // The server's running total of cuts not yet answered, minus answers already written but not yet sent.
            // Working from the total (not this receipt's cut) heals an adjust lost to a crash or a failed write.
            let unsentAnswers = ledger.entries.filter { $0.seq > r.deviceSeq && $0.kind == LedgerEntry.Kind.adjust.rawValue
                && $0.source == Self.clampSource }.reduce(0) { $0 - $1.amount }
            let owed = r.pendingClamp - unsentAnswers
            if owed > 0 {
                _ = try? ledger.append(kind: .adjust, source: Self.clampSource, amount: -owed, rule: Hunt.rule, note: "서버 상한 초과분")
            }
            last = r
        }
    }

    private struct SyncBody: Encodable { let device: String; let entries: [LedgerEntry] }

    // MARK: spending

    /// Asks the server to set aside crystals for an item before the local `spend` entry is written.
    func confirmSpend(item: String, amount: Int, time: Date = Date()) async throws {
        guard let device = state.device else { throw Failure.notRegistered }
        guard let signer = ledger.signer else { throw Failure.noKey }
        let t = Int(time.timeIntervalSince1970)
        let message = LedgerEntry.canonicalJSON([("action", "spend"), ("amount", amount), ("device", device),
                                                 ("item", item), ("time", t)])
        let sig = try signer.sign(Data(message.utf8)).base64EncodedString()
        let body: [String: Any] = ["device": device, "item": item, "amount": amount, "time": t, "sig": sig]
        struct Spent: Decodable { let type: String; let item: String; let amount: Int }
        let s: Spent = try verified(try await call("POST", "/spend", body: JSONSerialization.data(withJSONObject: body)))
        guard s.type == "spend", s.item == item, s.amount == amount else { throw Failure.unexpected }
    }

    /// The server's signed view of this device: balance and spend reservations still open.
    struct BalanceInfo: Decodable {
        struct Reservation: Decodable { let item: String; let amount: Int }
        let type: String
        let device: String
        let balance: Int
        let pendingGenesis: Int
        let reservations: [Reservation]
    }

    func balance() async throws -> BalanceInfo {
        guard let device = state.device else { throw Failure.notRegistered }
        let b: BalanceInfo = try verified(try await call("GET", "/balance/\(device)"))
        guard b.type == "balance", b.device == device else { throw Failure.unexpected }
        return b
    }

    /// Writes the local spend for any reservation the server holds but the ledger never recorded (the app died
    /// between the server's confirmation and the local write). Returns how many were booked.
    @discardableResult
    func bookOpenReservations(note: String) async throws -> Int {
        var booked = 0
        for r in try await balance().reservations {
            let recorded = ledger.entries.contains { $0.kind == LedgerEntry.Kind.spend.rawValue && $0.source == r.item }
            guard !recorded else { continue }
            if (try? ledger.append(kind: .spend, source: r.item, amount: -r.amount, rule: Hunt.rule, note: note)) != nil { booked += 1 }
        }
        return booked
    }

    /// Drops the registration (the ledger was started over with a new key): the next one needs a new code.
    func forget() {
        state = State(base: state.base, serverKey: state.serverKey)
        save()
    }

    // MARK: anchors

    func anchors() async throws -> [AnchorInfo] {
        struct List: Decodable { let anchors: [AnchorInfo] }
        let list: List = try decode(try await call("GET", "/anchors"))
        return list.anchors
    }

    func proof(_ anchor: AnchorInfo) async throws -> Data { try await call("GET", "/anchors/\(anchor.id).ots") }

    /// The head this device saw in a signed receipt for the anchor's seq, when it has one.
    func knownHead(seq: Int) -> String? { state.heads[String(seq)] }

    // MARK: plumbing

    private func call(_ method: String, _ path: String, json: [String: String]) async throws -> Data {
        try await call(method, path, body: JSONEncoder().encode(json))
    }

    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: state.base + path) else { throw Failure.unexpected }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, status) = try await transport(req)
        guard (200..<300).contains(status) else {
            struct E: Decodable { let error: String }
            throw Failure.server(status: status, code: (try? JSONDecoder().decode(E.self, from: data))?.error ?? "")
        }
        return data
    }

    /// Checks the server signature over `body` exactly as received, then decodes it.
    private struct Signed: Decodable { let body: String; let sig: String }

    private func verified<T: Decodable>(_ data: Data) throws -> T {
        let signed: Signed = try decode(data)
        guard let k = state.serverKey.flatMap({ Data(base64Encoded: $0) }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: k),
              let sig = Data(base64Encoded: signed.sig),
              key.isValidSignature(sig, for: Data(signed.body.utf8))
        else { throw Failure.badSignature }
        return try decode(Data(signed.body.utf8))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Failure.unexpected }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}
