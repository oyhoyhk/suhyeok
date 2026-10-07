import AppKit
import Foundation

/// Checks GitHub for a newer release and upgrades through Homebrew.
/// Agent sessions live on the tmux server, so restarting the app does not interrupt them.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "oyhoyhk/suhyeok"
    nonisolated static let formula = "oyhoyhk/tap/suhyeok"

    enum State: Equatable { case idle, available(String), upgrading, failed(String) }
    @Published var state: State = .idle

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    /// Installed by Homebrew when the bundle sits in a Cellar; dev builds only get a download link.
    var viaBrew: Bool { Bundle.main.bundlePath.contains("/Cellar/suhyeok/") }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
    }

    func check() async {
        guard let latest = await Self.latestVersion() else { return }  // offline: stay quiet
        if Self.isNewer(latest, than: current), state != .upgrading { state = .available(latest) }
    }

    nonisolated static func latestVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric compare of dotted versions: 0.1.10 > 0.1.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// `brew update` first: brew's own auto-update may skip a tap fetched within the last day.
    func upgrade() {
        guard viaBrew, let brew = Self.brew else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
            return
        }
        state = .upgrading
        Task.detached {
            let ok = Self.run(brew, ["update", "--quiet"]) == 0 && Self.run(brew, ["upgrade", Self.formula]) == 0
            await MainActor.run {
                if ok { Self.relaunch(brew: brew) } else { Updater.shared.state = .failed("brew upgrade 실패 — 터미널에서 brew upgrade suhyeok 실행") }
            }
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"  // already updated explicitly
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Open the new version from the stable opt path once this process has quit.
    private static func relaunch(brew: String) {
        let prefix = (brew as NSString).deletingLastPathComponent.replacingOccurrences(of: "/bin", with: "")
        let app = "\(prefix)/opt/suhyeok/수혁.app"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \(TmuxEngine.quote(app))"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
