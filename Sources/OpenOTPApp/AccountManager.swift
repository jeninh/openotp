import Foundation
import OpenOTPCore

@MainActor
final class AccountManager {

    private let store: CodeStore
    private var watchers: [String: AccountWatcher] = [:]

    private let accountsKey = "accounts"

    /// Live per-account health. Updated from watcher callbacks.
    private(set) var statuses: [String: AccountStatus] = [:]
    /// Fired (on the main actor) when any account's status changes — the app
    /// uses it to refresh the menu bar and (once) notify on a new error.
    var onStatusChange: ((_ email: String, _ status: AccountStatus) -> Void)?

    init(store: CodeStore) {
        self.store = store
    }

    func status(_ email: String) -> AccountStatus { statuses[email] ?? .ok }

    var accounts: [String] {
        UserDefaults.standard.stringArray(forKey: accountsKey) ?? []
    }

    func startAll() {
        for email in accounts {
            guard let pw = SecretStore.get(imapKey(email)) else { continue }
            let host = UserDefaults.standard.string(forKey: "imapHost.\(email)") ?? IMAPProvider.guessHost(for: email)
            startWatcher(email: email, source: IMAPSource(email: email, appPassword: pw, host: host))
        }
    }

    func addIMAPAccount(email: String, appPassword: String, host: String) async throws {
        let resolvedHost = host.isEmpty ? IMAPProvider.guessHost(for: email) : host
        let source = IMAPSource(email: email, appPassword: appPassword, host: resolvedHost)
        try await source.verify()
        SecretStore.set(appPassword, for: imapKey(email))
        UserDefaults.standard.set(resolvedHost, forKey: "imapHost.\(email)")
        addToList(email)
        startWatcher(email: email, source: source)
    }

    func removeAccount(_ email: String) {
        if let w = watchers[email] { Task { await w.stop() } }
        watchers[email] = nil
        statuses[email] = nil
        SecretStore.delete(imapKey(email))
        // Legacy keys from the removed OAuth path, cleaned up for old installs.
        SecretStore.delete("refresh.\(email)")
        UserDefaults.standard.removeObject(forKey: "history.\(email)")
        UserDefaults.standard.removeObject(forKey: "accountType.\(email)")
        UserDefaults.standard.removeObject(forKey: "imapHost.\(email)")
        UserDefaults.standard.set(accounts.filter { $0 != email }, forKey: accountsKey)
    }

    // MARK: - Internals

    private func addToList(_ email: String) {
        var list = accounts
        if !list.contains(email) {
            list.append(email)
            UserDefaults.standard.set(list, forKey: accountsKey)
        }
    }

    private func startWatcher(email: String, source: MailSource) {
        // Stop any existing watcher for this account first, so re-adding an
        // already-connected account doesn't leave an orphaned watcher polling
        // (a duplicate server connection that never stops).
        if let existing = watchers[email] { Task { await existing.stop() } }
        let watcher = AccountWatcher(source: source, store: store) { [weak self] status in
            // Hop to the main actor; only propagate real changes.
            Task { @MainActor [weak self] in self?.updateStatus(email, status) }
        }
        watchers[email] = watcher
        Task { await watcher.start() }
    }

    private func updateStatus(_ email: String, _ status: AccountStatus) {
        guard statuses[email] != status else { return }
        statuses[email] = status
        onStatusChange?(email, status)
    }

    private func imapKey(_ email: String) -> String { "imap.\(email)" }
}
