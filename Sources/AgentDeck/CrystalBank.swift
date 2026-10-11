import SwiftUI

/// The app's crystal ledger: pays recent conversation logs every minute, runs the one-time migration of past
/// logs, settles with the pickuma ledger server, and hires characters. The ledger file is the only source of
/// the balance; this object just keeps the UI in step with it.
@MainActor
final class CrystalBank: ObservableObject {
    static let shared = CrystalBank()

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Suhyeok")
    }
    static let syncKey = "ledgerSyncEnabled"

    @Published private(set) var balance = 0
    @Published private(set) var status: Ledger.Status = .ok
    @Published private(set) var migration: (done: Int, total: Int)?
    @Published private(set) var migrated = false
    @Published private(set) var unlocked: Set<Int> = []
    @Published private(set) var nextPrice = 0
    @Published private(set) var registered = false
    @Published private(set) var syncLine = ""
    @Published private(set) var lastReceipt: LedgerSync.Receipt?
    @Published private(set) var anchors: [LedgerSync.AnchorInfo] = []
    @Published var anchorResults: [Int: String] = [:]
    @Published var syncEnabled = UserDefaults.standard.bool(forKey: CrystalBank.syncKey) {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: Self.syncKey); syncIfDue(force: true) }
    }

    private(set) var ledger: Ledger
    private(set) var wallet: Wallet
    private(set) var sync: LedgerSync
    let strength: SignerStrength?
    private let queue = DispatchQueue(label: "com.pickuma.agentdeck.crystals", qos: .utility)
    private var timer: Timer?
    private var started = false
    private var syncing = false
    private var lastSync = Date.distantPast

    /// Offscreen snapshots and CLI checks: never create a keychain key or write the ledger.
    static var preview = false

    private init() {
        let signer = Self.preview ? nil : DeviceKey.loadOrCreate()
        strength = signer?.strength
        ledger = Ledger(url: Self.dir.appendingPathComponent("ledger.jsonl"), signer: signer)
        wallet = Wallet(ledger: ledger)
        sync = LedgerSync(ledger: ledger, stateURL: Self.dir.appendingPathComponent("ledger-sync.json"))
        publish()
    }

    var roster: [String] { Art.roster.map(\.id) }

    /// Begins paying (once per app run): migrate past logs first, then settle every minute.
    func start() {
        guard !started else { return }
        started = true
        migrateIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func migrateIfNeeded() {
        guard !wallet.isMigrated, ledger.status == .ok else { return }
        let wallet = wallet
        migration = (0, 0)
        queue.async {
            let paths = Wallet.transcripts()
            wallet.migrate(paths: paths, progress: { done, total in
                if done % 50 == 0 { Task { @MainActor in CrystalBank.shared.migration = (done, total) } }
            })
            Task { @MainActor in
                CrystalBank.shared.migration = nil
                CrystalBank.shared.publish()
                CrystalBank.shared.tick()
            }
        }
    }

    /// Pays logs touched in the last 7 days (live sessions included), then settles with the server when due.
    func tick() {
        guard wallet.isMigrated else { return }
        let wallet = wallet
        queue.async {
            let week = Date().addingTimeInterval(-7 * 86400)
            let recent = Wallet.transcripts().filter {
                ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date ?? .distantPast) > week
            }
            wallet.settle(paths: recent)
            Task { @MainActor in
                CrystalBank.shared.publish()
                CrystalBank.shared.syncIfDue()
            }
        }
    }

    func publish() {
        balance = ledger.balance
        status = ledger.status
        migrated = wallet.isMigrated
        unlocked = Recruit.unlocked(roster: roster, ledger: ledger)
        nextPrice = Recruit.nextPrice(roster: roster, ledger: ledger)
        registered = sync.isRegistered
    }

    // MARK: server

    func syncIfDue(force: Bool = false) {
        guard syncEnabled, registered, !syncing, force || Date().timeIntervalSince(lastSync) > 300 else { return }
        syncing = true
        let sync = sync
        Task {
            do {
                if let r = try await sync.sync() { lastReceipt = r }
                syncLine = "정산 \(Date().formatted(date: .omitted, time: .shortened))"
                    + (lastReceipt.map { " · 서버 잔액 \($0.balance)" + ($0.pendingClamp > 0 ? " · 상한 초과 \($0.pendingClamp)" : "") } ?? "")
            } catch {
                syncLine = "정산 실패: \(Self.describe(error))"
            }
            lastSync = Date()
            syncing = false
            publish()
        }
    }

    func register(code: String) async -> String? {
        do {
            try await sync.register(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            publish()
            syncIfDue(force: true)
            return nil
        } catch { return Self.describe(error) }
    }

    func loadAnchors() async {
        anchors = (try? await sync.anchors()) ?? []
    }

    /// Checks one anchor against Bitcoin, and against the head hash this Mac saw in a signed receipt.
    func verify(_ a: LedgerSync.AnchorInfo) async {
        anchorResults[a.id] = "확인 중…"
        guard let digest = AnchorVerifier.hexBytes(a.hash), let proof = try? await sync.proof(a) else {
            anchorResults[a.id] = "증명을 받지 못함"
            return
        }
        if let seen = sync.knownHead(seq: a.seq), seen != a.hash {
            anchorResults[a.id] = "⚠︎ 이 기기가 받은 영수증의 서버 장부와 다름"
            return
        }
        switch await AnchorVerifier().verify(proof: proof, expectedDigest: digest) {
        case .confirmed(let h): anchorResults[a.id] = "비트코인 #\(h) 확정"
        case .pending: anchorResults[a.id] = "캘린더 대기 (보통 몇 시간)"
        case .mismatch: anchorResults[a.id] = "⚠︎ 블록과 불일치"
        case .unreachable: anchorResults[a.id] = "블록 탐색기 응답 없음"
        case .invalid(let why): anchorResults[a.id] = "증명 오류: \(why)"
        }
    }

    // MARK: spending

    func hire(_ id: String) async -> String? {
        let viaServer = syncEnabled && registered
        let sync = sync
        do {
            try await Recruit.hire(id, roster: roster, ledger: ledger,
                                   confirm: viaServer ? { try await sync.confirmSpend(item: $0, amount: $1) } : nil)
            publish()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Sets a broken ledger aside (kept as ledger.broken-*.jsonl) and starts a new one.
    func startOver() {
        _ = try? ledger.startOver()
        wallet = Wallet(ledger: ledger)
        publish()
        migrateIfNeeded()
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case Ledger.Failure.insufficient: return "결정이 부족함"
        case Ledger.Failure.notWritable: return "장부에 쓸 수 없음"
        case Recruit.Failure.alreadyHired: return "이미 영입함"
        case LedgerSync.Failure.notRegistered: return "서버에 등록되지 않음"
        case LedgerSync.Failure.keyChanged: return "서버 키가 바뀜 — 연결을 멈춤"
        case LedgerSync.Failure.badSignature: return "서버 서명이 맞지 않음"
        case LedgerSync.Failure.server(_, let code):
            return ["invalid_code": "등록 코드가 틀림", "code_used": "이미 쓴 등록 코드", "code_expired": "만료된 등록 코드",
                    "insufficient": "서버 잔액 부족", "revoked": "해지된 기기", "key_registered": "이미 등록된 기기"][code] ?? "서버 오류 \(code)"
        case is URLError: return "서버에 연결할 수 없음"
        default: return "\(error)"
        }
    }
}

// MARK: - Command line

extension CrystalBank {
    /// Prints the ledger's state without writing to it (no key is loaded).
    nonisolated static func report() {
        let ledger = Ledger(url: dir.appendingPathComponent("ledger.jsonl"), signer: nil)
        let entries = ledger.entries
        let verdict: String
        switch ledger.status {
        case .broken(let seq): verdict = "BROKEN at entry #\(seq)"
        default: verdict = entries.isEmpty ? "empty" : "chain and signatures OK"
        }
        var kinds: [String: (n: Int, sum: Int)] = [:]
        for e in entries { kinds[e.kind, default: (0, 0)].n += 1; kinds[e.kind, default: (0, 0)].sum += e.amount }
        print("ledger \(ledger.url.path)")
        print("entries \(entries.count) · balance \(ledger.balance) · \(verdict)")
        for (k, v) in kinds.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v.n) entries, \(v.sum)") }
        print("migrated \(entries.contains { $0.source == Wallet.migrationDone })")
        let sync = LedgerSync(ledger: ledger, stateURL: dir.appendingPathComponent("ledger-sync.json"))
        print("server \(sync.state.device.map { "device \($0), confirmed through #\(sync.state.ackSeq ?? -1)" } ?? "not registered")")
    }

    /// Renders the guild page offscreen into a PNG (does not start paying).
    static func snapshot(path: String) -> Never {
        preview = true
        let host = NSHostingView(rootView: GuildView().frame(width: 860, height: 1100).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 1100)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 860, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

// MARK: - Guild page

/// Crystals, hiring, and how far the ledger can be trusted.
struct GuildView: View {
    @ObservedObject var bank = CrystalBank.shared
    @State private var message: String?
    @State private var code = ""
    @State private var confirmReset = false

    private let gold = Color(red: 0.85, green: 0.68, blue: 0.25)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if case .broken(let seq) = bank.status { brokenBanner(seq) }
                recruits
                server
                guarantees
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task { await bank.loadAnchors() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "diamond.fill").foregroundStyle(.cyan)
            Text("\(bank.balance)").font(.system(size: 34, weight: .bold).monospacedDigit())
            Text("결정").foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(protection).font(.caption)
                if let m = bank.migration {
                    Text(m.total == 0 ? "지난 기록 정리 준비 중…" : "지난 기록 이관 \(m.done)/\(m.total)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var protection: String {
        switch (bank.status, bank.strength) {
        case (.broken, _): return "장부 훼손"
        case (.readOnly(.noKey), _), (_, nil): return "서명 키 없음 · 읽기 전용"
        case (.readOnly(.keyMismatch), _): return "다른 기기의 장부 · 읽기 전용"
        case (_, .secureEnclave?): return "🔒 보안칩 서명"
        case (_, .software?): return "약한 보호 (보안칩 없음)"
        }
    }

    private func brokenBanner(_ seq: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("장부 훼손 (항목 #\(seq))").font(.headline).foregroundStyle(.red)
            Text("장부 파일이 바뀌어 사슬이나 서명이 맞지 않음. 지급과 영입을 멈춤.").font(.callout)
            Button("새 장부 시작…") { confirmReset = true }
                .confirmationDialog("기존 장부는 ledger.broken-*.jsonl 로 보관하고 0부터 새로 시작함", isPresented: $confirmReset) {
                    Button("새 장부 시작", role: .destructive) { bank.startOver() }
                }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recruits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("용병 영입").font(.title3.bold())
                Spacer()
                Text("다음 영입 \(bank.nextPrice) 결정").font(.callout).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                ForEach(Array(Art.roster.enumerated()), id: \.offset) { i, c in
                    card(i, c)
                }
            }
        }
    }

    private func card(_ i: Int, _ c: Character) -> some View {
        let open = bank.unlocked.contains(i)
        let affordable = bank.balance >= bank.nextPrice && bank.status == .ok
        return VStack(spacing: 6) {
            Group {
                if open, let img = Art.image("portraits/\(c.id)") ?? Art.image("sprites/\(c.id)") {
                    Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else {
                    // Who it is stays a surprise until hired.
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)).aspectRatio(0.75, contentMode: .fit)
                        .overlay(Image(systemName: open ? "person.fill" : "questionmark").font(.title).foregroundStyle(gold))
                }
            }
            .frame(height: 72)
            Text(open ? c.name : "???").font(.caption.bold()).lineLimit(1)
            if !open {
                Button("\(bank.nextPrice) 💎") {
                    Task { message = await bank.hire(c.id) }
                }
                .buttonStyle(.bordered).tint(gold).controlSize(.small)
                .disabled(!affordable)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("pickuma 결정 서버").font(.title3.bold())
            Toggle("서버와 정산 (suhyeok.pickuma.com)", isOn: $bank.syncEnabled)
            Text("pickuma 생태계에서는 서버가 서명한 잔액만 인정함. 켜면 영입도 서버 확인을 받아야 확정됨.")
                .font(.caption).foregroundStyle(.secondary)
            if bank.syncEnabled {
                if bank.registered {
                    Text(bank.syncLine.isEmpty ? "등록됨 · 정산 대기" : bank.syncLine).font(.callout)
                    if let r = bank.lastReceipt, r.pending > 0 {
                        Text("이관분 \(r.pending) 결정은 관리자 승인 대기").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        TextField("등록 코드 (XXXX-XXXX-XXXX)", text: $code).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Button("등록") { Task { message = await bank.register(code: code) } }.disabled(code.isEmpty)
                    }
                }
                anchorList
            }
        }
    }

    private var anchorList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("비트코인 공증").font(.headline)
                Spacer()
                Button("새로고침") { Task { await bank.loadAnchors() } }.controlSize(.small)
            }
            if bank.anchors.isEmpty {
                Text("아직 공증 기록 없음 (서버가 하루 1회 서버 장부 해시를 비트코인에 기록)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(bank.anchors.prefix(10)) { a in
                HStack {
                    Text("서버 장부 #\(a.seq)").font(.callout.monospacedDigit())
                    Text(Date(timeIntervalSince1970: TimeInterval(a.submittedAt)).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let r = bank.anchorResults[a.id] { Text(r).font(.caption) }
                    Button("확인") { Task { await bank.verify(a) } }.controlSize(.small)
                }
            }
        }
    }

    private var guarantees: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 장부가 막는 것과 못 막는 것").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Self.guarantees, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.callout)
                        Text(row.1).font(.callout.bold())
                        Text(row.2).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static let guarantees: [(String, String, String)] = [
        ("장부 항목 수정·삭제·순서 변경", "✅ 탐지", "해시 사슬이 깨짐"),
        ("해시를 다시 계산해 장부 바꿔치기", "✅ 탐지", "보안칩 서명을 다시 만들 수 없음"),
        ("장부·키를 지우고 새로 시작", "서버만 ✅", "서버가 기기별 잔액을 보관"),
        ("고친 앱이 가짜 활동을 보고", "서버 상한까지", "시간당 상한을 넘는 지급은 서버가 잘라냄"),
        ("대화 기록 파일 위조", "서버 상한까지", "입력이 로컬 파일이라 막을 수 없음"),
        ("운영자가 서버 잔액 수정", "✅ 탐지", "서버 장부 해시 사슬 + 비트코인 공증"),
    ]
}
