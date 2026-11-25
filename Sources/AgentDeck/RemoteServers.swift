import SwiftUI
import WebKit

/// Other machines' 수혁 servers (Windows / Linux suhyeok-server, or another Mac), opened from this Mac: the same
/// /desk page in a web view, after pairing with a link from that machine ("다른 기기 연결…" there). The list is kept
/// in UserDefaults; each server's pairing cookie lives in the default WebKit store, so a server opens straight away
/// the next time.
struct RemoteServer: Codable, Identifiable, Hashable {
    var origin: String
    var name: String
    var id: String { origin }
}

@MainActor
final class RemoteServers: ObservableObject {
    static let shared = RemoteServers()
    private static let key = "remoteServers"

    @Published private(set) var servers: [RemoteServer] = []
    /// What the web view shows: a server's /desk, with "#pair=…" right after adding it.
    @Published var open: URL?

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key) ?? Data()
        servers = (try? JSONDecoder().decode([RemoteServer].self, from: data)) ?? []
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: Self.key)
    }

    /// A pairing link ("https://…/desk#pair=<32 hex>" or "http://<LAN IP>:4381/desk#pair=…"): remembers the server
    /// and opens the link, whose page pairs and then waits for the owner there to allow it. Nil when it is not a link.
    func add(link: String) -> String? {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme, let host = u.host else {
            return String(localized: "링크 형식이 아님 — 다른 컴퓨터의 수혁에서 '다른 기기 연결…'로 받은 링크를 붙여넣기")
        }
        // https everywhere; plain http only for this machine and private / Tailscale addresses (the LAN listener).
        guard scheme == "https" || (scheme == "http" && Self.privateHost(host)) else {
            return String(localized: "https 주소이거나 같은 망의 주소여야 함")
        }
        var origin = "\(scheme)://\(host)"
        if let p = u.port { origin += ":\(p)" }
        if !servers.contains(where: { $0.origin == origin }) {
            servers.append(RemoteServer(origin: origin, name: host))
            save()
        }
        let pair = (u.fragment?.range(of: #"^pair=[0-9a-f]{32}$"#, options: .regularExpression) != nil) ? "#\(u.fragment!)" : ""
        open = URL(string: origin + "/desk" + pair)
        return nil
    }

    func show(_ s: RemoteServer) { open = URL(string: s.origin + "/desk") }

    func remove(_ s: RemoteServer) {
        servers.removeAll { $0 == s }
        save()
        if open?.absoluteString.hasPrefix(s.origin) == true { open = nil }
    }

    /// 127.0.0.1 / localhost, RFC 1918, link-local, Tailscale's 100.64/10, IPv6 ULA / link-local, *.local, *.ts.net.
    nonisolated static func privateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".ts.net") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            switch (p[0], p[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        return h.hasPrefix("fd") || h.hasPrefix("fe80") || h == "::1"
    }
}

/// Menu item (수혁 ▸ 다른 컴퓨터의 수혁…).
struct RemoteServersCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("다른 컴퓨터의 수혁…") { openWindow(id: "remote") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

/// The window: saved servers on the left, the chosen server's page on the right.
struct RemoteServersView: View {
    @ObservedObject private var model = RemoteServers.shared
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            List {
                Section("서버") {
                    ForEach(model.servers) { s in
                        Button { model.show(s) } label: { Label(s.name, systemImage: "server.rack") }
                            .buttonStyle(.plain)
                            .contextMenu { Button("목록에서 지우기", role: .destructive) { model.remove(s) } }
                    }
                }
                Section("서버 추가") {
                    TextField("https://…/desk#pair=…", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("연결", action: add).disabled(link.isEmpty)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("다른 컴퓨터(윈도우·리눅스·다른 Mac)의 수혁에서 '다른 기기 연결…'을 누르고, 60초 안에 받은 링크를 붙여넣은 뒤 그 컴퓨터에서 허용")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let url = model.open {
                RemoteWebView(url: url)
            } else {
                Text("왼쪽에서 서버를 고르거나 연결 링크를 붙여넣기").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private func add() {
        error = model.add(link: link)
        if error == nil { link = "" }
    }
}

/// The remote /desk page. It is another machine's page: no native bridge, plain navigation only.
struct RemoteWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps each server's pairing cookie
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url, context.coordinator.last != url {
            context.coordinator.last = url
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(last: url) }
    final class Coordinator { var last: URL; init(last: URL) { self.last = last } }
}
