import Foundation

/// Pays crystals into the ledger. For every conversation log it pays what the log has earned so far minus what
/// the ledger already paid for it, so two processes on one log, restarts, and time the app was closed all
/// settle to the same total without a separate cursor.
final class Wallet {
    let ledger: Ledger
    private let earned: (String) -> Int
    private var paid: [String: Int] = [:]  // log path → crystals already paid (genesis + earn)
    private(set) var isMigrated = false
    private let lock = NSLock()

    /// Source of the ledger entry that marks the one-time migration of past logs as finished.
    static let migrationDone = "#migration-complete"

    init(ledger: Ledger, earned: @escaping (String) -> Int = { HuntClock.progress(path: $0).earned }) {
        self.ledger = ledger
        self.earned = earned
        for e in ledger.entries where e.kind == LedgerEntry.Kind.earn.rawValue || e.kind == LedgerEntry.Kind.genesis.rawValue {
            if e.source == Self.migrationDone { isMigrated = true } else { paid[e.source, default: 0] += e.amount }
        }
    }

    /// Pays the difference for each log. Returns the entries written (none when the ledger cannot be written).
    @discardableResult
    func settle(paths: [String]) -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        var out: [LedgerEntry] = []
        for path in Set(paths).sorted() {
            let delta = earned(path) - paid[path, default: 0]
            guard delta > 0, let e = try? ledger.append(kind: .earn, source: path, amount: delta, rule: Hunt.rule) else { continue }
            paid[path, default: 0] += delta
            out.append(e)
        }
        return out
    }

    /// One-time move of everything past logs earned into the ledger, one genesis entry per log, then a
    /// completion mark. Logs already paid are skipped, so an interrupted run resumes where it stopped.
    func migrate(paths: [String], shouldContinue: () -> Bool = { true }, progress: (Int, Int) -> Void = { _, _ in }) {
        guard !isMigrated else { return }
        for (i, path) in paths.enumerated() {
            guard shouldContinue() else { return }
            progress(i, paths.count)
            lock.lock()
            if paid[path] == nil {
                let amount = max(earned(path), 0)
                if (try? ledger.append(kind: .genesis, source: path, amount: amount, rule: Hunt.rule)) != nil { paid[path] = amount }
            }
            lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        if (try? ledger.append(kind: .genesis, source: Self.migrationDone, amount: 0, rule: Hunt.rule)) != nil { isMigrated = true }
    }

    /// Every conversation log on this Mac: Claude sessions (not subagent logs) and Codex rollouts.
    static func transcripts(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let projects = home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
                out.append(f.path)
            }
        }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let f = walker?.nextObject() as? URL {
            if f.pathExtension == "jsonl", f.lastPathComponent.hasPrefix("rollout-") { out.append(f.path) }
        }
        return out.sorted()
    }
}
