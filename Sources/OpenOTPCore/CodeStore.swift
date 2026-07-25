import Foundation

/// In-memory store of detected codes. Nothing is ever written to disk or logged
/// (privacy invariant): entries live only in memory with staged TTLs — unused
/// codes expire, used codes drop out of the active list quickly, and a short
/// history is kept for the menu. Thread-safe (lock-guarded); callbacks fire for
/// UI refresh (`onChange`) and new detections (`onNewCode`).
public final class CodeStore: @unchecked Sendable {

    private struct Entry {
        var code: DetectedCode
        var usedAt: Date?
        var historyAt: Date?
    }

    private let activeUnusedTTL: TimeInterval
    private let usedTTL: TimeInterval
    private let historyTTL: TimeInterval
    private let notBefore: Date
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let dateProvider: () -> Date

    public var onChange: (() -> Void)?
    public var onNewCode: ((DetectedCode) -> Void)?

    public init(
        ttl: TimeInterval = 7200,
        usedTTL: TimeInterval = 120,
        historyTTL: TimeInterval = 43200,
        notBefore: Date = .distantPast,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.activeUnusedTTL = ttl
        self.usedTTL = usedTTL
        self.historyTTL = historyTTL
        self.notBefore = notBefore
        self.dateProvider = dateProvider
    }

    /// Insert a freshly detected code. Ignored if older than the launch floor
    /// (`notBefore`). De-dupes by (account, messageID); `onNewCode` fires only
    /// for genuinely new codes, `onChange` always.
    public func insert(_ code: DetectedCode) {
        guard code.receivedAt >= notBefore else { return }
        lock.lock()
        let existed = entries.contains { $0.code.account == code.account && $0.code.messageID == code.messageID }
        entries.removeAll { $0.code.account == code.account && $0.code.messageID == code.messageID }
        entries.append(Entry(code: code, usedAt: nil, historyAt: nil))
        pruneLocked()
        lock.unlock()
        if !existed { onNewCode?(code) }
        onChange?()
    }

    /// Mark a code as used (filled/copied) so it drops out of the active list
    /// promptly and moves toward history.
    public func markUsed(account: String, messageID: String) {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.code.account == account && $0.code.messageID == messageID }) {
            if entries[i].usedAt == nil { entries[i].usedAt = dateProvider() }
        }
        pruneLocked()
        lock.unlock()
        onChange?()
    }

    /// Currently surfaced codes (not yet aged into history), newest first.
    public func active() -> [DetectedCode] {
        lock.lock(); pruneLocked()
        let result = entries.filter { $0.historyAt == nil }.sorted { $0.code.receivedAt > $1.code.receivedAt }.map { $0.code }
        lock.unlock()
        return result
    }

    /// Recently-seen codes kept for the History submenu, newest first.
    public func history() -> [DetectedCode] {
        lock.lock(); pruneLocked()
        let result = entries.filter { $0.historyAt != nil }.sorted { ($0.historyAt ?? .distantPast) > ($1.historyAt ?? .distantPast) }.map { $0.code }
        lock.unlock()
        return result
    }

    /// Alias for `active()` — the count shown in the menu-bar badge.
    public func fresh() -> [DetectedCode] { active() }

    /// The most recent active code (what the global hotkey fills).
    public func latest() -> DetectedCode? { active().first }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
        onChange?()
    }

    private func pruneLocked() {
        let now = dateProvider()
        for i in entries.indices {
            guard entries[i].historyAt == nil else { continue }
            let e = entries[i]
            let usedExpired = e.usedAt.map { now >= $0.addingTimeInterval(usedTTL) } ?? false
            let unusedExpired = now >= e.code.receivedAt.addingTimeInterval(activeUnusedTTL)
            if usedExpired || unusedExpired {
                entries[i].historyAt = now
            }
        }
        entries.removeAll { entry in
            if entry.code.receivedAt < notBefore { return true }
            if let h = entry.historyAt, now >= h.addingTimeInterval(historyTTL) { return true }
            return false
        }
    }
}
