import CryptoKit
import Foundation

/// An OpenTimestamps proof (`.ots` detached timestamp file), as published by the ledger Worker at
/// `/ledger/v1/anchors/<id>.ots`. Format per python-opentimestamps (core/serialize, op, notary, timestamp):
///   file      = magic, u8 version 1, file hash op (0x08 sha256), 32-byte digest, timestamp
///   timestamp = (0xff item)* item;  item = 0x00 attestation | op [varbytes arg] timestamp
///   attestation = 8-byte tag + varbytes payload (pending: varbytes uri, bitcoin: varuint height)
/// The server side of the same format is server/ledger/ots.js.
struct OTSProof {
    enum Op: Equatable {
        case sha1, ripemd160, sha256, keccak256, reverse, hexlify
        case append(Data), prepend(Data)
    }

    enum Attestation: Equatable {
        case pending(String)      // calendar URL
        case bitcoin(Int)         // block height; the message is that block's merkle root (internal byte order)
        case unknown(Data, Data)  // tag, payload
    }

    struct Node {
        var attestations: [Attestation] = []
        var branches: [(op: Op, node: Node)] = []
    }

    enum ParseError: Error, Equatable {
        case badMagic, unsupportedVersion, unsupportedFileHash, truncated, trailingBytes
        case badLength, unknownOp(UInt8), badURI, tooDeep
    }

    static let magic = Data([0x00]) + Data("OpenTimestamps".utf8) + Data([0x00, 0x00]) + Data("Proof".utf8)
        + Data([0x00, 0xbf, 0x89, 0xe2, 0xe8, 0x84, 0xe8, 0x92, 0x94])
    static let pendingTag = Data([0x83, 0xdf, 0xe3, 0x0d, 0x2e, 0xf9, 0x0c, 0x8e])
    static let bitcoinTag = Data([0x05, 0x88, 0x96, 0x0d, 0x73, 0xd7, 0x19, 0x01])
    // Limits from python-opentimestamps.
    private static let maxOpLength = 4096, maxPayload = 8192, maxURI = 1000, maxDepth = 256

    let digest: Data
    let root: Node

    init(_ data: Data) throws {
        var r = Reader(bytes: [UInt8](data))
        guard Data(try r.bytes(Self.magic.count)) == Self.magic else { throw ParseError.badMagic }
        guard try r.u8() == 1 else { throw ParseError.unsupportedVersion }
        guard try r.u8() == 0x08 else { throw ParseError.unsupportedFileHash }
        digest = Data(try r.bytes(32))
        root = try Self.readNode(&r, depth: Self.maxDepth)
        guard r.atEnd else { throw ParseError.trailingBytes }
    }

    /// Every attestation reachable from the file digest, with the message it commits to.
    /// Branches under ops that cannot be computed (keccak256) or fail (oversized results) are skipped.
    func attestations() -> [(attestation: Attestation, message: Data)] {
        var out: [(Attestation, Data)] = []
        func walk(_ node: Node, _ msg: Data) {
            for a in node.attestations { out.append((a, msg)) }
            for b in node.branches { if let next = Self.apply(b.op, msg) { walk(b.node, next) } }
        }
        walk(root, digest)
        return out
    }

    static func apply(_ op: Op, _ msg: Data) -> Data? {
        guard msg.count <= maxOpLength else { return nil }
        let out: Data
        switch op {
        case .sha256: out = Data(SHA256.hash(data: msg))
        case .sha1: out = Data(Insecure.SHA1.hash(data: msg))
        case .ripemd160: out = RIPEMD160.hash(msg)
        case .keccak256: return nil
        case .append(let a): out = msg + a
        case .prepend(let a): out = a + msg
        case .reverse: guard !msg.isEmpty else { return nil }; out = Data(msg.reversed())
        case .hexlify: guard !msg.isEmpty else { return nil }; out = Data(msg.map { String(format: "%02x", $0) }.joined().utf8)
        }
        return out.count <= maxOpLength ? out : nil
    }

    // MARK: parsing

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        var atEnd: Bool { i == bytes.count }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= bytes.count - i else { throw ParseError.truncated }
            defer { i += n }
            return Array(bytes[i..<i + n])
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func varuint() throws -> Int {
            var value = 0, shift = 0
            while true {
                let b = try u8()
                guard shift <= 49 else { throw ParseError.badLength }
                value |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
            }
        }
        mutating func varbytes(max: Int, min: Int = 0) throws -> [UInt8] {
            let n = try varuint()
            guard n >= min, n <= max else { throw ParseError.badLength }
            return try bytes(n)
        }
    }

    private static func readNode(_ r: inout Reader, depth: Int) throws -> Node {
        guard depth > 0 else { throw ParseError.tooDeep }
        var node = Node()
        func item(_ tag: UInt8) throws {
            if tag == 0x00 { node.attestations.append(try readAttestation(&r)); return }
            let op: Op
            switch tag {
            case 0x02: op = .sha1
            case 0x03: op = .ripemd160
            case 0x08: op = .sha256
            case 0x67: op = .keccak256
            case 0xf2: op = .reverse
            case 0xf3: op = .hexlify
            case 0xf0: op = .append(Data(try r.varbytes(max: maxOpLength, min: 1)))
            case 0xf1: op = .prepend(Data(try r.varbytes(max: maxOpLength, min: 1)))
            default: throw ParseError.unknownOp(tag)
            }
            node.branches.append((op, try readNode(&r, depth: depth - 1)))
        }
        var tag = try r.u8()
        while tag == 0xff {
            try item(try r.u8())
            tag = try r.u8()
        }
        try item(tag)
        return node
    }

    private static func readAttestation(_ r: inout Reader) throws -> Attestation {
        let tag = Data(try r.bytes(8))
        let payload = try r.varbytes(max: maxPayload)
        var p = Reader(bytes: payload)
        let a: Attestation
        if tag == pendingTag {
            let raw = try p.varbytes(max: maxURI)
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._/:".utf8)
            guard raw.allSatisfy(allowed.contains), let uri = String(bytes: raw, encoding: .utf8) else { throw ParseError.badURI }
            a = .pending(uri)
        } else if tag == bitcoinTag {
            a = .bitcoin(try p.varuint())
        } else {
            return .unknown(tag, Data(payload))
        }
        guard p.atEnd else { throw ParseError.trailingBytes }
        return a
    }
}

/// Outcome of checking a published anchor.
enum AnchorResult: Equatable {
    case confirmed(height: Int)  // a Bitcoin attestation matches that block's merkle root
    case pending                 // only calendar promises so far
    case mismatch                // wrong digest, or the attested root is not the block's root
    case unreachable             // no block explorer answered
    case invalid(String)         // not a parseable proof
}

/// Verifies an anchor proof: replays its ops from the anchored ledger hash to each Bitcoin attestation and
/// compares the result with the block header's merkle root from a public Esplora API (blockstream.info,
/// falling back to mempool.space). Trusting an explorer is the weak point; anyone can check the same
/// `.ots` file independently with `ots verify` against their own node (KTD9).
struct AnchorVerifier {
    /// GET a URL, returning the body of a 200 response; swapped for recorded responses in tests.
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let esplora = [URL(string: "https://blockstream.info/api")!, URL(string: "https://mempool.space/api")!]

    var explorers: [URL] = AnchorVerifier.esplora
    var fetch: Fetch = AnchorVerifier.urlSession

    static let urlSession: Fetch = { url in
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// `expectedDigest` is the server ledger hash at the anchored seq, as the app knows it.
    func verify(proof: Data, expectedDigest: Data) async -> AnchorResult {
        let p: OTSProof
        do { p = try OTSProof(proof) } catch { return .invalid("\(error)") }
        guard p.digest == expectedDigest else { return .mismatch }
        let all = p.attestations()
        let bitcoin = all.compactMap { a -> (height: Int, root: Data)? in
            if case .bitcoin(let h) = a.attestation { return (h, a.message) }
            return nil
        }.sorted { $0.height < $1.height }
        if bitcoin.isEmpty {
            return all.contains { if case .pending = $0.attestation { return true }; return false } ? .pending : .invalid("no attestations")
        }
        var sawMismatch = false
        for (height, root) in bitcoin {
            guard let header = await merkleRoot(height: height) else { continue }
            if root.count == 32 && root == header { return .confirmed(height: height) }
            sawMismatch = true
        }
        return sawMismatch ? .mismatch : .unreachable
    }

    /// The merkle root of the block at `height`, in internal (header) byte order. Esplora shows hashes in
    /// display order, which is the byte-reversed form, so the hex is reversed here.
    func merkleRoot(height: Int) async -> Data? {
        for base in explorers {
            guard let hashData = try? await fetch(base.appendingPathComponent("block-height/\(height)")),
                  let hash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.hexBytes(hash)?.count == 32,
                  let json = try? await fetch(base.appendingPathComponent("block/\(hash)")),
                  let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let rootHex = block["merkle_root"] as? String,
                  let display = Self.hexBytes(rootHex), display.count == 32
            else { continue }
            if let h = block["height"] as? Int, h != height { continue }
            return Data(display.reversed())
        }
        return nil
    }

    static func hexBytes(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }
}

/// RIPEMD-160, needed to replay older proofs (e.g. the official hello-world example). CryptoKit has none.
enum RIPEMD160 {
    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
    private static let rr: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
    private static let s: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
    private static let ss: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]
    private static let k: [UInt32] = [0x0000_0000, 0x5a82_7999, 0x6ed9_eba1, 0x8f1b_bcdc, 0xa953_fd4e]
    private static let kk: [UInt32] = [0x50a2_8be6, 0x5c4d_d124, 0x6d70_3ef3, 0x7a6d_76e9, 0x0000_0000]

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16: return x ^ y ^ z
        case 16..<32: return (x & y) | (~x & z)
        case 32..<48: return (x | ~y) ^ z
        case 48..<64: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }
    private static func rol(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    static func hash(_ data: Data) -> Data {
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        var h: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0]
        for block in stride(from: 0, to: msg.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = block + 4 * i
                x[i] = UInt32(msg[o]) | UInt32(msg[o + 1]) << 8 | UInt32(msg[o + 2]) << 16 | UInt32(msg[o + 3]) << 24
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            var (a2, b2, c2, d2, e2) = (h[0], h[1], h[2], h[3], h[4])
            for j in 0..<80 {
                var t = rol(a &+ f(j, b, c, d) &+ x[r[j]] &+ k[j / 16], s[j]) &+ e
                (a, e, d, c, b) = (e, d, rol(c, 10), b, t)
                t = rol(a2 &+ f(79 - j, b2, c2, d2) &+ x[rr[j]] &+ kk[j / 16], ss[j]) &+ e2
                (a2, e2, d2, c2, b2) = (e2, d2, rol(c2, 10), b2, t)
            }
            let t = h[1] &+ c &+ d2
            h[1] = h[2] &+ d &+ e2
            h[2] = h[3] &+ e &+ a2
            h[3] = h[4] &+ a &+ b2
            h[4] = h[0] &+ b &+ c2
            h[0] = t
        }
        var out = Data(capacity: 20)
        for w in h { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> (8 * UInt32(i)))) } }
        return out
    }
}
