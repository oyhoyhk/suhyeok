import Foundation
import XCTest
@testable import AgentDeck

final class AssetLibraryTests: XCTestCase {
    private var root: URL!
    private var vectors: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/ledger/test/asset-vectors")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A vector pack as the downloader would hand it over: manifest bytes plus every listed file.
    private func pack(_ name: String) throws -> (Data, [String: Data]) {
        let dir = vectors.appendingPathComponent(name)
        let manifest = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let listed = (try JSONSerialization.jsonObject(with: manifest) as! [String: Any])["files"] as! [String: Any]
        var files: [String: Data] = [:]
        for path in listed.keys where AssetPack.classify(path) != nil {
            files[path] = try? Data(contentsOf: dir.appendingPathComponent(path))
        }
        return (manifest, files)
    }

    func testInstalledCharacterJoinsTheLibraryAndResolvesArtNames() throws {
        let lib = AssetLibrary(root: root)
        let (m, files) = try pack("ok_minimal")
        try lib.install(listingId: "abc123", manifest: m, files: files)
        XCTAssertEqual(lib.characters.map(\.id), ["market.abc123"])
        XCTAssertEqual(lib.characters.first?.name, "Tester")
        XCTAssertEqual(lib.file(forArtName: "frames/market.abc123/walk_down_1")?.lastPathComponent, "walk_down_1.png")
        XCTAssertEqual(lib.file(forArtName: "sprites/market.abc123")?.lastPathComponent, "sprite.png")
        XCTAssertEqual(lib.file(forArtName: "portraits/market.abc123")?.lastPathComponent, "portrait.jpg")
        XCTAssertNil(lib.file(forArtName: "frames/market.abc123/../../x"))
        XCTAssertNil(lib.file(forArtName: "frames/knight/walk_down_1"))  // bundled names stay with the bundle
        XCTAssertNil(lib.file(forArtName: "sprites/market.unknown"))

        let again = AssetLibrary(root: root)  // survives a restart
        XCTAssertEqual(again.characters.map(\.id), ["market.abc123"])
    }

    func testInvalidPackIsRefusedAndLeavesNothingBehind() throws {
        let lib = AssetLibrary(root: root)
        let (m, files) = try pack("svg_sprite")
        XCTAssertThrowsError(try lib.install(listingId: "bad1", manifest: m, files: files)) {
            XCTAssertEqual($0 as? AssetLibrary.Failure, .invalid(["bad_format"]))
        }
        let undecodable = try pack("undecodable_frame")
        XCTAssertThrowsError(try lib.install(listingId: "bad2", manifest: undecodable.0, files: undecodable.1))
        XCTAssertTrue(lib.characters.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }, [])
    }

    func testListingIdCannotEscapeTheAssetsFolder() throws {
        let lib = AssetLibrary(root: root)
        let (m, files) = try pack("ok_minimal")
        for id in ["../evil", "a/b", "", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try lib.install(listingId: id, manifest: m, files: files), id)
        }
    }

    func testDeletedOrDamagedFolderDropsOut() throws {
        let lib = AssetLibrary(root: root)
        let (m, files) = try pack("ok_minimal")
        try lib.install(listingId: "one", manifest: m, files: files)
        try lib.install(listingId: "two", manifest: m, files: files)
        try FileManager.default.removeItem(at: lib.folder("one"))
        try Data("not a png".utf8).write(to: lib.folder("two").appendingPathComponent("sprite.png"))
        lib.reload()
        XCTAssertTrue(lib.characters.isEmpty)
    }

    func testReinstallReplacesThePack() throws {
        let lib = AssetLibrary(root: root)
        let (m, files) = try pack("ok_minimal")
        try lib.install(listingId: "same", manifest: m, files: files)
        try lib.install(listingId: "next", manifest: m, files: files)
        try lib.install(listingId: "same", manifest: m, files: files)
        XCTAssertEqual(lib.characters.map(\.id), ["market.same", "market.next"])  // roster indices stay put
    }

    func testMarketCharactersAreAlwaysOpenForAssignment() throws {
        let url = root.appendingPathComponent("ledger.jsonl")
        let ledger = Ledger(url: url, signer: SoftwareSigner())
        let roster = (0..<12).map { "hero\($0)" } + ["market.abc"]
        XCTAssertTrue(Recruit.unlocked(roster: roster, ledger: ledger).contains(12))
        XCTAssertEqual(Recruit.nextPrice(roster: roster, ledger: ledger), Recruit.price(recruited: 0))
    }
}
