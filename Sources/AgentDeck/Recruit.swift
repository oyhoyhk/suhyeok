import Foundation

/// Hiring characters with crystals. The first `freeCount` roster entries are open from the start; each hire is a
/// `spend` entry whose source is the character id, so the ledger alone says who is open.
enum Recruit {
    static let freeCount = 8
    enum Failure: Error, Equatable { case unknown, alreadyHired }

    /// Each hire costs more than the last: 100, 200, 300, … (24 hires ≈ 30,000 crystals).
    static func price(recruited: Int) -> Int { 100 * (recruited + 1) }

    /// Roster indices this ledger has opened.
    static func unlocked(roster: [String], ledger: Ledger) -> Set<Int> {
        var open = Set(0..<min(freeCount, roster.count))
        for id in hired(ledger) { if let i = roster.firstIndex(of: id) { open.insert(i) } }
        return open
    }

    static func nextPrice(roster: [String], ledger: Ledger) -> Int { price(recruited: hired(ledger).count) }

    /// Spends crystals on a character. `confirm` (the ledger server, when sync is on) must succeed first,
    /// so the server never has to take back a hire the app already recorded.
    @discardableResult
    static func hire(_ id: String, roster: [String], ledger: Ledger,
                     confirm: ((String, Int) async throws -> Void)? = nil) async throws -> LedgerEntry {
        guard let i = roster.firstIndex(of: id) else { throw Failure.unknown }
        guard !unlocked(roster: roster, ledger: ledger).contains(i) else { throw Failure.alreadyHired }
        let cost = nextPrice(roster: roster, ledger: ledger)
        guard ledger.balance >= cost else { throw Ledger.Failure.insufficient }
        try await confirm?(id, cost)
        return try ledger.append(kind: .spend, source: id, amount: -cost, rule: Hunt.rule, note: "영입")
    }

    private static func hired(_ ledger: Ledger) -> [String] {
        ledger.entries.filter { $0.kind == LedgerEntry.Kind.spend.rawValue && $0.note == "영입" }.map(\.source)
    }
}
