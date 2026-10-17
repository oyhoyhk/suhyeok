import AppKit
import SwiftUI

/// The character market page: approved characters to buy, what you own, and what you sell.
struct MarketView: View {
    @ObservedObject var bank = CrystalBank.shared
    @State private var tab = 0
    @State private var listings: [MarketService.Listing] = []
    @State private var mine: MarketService.Mine?
    @State private var previews: [String: NSImage] = [:]
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !bank.canTrade {
                Text("마켓은 서버 정산을 켜고 등록한 기기에서만 쓸 수 있음 (길드 · 결정 > pickuma 결정 서버)")
                    .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            Picker("", selection: $tab) {
                Text("둘러보기").tag(0)
                Text("판매").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == 0 { browse } else { selling }
                    terms
                }
            }
        }
        .padding(24)
        .task(id: tab) { await reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("캐릭터 마켓").font(.title2.bold())
            Spacer()
            Image(systemName: "diamond.fill").foregroundStyle(.cyan)
            Text("\(bank.balance)").font(.title3.monospacedDigit().bold())
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
    }

    private func reload() async {
        guard let market = bank.market, bank.canTrade else { return }
        do {
            if tab == 0 {
                listings = try await market.listings()
                for l in listings where previews[l.id] == nil {
                    if let p = l.previews?.portrait ?? l.previews?.sprite, let data = await market.image(p) { previews[l.id] = NSImage(data: data) }
                }
            }
            mine = try await market.mine()
            message = nil
        } catch is CancellationError {
        } catch URLError.cancelled {  // switching tabs cancels the previous load: not an error
        } catch {
            message = String(localized: "마켓을 불러오지 못함: \(CrystalBank.describe(error))")
        }
    }

    // MARK: browse

    private var browse: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                ForEach(listings) { l in card(l) }
            }
            .overlay { if listings.isEmpty && bank.canTrade { Text("아직 승인된 캐릭터가 없음").foregroundStyle(.secondary).padding(40) } }
            // Bought characters that left the catalogue (delisted) stay downloadable.
            let gone = (mine?.purchases ?? []).filter { p in !listings.contains { $0.id == p.id } }
            if !gone.isEmpty {
                Text("판매가 끝난 내 구매").font(.headline)
                ForEach(gone) { p in
                    HStack {
                        Text(p.name).font(.callout)
                        Spacer()
                        if AssetLibrary.shared.isInstalled(p.id) {
                            Text("보유").font(.caption.bold()).foregroundStyle(.green)
                        } else {
                            Button(busy == p.id ? "…" : "다시 받기") { Task { await act(p.id) { try await $0.install(p.id) } } }
                                .controlSize(.small).disabled(busy != nil || !bank.canTrade)
                        }
                    }
                }
            }
        }
    }

    private func card(_ l: MarketService.Listing) -> some View {
        let owned = bank.market?.owns(l.id) ?? false
        let installed = AssetLibrary.shared.isInstalled(l.id)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let img = previews[l.id] {
                    Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2))
                }
            }
            .frame(height: 150).frame(maxWidth: .infinity)
            Text(l.profile.map { L10n.english ? l.name : "\($0.ko) · \(l.name)" } ?? l.name).font(.headline).lineLimit(1)
            if let role = l.profile?.role { Text(role).font(.caption).lineLimit(1) }
            Text("\(l.seller.alias?.isEmpty == false ? l.seller.alias! : String(localized: "판매자")) · \(l.seller.tag)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let d = l.description, !d.isEmpty { Text(d).font(.caption).lineLimit(3) }
            HStack {
                Text("\(l.price) 💎").font(.callout.monospacedDigit().bold())
                if let s = l.sales, s > 0 { Text("· \(s)명 구매").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if owned && installed {
                    Text("보유").font(.caption.bold()).foregroundStyle(.green)
                } else {
                    Button(busy == l.id ? "…" : owned ? "다시 받기" : "구매") {
                        Task { await act(l.id) { try await $0.buy(l) } }
                    }
                    .controlSize(.small)
                    .disabled(busy != nil || !bank.canTrade || (!owned && bank.balance < l.price))
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .hoverInfo {
            CharacterInfo(character: Character(id: AssetLibrary.idPrefix + l.id, name: l.name, ko: l.profile?.ko, role: l.profile?.role,
                                               visual: l.profile?.visual, tone: l.profile?.tone))
        }
    }

    private func act(_ id: String, _ work: (MarketService) async throws -> Void) async {
        guard let market = bank.market else { return }
        busy = id
        defer { busy = nil }
        do {
            try await work(market)
            AssetLibrary.shared.reload()
            message = nil
        } catch {
            message = CrystalBank.describe(error)
        }
        bank.publish()
    }

    // MARK: selling

    @State private var folder: URL?
    @State private var issues: [String] = []
    @State private var picked: Character?
    @State private var price = 300
    @State private var alias = ""
    @State private var note = ""
    @State private var progress: (Int, Int)?

    private var selling: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("새 캐릭터 올리기") {
                VStack(alignment: .leading, spacing: 8) {
                    MarketGuide()
                    Divider()
                    HStack {
                        Button("팩 폴더 선택…") { pickFolder() }
                        Text(folder?.lastPathComponent ?? String(localized: "manifest.json이 있는 폴더 (docs/asset-pack-spec.md)")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !issues.isEmpty {
                        Text("규격 오류: \(issues.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
                    }
                    if let picked {
                        // What buyers will get: their agents talk in this voice.
                        CharacterInfo(character: picked)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("팩에는 일러스트·스프라이트·동작 프레임과 profile(한글 이름·직업·말투, 선택: 외형·무기)이 모두 있어야 함 (format 2, docs/asset-pack-spec.md). 말투는 구매자 에이전트의 대답 말투로 쓰임.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("가격")
                        TextField("", value: $price, format: .number).frame(width: 80).textFieldStyle(.roundedBorder)
                        Text("결정 (50~5,000, 판매 시 90% 수령)").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("판매자 별칭 (선택, 24자)", text: $alias).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    TextField("설명 (선택, 500자)", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                    HStack {
                        Button(progress.map { String(localized: "올리는 중 \($0.0)/\($0.1)") } ?? String(localized: "심사 요청")) { Task { await upload() } }
                            .disabled(folder == nil || !issues.isEmpty || progress != nil || !bank.canTrade || !(50...5000).contains(price))
                        Text("운영진이 승인하면 마켓에 올라감").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
            if let mine {
                Text("내 판매 · 미반영 수익 \(mine.pendingIncome) 결정").font(.headline)
                ForEach(mine.listings) { m in
                    HStack {
                        Text(m.name).font(.callout)
                        Text("\(m.price) 💎").font(.caption.monospacedDigit())
                        Spacer()
                        if let s = m.sales, s > 0 { Text("\(s)건 · \(m.earned ?? 0) 결정").font(.caption) }
                        Text(Self.status[m.status] ?? m.status).font(.caption.bold()).foregroundStyle(m.status == "rejected" ? .red : .secondary)
                        if m.status == "draft" {
                            Button(busy == m.id ? "…" : "취소") {
                                Task { await act(m.id) { try await $0.withdraw(m.id) }; await reload() }
                            }
                            .controlSize(.small).disabled(busy != nil || !bank.canTrade)
                        }
                    }
                    if let r = m.reason, !r.isEmpty { Text("사유: \(r)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    static let status = ["draft": String(localized: "올리는 중"), "pending": String(localized: "심사 대기"),
                         "approved": String(localized: "판매 중"), "rejected": String(localized: "거절"),
                         "delisted": String(localized: "판매 중지"), "withdrawn": String(localized: "취소")]

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        let manifest = (try? Data(contentsOf: url.appendingPathComponent("manifest.json"))).flatMap { AssetPack.validateManifest($0).0 }
        var found = AssetPack.validate(folder: url)
        // Format 1 packs still install, but new uploads must carry a profile.
        if let m = manifest, m.format != AssetPack.uploadFormat { found.append(.init(code: "bad_format_version", path: "")) }
        issues = AssetPack.codes(found)
        picked = manifest.flatMap { m in
            m.profile.map { Character(id: "", name: m.name ?? "", ko: $0.ko, role: $0.role, visual: $0.visual, tone: $0.tone) }
        }
    }

    private func upload() async {
        guard let folder, let market = bank.market else { return }
        progress = (0, 0)
        defer { progress = nil }
        do {
            try await market.upload(folder: folder, price: price, alias: alias, description: note) { done, total in
                progress = (done, total)
            }
            message = String(localized: "심사 요청을 보냄")
            self.folder = nil
            picked = nil
            mine = try? await market.mine()
        } catch {
            message = CrystalBank.describe(error)
        }
    }

    private var terms: some View {
        Text("결정은 앱 안에서만 쓰이며 현금으로 바꿀 수 없음. 올린 캐릭터의 저작권 책임은 판매자에게 있음. 운영진은 승인한 캐릭터라도 판매를 중지할 수 있음. 구매가의 10%는 소각됨.")
            .font(.caption2).foregroundStyle(.secondary).padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
