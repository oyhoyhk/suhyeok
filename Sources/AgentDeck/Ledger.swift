import CryptoKit
import Foundation

/// One line of the crystal ledger. The hash covers every field but `hash` and `sig`, in the canonical form
/// below; the ledger Worker recomputes it byte for byte (shared vectors: server/ledger/test/vectors.json).
struct LedgerEntry: Codable, Equatable {
    enum Kind: String { case open, genesis, earn, spend, adjust, income }

    var seq: Int
    var time: Int        // unix seconds
    var kind: String
    var source: String   // transcript path or item id
    var amount: Int      // negative for spending
    var rule: Int        // earning-formula version
    var note: String
    var key: String?     // opening entry only: the device public key (base64 X9.63)
    var prev: String
    var hash: String
    var sig: String      // base64 raw ECDSA P-256 signature over `canonical`

    /// Keys sorted, no whitespace, integers only, strings escaped the way JSON.stringify escapes them.
    var canonical: String { Self.canonicalJSON(fields(withProof: false)) }
    var computedHash: String { SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// The stored line: the canonical fields plus hash and sig.
    var line: String { Self.canonicalJSON(fields(withProof: true)) }

    private func fields(withProof: Bool) -> [(String, Any)] {
        var f: [(String, Any)] = [("amount", amount), ("kind", kind), ("note", note), ("prev", prev),
                                  ("rule", rule), ("seq", seq), ("source", source), ("time", time)]
        if let key { f.append(("key", key)) }
        if withProof { f.append(("hash", hash)); f.append(("sig", sig)) }
        return f
    }

    /// `{"k":v,…}` with keys sorted, Int or String values only. Also used for the ledger server's signed requests.
    static func canonicalJSON(_ fields: [(String, Any)]) -> String {
        "{" + fields.sorted { $0.0 < $1.0 }.map { k, v in quote(k) + ":" + ((v as? Int).map(String.init) ?? quote(v as! String)) }
            .joined(separator: ",") + "}"
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

/// Append-only, hash-chained, signed crystal ledger (`ledger.jsonl`). The balance is the sum of its entries.
/// Any edit, reorder or re-hashed rewrite shows up as `.broken(seq:)` on load, and the ledger then stops writing.
final class Ledger {
    enum ReadOnlyReason: Equatable { case noKey, keyMismatch, unreadable }
    enum Status: Equatable {
        case ok
        case broken(seq: Int)          // first entry that fails the chain or its signature
        case readOnly(ReadOnlyReason)  // verified, but this device cannot sign it
    }
    enum Failure: Error, Equatable { case notWritable, insufficient }

    static let zeroHash = String(repeating: "0", count: 64)

    let url: URL
    let signer: LedgerSigning?
    // Read from the settle queue, the sync task and the UI at once: every access goes through `lock`.
    private var _entries: [LedgerEntry] = []
    private var _status: Status = .ok
    private var _balance = 0
    private var validLength: UInt64 = 0  // bytes up to the last complete line; a torn tail is cut before writing
    private let lock = NSLock()

    var entries: [LedgerEntry] { lock.withLock { _entries } }
    var status: Status { lock.withLock { _status } }
    var balance: Int { lock.withLock { _balance } }

    var isVerified: Bool { if case .broken = status { return false } else { return true } }

    init(url: URL, signer: LedgerSigning?) {
        self.url = url
        self.signer = signer
        load()
    }

    private func load() {
        _entries = []; _balance = 0; validLength = 0
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            // Missing means empty; present but unreadable must never be treated as empty (the next write would wipe it).
            if FileManager.default.fileExists(atPath: url.path) { _status = .readOnly(.unreadable); return }
            data = Data()
        }
        // A last line without its newline was cut off mid-write: ignore it rather than calling the ledger broken.
        let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        validLength = UInt64(end - data.startIndex)
        var publicKey: P256.Signing.PublicKey?
        for raw in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
            let seq = _entries.count
            guard let e = try? JSONDecoder().decode(LedgerEntry.self, from: Data(raw)),
                  e.seq == seq, e.prev == (_entries.last?.hash ?? Self.zeroHash), e.computedHash == e.hash
            else { _status = .broken(seq: seq); return }
            if seq == 0 {
                guard e.kind == LedgerEntry.Kind.open.rawValue, let k = e.key.flatMap({ Data(base64Encoded: $0) }),
                      let pk = try? P256.Signing.PublicKey(x963Representation: k)
                else { _status = .broken(seq: 0); return }
                publicKey = pk
            }
            guard let pk = publicKey, let sigData = Data(base64Encoded: e.sig),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
                  pk.isValidSignature(sig, for: Data(e.canonical.utf8))
            else { _status = .broken(seq: seq); return }
            _entries.append(e)
            _balance += e.amount
        }
        if signer == nil { _status = .readOnly(.noKey) }
        else if let pk = publicKey, pk.x963Representation != signer!.publicKey.x963Representation { _status = .readOnly(.keyMismatch) }
        else { _status = .ok }
    }

    /// Appends a signed entry (an opening entry with the public key goes first on an empty ledger).
    @discardableResult
    func append(kind: LedgerEntry.Kind, source: String, amount: Int, rule: Int = 1, note: String = "",
                time: Date = Date()) throws -> LedgerEntry {
        lock.lock(); defer { lock.unlock() }
        guard _status == .ok, let signer else { throw Failure.notWritable }
        if amount < 0, _balance + amount < 0 { throw Failure.insufficient }
        // Never earlier than the entry before: a clock stepping back must not break the server's time order.
        let t = max(Int(time.timeIntervalSince1970), _entries.last?.time ?? 0)
        if _entries.isEmpty {
            try write(kind: .open, source: "", amount: 0, rule: rule, note: "",
                      key: signer.publicKey.x963Representation.base64EncodedString(), time: t, signer: signer)
        }
        return try write(kind: kind, source: source, amount: amount, rule: rule, note: note, key: nil, time: t, signer: signer)
    }

    @discardableResult
    private func write(kind: LedgerEntry.Kind, source: String, amount: Int, rule: Int, note: String, key: String?,
                       time: Int, signer: LedgerSigning) throws -> LedgerEntry {
        var e = LedgerEntry(seq: _entries.count, time: time, kind: kind.rawValue, source: source, amount: amount,
                            rule: rule, note: note, key: key, prev: _entries.last?.hash ?? Self.zeroHash, hash: "", sig: "")
        e.hash = e.computedHash
        e.sig = try signer.sign(Data(e.canonical.utf8)).base64EncodedString()
        let line = Data((e.line + "\n").utf8)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: validLength)
        try h.seek(toOffset: validLength)
        try h.write(contentsOf: line)
        try h.synchronize()

        validLength += UInt64(line.count)
        _entries.append(e)
        _balance += e.amount
        return e
    }

    /// Sets a broken ledger aside (never deleted) and starts an empty one. Returns the archived file.
    func startOver() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let archived = url.deletingLastPathComponent().appendingPathComponent("ledger.broken-\(f.string(from: Date())).jsonl")
        try FileManager.default.moveItem(at: url, to: archived)
        _entries = []; _balance = 0; validLength = 0
        _status = signer == nil ? .readOnly(.noKey) : .ok
        return archived
    }
}
