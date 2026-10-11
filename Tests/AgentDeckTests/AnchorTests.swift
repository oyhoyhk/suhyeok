import CryptoKit
import Foundation
import XCTest
@testable import AgentDeck

/// Official OpenTimestamps examples (Fixtures/README.md) checked against recorded Esplora responses.
/// No live network: the verifier's fetcher serves Fixtures/esplora-recorded.json.
final class AnchorTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }

    private func recorded() throws -> [String: String] {
        let obj = try JSONSerialization.jsonObject(with: try fixture("esplora-recorded.json")) as! [String: Any]
        return obj["responses"] as! [String: String]
    }

    /// A verifier whose explorer answers only from the recording; unknown URLs fail like a network error.
    private func verifier(_ responses: [String: String]) -> AnchorVerifier {
        var v = AnchorVerifier()
        v.fetch = { url in
            guard let body = responses[url.absoluteString] else { throw URLError(.cannotConnectToHost) }
            return Data(body.utf8)
        }
        return v
    }

    private func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    func testHelloWorldParsesAndReplaysToBlockMerkleRoot() async throws {
        let proof = try OTSProof(try fixture("hello-world.txt.ots"))
        XCTAssertEqual(proof.digest, sha256(Data("Hello World!\n".utf8)))
        let btc = proof.attestations().filter { $0.attestation == .bitcoin(358391) }
        XCTAssertEqual(btc.count, 1)
        // Byte order: Esplora displays merkle_root reversed; the attested message is the header's raw bytes.
        let display = "8a1b66ecb7cbd07d8139a7e7d7f2c41aab1f5009b8364aaf61d03ad245e47e00"
        XCTAssertEqual(btc[0].message, Data(AnchorVerifier.hexBytes(display)!.reversed()))
        XCTAssertNotEqual(btc[0].message, AnchorVerifier.hexBytes(display))
        let root = await verifier(try recorded()).merkleRoot(height: 358391)
        XCTAssertEqual(root, btc[0].message)
    }

    func testOfficialConfirmedExamplesVerify() async throws {
        let v = verifier(try recorded())
        let hello = try fixture("hello-world.txt.ots")
        let r1 = await v.verify(proof: hello, expectedDigest: sha256(Data("Hello World!\n".utf8)))
        XCTAssertEqual(r1, .confirmed(height: 358391))
        let gdp = try fixture("gdp2q25-2nd.pdf.ots")
        let r2 = await v.verify(proof: gdp, expectedDigest: try OTSProof(gdp).digest)
        XCTAssertEqual(r2, .confirmed(height: 912095))
    }

    func testFallsBackToSecondExplorer() async throws {
        // blockstream unreachable; mempool.space serves the same Esplora API.
        var mempool: [String: String] = [:]
        for (url, body) in try recorded() {
            mempool[url.replacingOccurrences(of: "https://blockstream.info/api", with: "https://mempool.space/api")] = body
        }
        let gdp = try fixture("gdp2q25-2nd.pdf.ots")
        let r = await verifier(mempool).verify(proof: gdp, expectedDigest: try OTSProof(gdp).digest)
        XCTAssertEqual(r, .confirmed(height: 912095))
    }

    func testWrongExpectedDigestIsMismatch() async throws {
        let hello = try fixture("hello-world.txt.ots")
        let r = await verifier(try recorded()).verify(proof: hello, expectedDigest: sha256(Data("Hello World?\n".utf8)))
        XCTAssertEqual(r, .mismatch)
    }

    func testEveryFlippedByteFailsToConfirm() async throws {
        let hello = try fixture("hello-world.txt.ots")
        let digest = try OTSProof(hello).digest
        let v = verifier(try recorded())
        let original = try OTSProof(hello).attestations().map(\.message)
        var outcomes: [String: Int] = [:]
        for i in 0..<hello.count {
            var bad = hello
            bad[i] ^= 0x01
            let r = await v.verify(proof: bad, expectedDigest: digest)
            if case .confirmed = r {
                // Only a semantically identical proof may still confirm: byte 603 turns `append m` into
                // `prepend m` where m equals the message itself (Bitcoin's merkle tree duplicates an odd last
                // node), so the replay is unchanged. python-opentimestamps verifies that file too.
                XCTAssertEqual(try OTSProof(bad).attestations().map(\.message), original, "byte \(i)")
                outcomes["same proof", default: 0] += 1
            } else if case .invalid = r {
                outcomes["invalid", default: 0] += 1
            } else {
                outcomes["\(r)", default: 0] += 1
            }
        }
        XCTAssertEqual(outcomes["same proof"], 1)
        XCTAssertGreaterThan(outcomes["invalid"] ?? 0, 0)
        XCTAssertGreaterThan(outcomes["mismatch"] ?? 0, 0)

        // A flipped byte inside an op argument: parses, but replays to a different root.
        var bad = hello
        bad[bad.count - 40] ^= 0x01
        XCTAssertNoThrow(try OTSProof(bad))
        let r = await v.verify(proof: bad, expectedDigest: digest)
        XCTAssertEqual(r, .mismatch)
    }

    func testPendingOnlyProofsArePending() async throws {
        let v = verifier([:])
        for name in ["incomplete.txt.ots", "two-calendars.txt.ots", "known-and-unknown-notary.txt.ots"] {
            let data = try fixture(name)
            let r = await v.verify(proof: data, expectedDigest: try OTSProof(data).digest)
            XCTAssertEqual(r, .pending, name)
        }
        let p = try OTSProof(try fixture("incomplete.txt.ots"))
        let pending = p.attestations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].attestation, .pending("https://alice.btc.calendar.opentimestamps.org"))
        XCTAssertEqual(pending[0].message, AnchorVerifier.hexBytes("57cfa5c46716df9bd9e83595bce439c58108d8fcc1678f30d4c6731c3f1fa6c79ed712c66fb1ac8d4e4eb0e7"))
    }

    func testNoExplorerIsUnreachable() async throws {
        let hello = try fixture("hello-world.txt.ots")
        let r = await verifier([:]).verify(proof: hello, expectedDigest: try OTSProof(hello).digest)
        XCTAssertEqual(r, .unreachable)
    }

    func testMalformedProofs() {
        XCTAssertThrowsError(try OTSProof(Data())) { XCTAssertEqual($0 as? OTSProof.ParseError, .truncated) }
        XCTAssertThrowsError(try OTSProof(Data(repeating: 0, count: 80))) { XCTAssertEqual($0 as? OTSProof.ParseError, .badMagic) }
        let hello = try! fixture("hello-world.txt.ots")
        XCTAssertThrowsError(try OTSProof(hello + Data([0]))) { XCTAssertEqual($0 as? OTSProof.ParseError, .trailingBytes) }
        XCTAssertThrowsError(try OTSProof(hello.dropLast())) { XCTAssertEqual($0 as? OTSProof.ParseError, .truncated) }
    }

    func testRIPEMD160Vectors() {
        let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(RIPEMD160.hash(Data())), "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        XCTAssertEqual(hex(RIPEMD160.hash(Data("abc".utf8))), "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        XCTAssertEqual(hex(RIPEMD160.hash(Data("message digest".utf8))), "5d0689ef49d2fae572b881b123a85ffa21595f36")
        XCTAssertEqual(hex(RIPEMD160.hash(Data(String(repeating: "a", count: 1_000_000).utf8))), "52783243c1697bdbe16d37f97f68f08325dc1528")
    }
}
