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

    /// ok_minimal's manifest with its format and profile replaced; `profile: nil` removes it.
    private func manifest(format: Any, profile: Any?) throws -> Data {
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: vectors.appendingPathComponent("ok_minimal/manifest.json"))) as! [String: Any]
        m["format"] = format
        m["profile"] = profile
        return try JSONSerialization.data(withJSONObject: m)
    }

    private func profileIssues(format: Any = 2, _ profile: Any?) throws -> [AssetPack.Issue] {
        AssetPack.validateManifest(try manifest(format: format, profile: profile)).1.filter { $0.code == "bad_profile" || $0.code == "bad_format_version" }
    }

    func testProfileRules() throws {
        let good: [String: Any] = ["ko": "모찌", "role": "고양이 마법사", "tone": "문장 끝을 '~냥'으로 맺음", "visual": "white cat"]
        XCTAssertEqual(try profileIssues(good), [])
        XCTAssertEqual(AssetPack.validateManifest(try manifest(format: 2, profile: good)).0?.profile?.ko, "모찌")
        XCTAssertEqual(try profileIssues(nil).map(\.path), ["profile"])                // format 2 needs one
        XCTAssertEqual(try profileIssues(format: 1, nil), [])                          // format 1 packs stay valid
        XCTAssertEqual(try profileIssues(format: 3, good).map(\.code), ["bad_format_version"])
        var bad = good
        bad["tone"] = "짧음"                       // under 10
        bad["role"] = "줄\n바꿈"                  // control character
        bad["extra"] = "x"
        XCTAssertEqual(Set(try profileIssues(bad).map(\.path)), ["profile.tone", "profile.role", "profile.extra"])
        bad = good
        bad["ko"] = String(repeating: "가", count: 21)
        XCTAssertEqual(try profileIssues(bad).map(\.path), ["profile.ko"])
    }

    func testPathsOutsideTheLayoutAreRefused() {
        for p in ["../x.png", "frames/../sprite.png", "frames/sub/walk_down_0.png", ".hidden.png", "sprite.svg",
                  "frames/walk_down_01.png", "frames/dance_0.png", "portrait.jpeg", "/sprite.png"] {
            XCTAssertNil(AssetPack.classify(p), p)
        }
        XCTAssertEqual(AssetPack.classify("frames/walk_down_5.png")?.role, .frame(motion: "walk_down", index: 5))
    }
}
