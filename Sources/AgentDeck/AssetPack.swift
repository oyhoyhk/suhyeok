import CryptoKit
import Foundation
import ImageIO

/// Character pack validation (docs/asset-pack-spec.md): the same rules as server/ledger/assets.js, plus a real
/// decode of every image before the app installs a pack. server/ledger/test/asset-vectors keeps both in step.
enum AssetPack {
    struct Issue: Equatable {
        let code: String
        let path: String
    }

    static let format = 1
    static let kinds = ["character"]
    static let maxManifest = 16 * 1024
    static let maxFile = 1024 * 1024
    static let maxPack = 4 * 1024 * 1024
    static let nameMax = 40
    static let motions: [String: Int] = ["walk_down": 6, "walk_left": 6, "walk_up": 6, "attack": 6,
                                         "hammer": 3, "read": 3, "type": 3, "smith": 6, "study": 6, "write": 6]
    static let required = ["walk_down", "walk_left", "walk_up", "attack"]
    static let frameMax = 256
    static let portraitW = 128...1024, portraitH = 128...1365

    enum Role: Equatable { case portrait, sprite, frame(motion: String, index: Int) }

    struct FileEntry: Decodable { let sha256: String; let bytes: Int }
    struct Manifest: Decodable {
        let format: Int?
        let kind: String?
        let name: String?
        let frames: [String: Int]
        let files: [String: FileEntry]
    }

    private static let pathPattern = try! NSRegularExpression(
        pattern: #"^(?:(portrait)\.(jpg|png)|(sprite)\.png|frames/([a-z_]+)_(\d{1,2})\.png)$"#)

    /// What a pack path is, and whether it holds a PNG; nil when the path is not allowed.
    static func classify(_ path: String) -> (role: Role, png: Bool)? {
        let ns = path as NSString
        guard let m = pathPattern.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        if group(1) != nil { return (.portrait, group(2) == "png") }
        if group(3) != nil { return (.sprite, true) }
        guard let motion = group(4), motions[motion] != nil, let digits = group(5),
              !(digits.count > 1 && digits.hasPrefix("0")), let index = Int(digits) else { return nil }
        return (.frame(motion: motion, index: index), true)
    }

    // MARK: manifest

    static func validateManifest(_ data: Data) -> (Manifest?, [Issue]) {
        if data.count > maxManifest { return (nil, [Issue(code: "too_large", path: "manifest.json")]) }
        // Fields are checked by hand below; decoding only needs the two maps to be the right shape.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["files"] is [String: Any], raw["frames"] is [String: Any] else { return (nil, [Issue(code: "bad_manifest", path: "")]) }
        var issues: [Issue] = []
        if (raw["format"] as? Int) != format || isBool(raw["format"]) { issues.append(Issue(code: "bad_format_version", path: "")) }
        if !kinds.contains(raw["kind"] as? String ?? "") { issues.append(Issue(code: "bad_kind", path: "")) }
        let name = (raw["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.unicodeScalars.count > nameMax || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            issues.append(Issue(code: "bad_name", path: ""))
        }

        var files: [String: FileEntry] = [:]
        var total = 0, portraits: [String] = [], sprite = false
        var frames: [String: [Int]] = [:]
        for (path, value) in raw["files"] as! [String: Any] {
            guard let f = value as? [String: Any], let sha = f["sha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let bytes = f["bytes"] as? Int, !isBool(f["bytes"]), bytes > 0 else {
                issues.append(Issue(code: "bad_manifest", path: path)); continue
            }
            guard let c = classify(path) else { issues.append(Issue(code: "bad_path", path: path)); continue }
            files[path] = FileEntry(sha256: sha, bytes: bytes)
            total += bytes
            if bytes > maxFile { issues.append(Issue(code: "too_large", path: path)) }
            switch c.role {
            case .portrait: portraits.append(path)
            case .sprite: sprite = true
            case .frame(let motion, let index): frames[motion, default: []].append(index)
            }
        }
        if total > maxPack { issues.append(Issue(code: "too_large", path: "")) }
        if portraits.isEmpty { issues.append(Issue(code: "missing_file", path: "portrait")) }
        if portraits.count > 1 { issues.append(Issue(code: "bad_path", path: portraits.joined(separator: ","))) }
        if !sprite { issues.append(Issue(code: "missing_file", path: "sprite.png")) }

        let declared = raw["frames"] as! [String: Any]
        for motion in Set(frames.keys).union(declared.keys).union(required) {
            let have = (frames[motion] ?? []).sorted()
            let says = declared[motion] as? Int
            if motions[motion] != have.count || have != Array(0..<have.count) || says != have.count || isBool(declared[motion]) {
                issues.append(Issue(code: "frame_count", path: motion))
            }
        }
        let m = Manifest(format: raw["format"] as? Int, kind: raw["kind"] as? String, name: name,
                         frames: declared.compactMapValues { $0 as? Int }, files: files)
        return (m, issues)
    }

    /// JSON `true` arrives as an NSNumber that also casts to Int (and 1 casts to Bool), so ask CoreFoundation.
    private static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    // MARK: file contents

    struct ImageInfo { let width: Int; let height: Int; let colorType: Int; let trns: Bool }

    private static let pngDepths: [Int: Set<Int>] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]

    /// Walks the PNG chunks (lengths, CRCs, IHDR first, IEND last); nil when it is not a sound PNG.
    static func parsePNG(_ d: [UInt8]) -> ImageInfo? {
        guard d.count >= 45, d.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func u32(_ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }
        var i = 8, info: ImageInfo?, trns = false, idat = false, chunks = 0
        while i + 12 <= d.count {
            let len = u32(i), end = i + 8 + len
            chunks += 1
            guard len <= 0x7fff_ffff, end + 4 <= d.count, chunks <= 4096 else { return nil }
            guard UInt32(u32(end)) == crc32(d[(i + 4)..<end]) else { return nil }
            let type = String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self)
            if info == nil {
                guard type == "IHDR", len == 13 else { return nil }
                let w = u32(i + 8), h = u32(i + 12), depth = Int(d[i + 16]), color = Int(d[i + 17])
                guard w > 0, h > 0, pngDepths[color]?.contains(depth) == true else { return nil }
                info = ImageInfo(width: w, height: h, colorType: color, trns: false)
            } else if type == "tRNS" {
                guard !idat else { return nil }
                trns = true
            } else if type == "IDAT" {
                idat = true
            } else if type == "IEND" {
                guard idat, end + 4 == d.count, let info else { return nil }
                return ImageInfo(width: info.width, height: info.height, colorType: info.colorType, trns: trns)
            }
            i = end + 4
        }
        return nil
    }

    /// The frame size of a baseline or progressive JPEG; nil when it is not a sound JPEG.
    static func parseJPEG(_ d: [UInt8]) -> ImageInfo? {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8, d[d.count - 2] == 0xFF, d[d.count - 1] == 0xD9 else { return nil }
        var i = 2, size: (Int, Int)?
        while i + 4 <= d.count {
            guard d[i] == 0xFF else { return nil }
            var marker = d[i + 1]
            while marker == 0xFF && i + 2 < d.count { i += 1; marker = d[i + 1] }
            if marker == 0xD9 { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard len >= 2, i + 2 + len <= d.count else { return nil }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard len >= 8 else { return nil }
                size = (Int(d[i + 7]) << 8 | Int(d[i + 8]), Int(d[i + 5]) << 8 | Int(d[i + 6]))
            }
            if marker == 0xDA { break }
            i += 2 + len
        }
        guard let (w, h) = size, w > 0, h > 0 else { return nil }
        return ImageInfo(width: w, height: h, colorType: -1, trns: false)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Actually decodes the pixels: a sound header over broken image data passes the parsers but not this.
    /// (ImageIO hands back a CGImage lazily and drawing a broken one fails silently; the pixel buffer does not lie.)
    static func decodes(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) == 1,
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let pixels = img.dataProvider?.data
        else { return false }
        return CFDataGetLength(pixels) >= img.height * img.bytesPerRow
    }

    static func validateFile(_ manifest: Manifest, path: String, data: Data, decode: Bool = true) -> [Issue] {
        guard let f = manifest.files[path], let c = classify(path) else { return [Issue(code: "bad_path", path: path)] }
        if data.count > maxFile { return [Issue(code: "too_large", path: path)] }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if data.count != f.bytes || sha != f.sha256 { return [Issue(code: "hash_mismatch", path: path)] }
        let bytes = [UInt8](data)
        guard let img = c.png ? parsePNG(bytes) : parseJPEG(bytes) else { return [Issue(code: "bad_format", path: path)] }
        var issues: [Issue] = []
        if c.role == .portrait {
            if !portraitW.contains(img.width) || !portraitH.contains(img.height) { issues.append(Issue(code: "bad_dimensions", path: path)) }
        } else {
            if img.width > frameMax || img.height > frameMax { issues.append(Issue(code: "bad_dimensions", path: path)) }
            if !(img.colorType == 6 || (img.colorType == 3 && img.trns)) { issues.append(Issue(code: "no_transparency", path: path)) }
        }
        if decode, issues.isEmpty, !decodes(data) { issues.append(Issue(code: "undecodable", path: path)) }
        return issues
    }

    /// A whole pack: manifest bytes plus path → bytes. `decode: false` matches the server's header-only check.
    static func validate(manifest data: Data, files: [String: Data], decode: Bool = true) -> [Issue] {
        let (manifest, issues) = validateManifest(data)
        guard let manifest else { return issues }
        var all = issues
        for path in manifest.files.keys.sorted() {
            guard let bytes = files[path] else { all.append(Issue(code: "missing_file", path: path)); continue }
            all += validateFile(manifest, path: path, data: bytes, decode: decode)
        }
        return all
    }

    /// Reads a pack folder (only the paths its manifest lists and the layout allows) and validates it.
    static func validate(folder: URL, decode: Bool = true) -> [Issue] {
        guard let m = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else {
            return [Issue(code: "missing_file", path: "manifest.json")]
        }
        var files: [String: Data] = [:]
        if let raw = try? JSONSerialization.jsonObject(with: m) as? [String: Any], let listed = raw["files"] as? [String: Any] {
            for path in listed.keys where classify(path) != nil {
                files[path] = try? Data(contentsOf: folder.appendingPathComponent(path))
            }
        }
        return validate(manifest: m, files: files, decode: decode)
    }

    static func codes(_ issues: [Issue]) -> [String] { Array(Set(issues.map(\.code))).sorted() }
}
