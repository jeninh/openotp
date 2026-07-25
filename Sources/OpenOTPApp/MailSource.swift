import Foundation
import OpenOTPCore

/// A recoverable account condition surfaced to the user. Distinguishes
/// "you must re-authenticate" from "the network hiccuped" so the UI can guide.
enum AccountError: Error, Sendable, Equatable {
    case authFailed(String)   // bad app password / credentials rejected
    case network(String)      // transient connectivity; will retry automatically
}

/// The live health of a connected account, shown in the menu bar.
enum AccountStatus: Sendable, Equatable {
    case ok
    case authFailed(String)
    case network(String)

    var isError: Bool { if case .ok = self { return false }; return true }

    /// Whether the user must act (vs. a transient network blip that self-heals).
    var needsUserAction: Bool {
        switch self { case .authFailed: return true; default: return false }
    }

    var shortLabel: String {
        switch self {
        case .ok: return "Connected"
        case .authFailed: return "Sign-in failed — reconnect"
        case .network: return "Offline — retrying"
        }
    }
}

protocol MailSource: Sendable {
    /// Fetch new messages. Throws `AccountError` on a surfaced condition; the
    /// watcher maps it to an `AccountStatus`. Transient successes report `.ok`.
    func poll() async throws -> [EmailMessage]
}


enum IMAPProvider {
    static func guessHost(for email: String) -> String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return "imap.gmail.com"
        case "outlook.com", "hotmail.com", "live.com", "msn.com", "office365.com": return "outlook.office365.com"
        case "icloud.com", "me.com", "mac.com": return "imap.mail.me.com"
        case "yahoo.com", "ymail.com": return "imap.mail.yahoo.com"
        case "fastmail.com", "fastmail.fm": return "imap.fastmail.com"
        case "aol.com": return "imap.aol.com"
        case "proton.me", "protonmail.com": return "127.0.0.1"
        default: return domain.isEmpty ? "" : "imap.\(domain)"
        }
    }
}

actor IMAPSource: MailSource {
    private let account: String
    private let client: IMAPClient
    private var lastUID: UInt32?

    init(email: String, appPassword: String, host: String) {
        self.account = email
        self.client = IMAPClient(host: host, email: email, password: appPassword)
    }

    func poll() async throws -> [EmailMessage] {
        do {
            if await !client.isConnected {
                try await client.connect()
                try await client.login()
                lastUID = try await client.selectInboxUIDNext()
                return []
            }
            guard let last = lastUID else {
                lastUID = try await client.selectInboxUIDNext()
                return []
            }
            // Fetch anything that arrived since the last seen UID.
            var uids = try await client.searchUIDs(fromUID: last).sorted()
            // Push path: if nothing is waiting, block in IDLE until the server
            // pushes new mail or the short re-arm window elapses, then search
            // again. Gmail's IDLE push can lag many seconds behind mail that's
            // already in the inbox, so the 2s window bounds worst-case latency
            // to ~2s while still delivering instantly when the push fires.
            // Falls back to plain interval polling if the server doesn't support
            // IDLE (idleSupported flips false inside idle()).
            if uids.isEmpty {
                if await client.idleSupported {
                    try await client.idle(maxSeconds: 2)
                    uids = try await client.searchUIDs(fromUID: last).sorted()
                } else {
                    try await client.noop()   // keepalive when IDLE is unavailable
                }
            }
            var out: [EmailMessage] = []
            for uid in uids {
                if let raw = try await client.fetchRaw(uid: uid) {
                    let p = RFC822Parser.parse(raw)
                    out.append(EmailMessage(
                        id: "\(account)-\(uid)", account: account, sender: p.from,
                        subject: p.subject, body: p.body, isHTML: p.isHTML, receivedAt: Date()))
                }
                lastUID = Swift.max(lastUID ?? 0, uid + 1)
            }
            return out
        } catch let e as IMAPError {
            await client.disconnect()
            if case .authFailed(let m) = e { throw AccountError.authFailed(m) }
            throw AccountError.network(e.errorDescription ?? "IMAP error")
        } catch let e as AccountError {
            await client.disconnect()
            throw e
        } catch {
            await client.disconnect()
            throw AccountError.network(error.localizedDescription)
        }
    }

    func verify() async throws {
        try await client.connect()
        try await client.login()
        _ = try await client.selectInboxUIDNext()
        await client.disconnect()
    }
}
