import AppKit
import SwiftUI
import UserNotifications

/// macOS notifications when an agent changes state: it stopped on a question ("선택 필요") or it finished a turn
/// ("작업 완료"). Each kind can be turned off in Settings. Clicking one opens that agent in the main window.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let askingKey = "notifyAsking"
    static let doneKey = "notifyDone"

    private weak var store: SessionStore?
    private var last: [String: SessionStatus] = [:]
    private var authorized = false

    static var asking: Bool { UserDefaults.standard.object(forKey: askingKey) as? Bool ?? true }
    static var done: Bool { UserDefaults.standard.object(forKey: doneKey) as? Bool ?? true }

    func attach(_ store: SessionStore) {
        guard self.store == nil else { return }
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            NSLog("[notify] macOS notifications allowed: %d", ok ? 1 : 0)
            Task { @MainActor in Notifier.shared.authorized = ok }
        }
    }

    /// State changes the phone app fetches (/api/events): it asks every 15 s, so it would miss turns shorter
    /// than that; the Mac sees every change at its 3 s refresh and keeps the last 100 here.
    struct Event { let seq: Int; let session: String; let name: String; let title: String; let kind: String; let text: String; let at: Date }
    private(set) var events: [Event] = []
    private(set) var seq = 0
    /// Differs on every launch, so a phone holding a sequence number from before a restart starts over.
    let boot = UUID().uuidString

    /// Called after every refresh with the new sessions; the first call only records where everyone is.
    func observe(_ sessions: [AgentSession], store: SessionStore) {
        defer { last = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) }) }
        guard !last.isEmpty else { return }
        // Subagents (nested under the agent that launched them) report through their parent; no banner or phone event.
        for s in sessions where s.parentId == nil {
            guard let before = last[s.id], before != s.status else { continue }
            let name = store.agentName(for: s)
            let kind: String, text: String
            if s.status == .waiting {
                kind = "asking"; text = String(localized: "\(s.name) — 선택지에서 멈춰 답을 기다림")
            } else if before == .busy, s.status == .idle || s.status == .shell {
                kind = "done"; text = s.lastAssistant.map { oneLine(Speaker.plain($0), limit: 160) } ?? s.name  // no ** or ` in a banner
            } else { continue }
            seq += 1
            events.append(Event(seq: seq, session: s.id, name: name, title: s.name, kind: kind, text: text, at: Date()))
            if events.count > 100 { events.removeFirst(events.count - 100) }
            // Banners on the Mac; not for the agent you are looking at.
            guard authorized, kind == "asking" ? Self.asking : Self.done else { continue }
            if NSApp.isActive, store.selectedSession?.id == s.id { continue }
            post(s, title: "\(name) · \(kind == "asking" ? String(localized: "선택 필요") : String(localized: "작업 완료"))", body: text, sound: kind == "asking")
        }
    }

    private func post(_ s: AgentSession, title: String, body: String, sound: Bool) {
        NSLog("[notify] %@ — %@", title, body)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["session": s.id]
        if sound { c.sound = .default }
        // One notification per agent: a newer state replaces the older banner.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            if let id, let store = Notifier.shared.store, let s = store.sessions.first(where: { $0.id == id }) {
                store.selection = store.pane(for: s)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
            done()
        }
    }
}

struct NotificationSettings: View {
    @AppStorage(Notifier.askingKey) private var asking = true
    @AppStorage(Notifier.doneKey) private var done = true

    var body: some View {
        Toggle("알림: 에이전트가 선택지에서 멈추면", isOn: $asking)
        Toggle("알림: 에이전트가 작업을 마치면", isOn: $done)
        Text("지금 화면에 열어 둔 에이전트는 알리지 않음. 알림을 누르면 그 에이전트가 열림. 처음 한 번 macOS가 알림 허용을 물음.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
