import AppKit
import Foundation

/// Characters bought on the market, installed under Application Support/Suhyeok/assets/<listingId>/ in the pack
/// layout (docs/asset-pack-spec.md). Installed characters join the roster after the bundled ones with the id
/// `market.<listingId>`, and `Art.image` finds their portrait, sprite and frames here.
final class AssetLibrary {
    static let shared = AssetLibrary(root: CrystalBank.dir.appendingPathComponent("assets"))
    static let idPrefix = "market."

    struct Installed: Codable, Equatable {
        let listingId: String
        let name: String
        let installedAt: Date
    }

    enum Failure: Error, Equatable { case invalid([String]), io }

    let root: URL
    private let lock = NSLock()
    private var _installed: [Installed] = []

    init(root: URL) {
        self.root = root
        reload()
    }

    private var indexURL: URL { root.appendingPathComponent("installed.json") }

    /// Installed packs whose folder is still there and still passes the header checks (a deleted or damaged
    /// folder simply drops out; sessions using it fall back to a bundled character).
    var installed: [Installed] { lock.withLock { _installed } }

    var characters: [Character] { installed.map { Character(id: Self.idPrefix + $0.listingId, name: $0.name) } }

    func reload() {
        let listed = (try? Data(contentsOf: indexURL)).flatMap { try? Self.decoder.decode([Installed].self, from: $0) } ?? []
        let usable = listed.filter { AssetPack.validate(folder: folder($0.listingId), decode: false).isEmpty }
        lock.withLock { _installed = usable }
    }

    func folder(_ listingId: String) -> URL { root.appendingPathComponent(listingId, isDirectory: true) }

    func isInstalled(_ listingId: String) -> Bool { installed.contains { $0.listingId == listingId } }

    /// Validates (with a full pixel decode), writes into a temporary folder, then swaps it into place, so a failed
    /// or interrupted install never leaves a half-written pack where the app reads.
    func install(listingId: String, manifest: Data, files: [String: Data]) throws {
        guard listingId.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw Failure.invalid(["bad_path"]) }
        let issues = AssetPack.validate(manifest: manifest, files: files)
        guard issues.isEmpty else { throw Failure.invalid(AssetPack.codes(issues)) }
        let name = (try? JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["name"] as? String ?? listingId

        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(listingId)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("frames"), withIntermediateDirectories: true)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"))
            for (path, data) in files where AssetPack.classify(path) != nil {
                try data.write(to: staging.appendingPathComponent(path))
            }
            let target = folder(listingId)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: target) }
        } catch {
            try? fm.removeItem(at: staging)
            throw Failure.io
        }
        try lock.withLock {
            // A reinstall keeps its place: roster indices of the characters after it must not move.
            var next = _installed
            let entry = Installed(listingId: listingId, name: name.trimmingCharacters(in: .whitespacesAndNewlines), installedAt: Date())
            if let i = next.firstIndex(where: { $0.listingId == listingId }) { next[i] = entry } else { next.append(entry) }
            do { try Self.encoder.encode(next).write(to: indexURL, options: .atomic) } catch { throw Failure.io }
            _installed = next
        }
    }

    /// The file behind an `Art.image` name such as "frames/market.<id>/walk_down_1", "sprites/market.<id>" or
    /// "portraits/market.<id>"; nil for bundled names or unknown packs.
    func file(forArtName name: String) -> URL? {
        let parts = name.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[1].hasPrefix(Self.idPrefix) else { return nil }
        let id = String(parts[1].dropFirst(Self.idPrefix.count))
        guard isInstalled(id) else { return nil }
        let dir = folder(id)
        switch (parts[0], parts.count) {
        case ("frames", 3):
            let path = "frames/\(parts[2]).png"
            return AssetPack.classify(path) != nil ? dir.appendingPathComponent(path) : nil
        case ("sprites", 2):
            return dir.appendingPathComponent("sprite.png")
        case ("portraits", 2):
            return ["portrait.jpg", "portrait.png"].map(dir.appendingPathComponent).first { FileManager.default.fileExists(atPath: $0.path) }
        default:
            return nil
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
