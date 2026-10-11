import Foundation
import XCTest
@testable import AgentDeck

/// Runs the shared character-pack vectors (server/ledger/test/asset-vectors) through the app's validator.
final class AssetPackTests: XCTestCase {
    private var vectors: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/ledger/test/asset-vectors")
    }

    private func cases() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: vectors, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("expected.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func expected(_ dir: URL, _ key: String) throws -> [String] {
        let e = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expected.json"))) as! [String: [String]]
        return e[key]!
    }

    func testSharedVectorsWithDecoding() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 19)
        for dir in all {
            XCTAssertEqual(AssetPack.codes(AssetPack.validate(folder: dir)), try expected(dir, "swift"), dir.lastPathComponent)
        }
    }

    func testSharedVectorsHeaderOnlyMatchTheServer() throws {
        for dir in try cases() {
            XCTAssertEqual(AssetPack.codes(AssetPack.validate(folder: dir, decode: false)), try expected(dir, "js"), dir.lastPathComponent)
        }
    }

    func testPathsOutsideTheLayoutAreRefused() {
        for p in ["../x.png", "frames/../sprite.png", "frames/sub/walk_down_0.png", ".hidden.png", "sprite.svg",
                  "frames/walk_down_01.png", "frames/dance_0.png", "portrait.jpeg", "/sprite.png"] {
            XCTAssertNil(AssetPack.classify(p), p)
        }
        XCTAssertEqual(AssetPack.classify("frames/walk_down_5.png")?.role, .frame(motion: "walk_down", index: 5))
    }
}
