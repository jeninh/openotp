import Foundation
import Network

enum IMAPError: Error, LocalizedError {
    case connectionFailed(String)
    case commandFailed(String)
    case authFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Couldn't connect: \(m)"
        case .commandFailed(let m): return m
        case .authFailed(let m): return "Sign-in failed: \(m)"
        case .notConnected: return "Not connected."
        }
    }
}

actor IMAPClient {
    private let host: String
    private let port: UInt16
    private let email: String
    private let password: String

    private var connection: NWConnection?
    private var buffer = Data()
    private var tagCounter = 0
    private let queue = DispatchQueue(label: "com.openotp.imap")

    /// Whether the server accepted IDLE (RFC 2177). Flipped to false the first
    /// time a server refuses it, so the source falls back to interval polling.
    private(set) var idleSupported = true
    private var idleDoneSent = false

    init(host: String = "imap.gmail.com", port: UInt16 = 993, email: String, password: String) {
        self.host = host
        self.port = port
        self.email = email
        self.password = password
    }

    var isConnected: Bool { connection != nil }

    func connect() async throws {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        self.connection = conn

        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume { cont.resume() }
                case .failed(let e):
                    box.resume { cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription)) }
                case .waiting(let e):
                    box.resume { conn.cancel(); cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription)) }
                case .cancelled:
                    box.resume { cont.resume(throwing: IMAPError.connectionFailed("cancelled")) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) {
                box.resume { conn.cancel(); cont.resume(throwing: IMAPError.connectionFailed("timed out — check the server address")) }
            }
        }
        conn.stateUpdateHandler = nil
        _ = try await readLine() // server greeting
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    func login() async throws {
        // A NO/BAD to LOGIN is an authentication failure (bad app password /
        // revoked), which the UI surfaces distinctly from a network hiccup.
        do {
            try await command("LOGIN \(quoted(email)) \(quoted(password))")
        } catch IMAPError.commandFailed(let m) {
            throw IMAPError.authFailed(m)
        }
    }

    func selectInboxUIDNext() async throws -> UInt32 {
        let lines = try await command("SELECT \"INBOX\"")
        for line in lines {
            if let r = line.range(of: "[UIDNEXT ") {
                let rest = line[r.upperBound...]
                let digits = rest.prefix { $0.isNumber }
                if let v = UInt32(digits) { return v }
            }
        }
        return 1
    }

    func noop() async throws {
        try await command("NOOP")
    }

    /// RFC 2177 IDLE. Enters IDLE and blocks until the server reports mailbox
    /// activity (an untagged EXISTS/RECENT/EXPUNGE) or `maxSeconds` elapses,
    /// then sends DONE and returns once the IDLE command completes. The caller
    /// re-runs its UID search afterward to fetch whatever arrived.
    ///
    /// If the server refuses IDLE (a tagged reply instead of the `+` idling
    /// continuation), `idleSupported` is set false and the call returns at once
    /// so the source can fall back to interval polling.
    func idle(maxSeconds: TimeInterval) async throws {
        guard connection != nil else { throw IMAPError.notConnected }
        let tag = nextTag()
        idleDoneSent = false
        try await send("\(tag) IDLE\r\n")

        // Wait for the "+ idling" continuation before we're allowed to DONE.
        while true {
            let line = try await readLine()
            if line.hasPrefix("+") { break }
            if line.hasPrefix("\(tag) ") { idleSupported = false; return }
            // ignore stray untagged status lines before the continuation
        }

        // Force DONE after the timeout: servers drop IDLE after ~30 min, and a
        // periodic wake also lets us notice a silently-dropped connection.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
            await self?.sendDoneOnce()
        }
        defer { timeout.cancel() }

        while true {
            let line = try await readLine()
            if line.hasPrefix("\(tag) ") { break }          // IDLE completed
            if line.hasPrefix("* ") {
                let up = line.uppercased()
                if up.contains(" EXISTS") || up.contains(" RECENT") || up.contains(" EXPUNGE") {
                    await sendDoneOnce()                     // new activity → leave IDLE now
                }
            }
        }
    }

    /// Send DONE exactly once per IDLE (the timeout task and an EXISTS push can
    /// both race to end the same IDLE).
    private func sendDoneOnce() async {
        guard !idleDoneSent, connection != nil else { return }
        idleDoneSent = true
        try? await send("DONE\r\n")
    }

    func searchUIDs(fromUID: UInt32) async throws -> [UInt32] {
        let lines = try await command("UID SEARCH UID \(fromUID):*")
        var uids: [UInt32] = []
        for line in lines where line.uppercased().contains("SEARCH") {
            let parts = line.split(separator: " ")
            for p in parts { if let v = UInt32(p), v >= fromUID { uids.append(v) } }
        }
        return uids
    }

    func fetchRaw(uid: UInt32) async throws -> Data? {
        let tag = nextTag()
        try await send("\(tag) UID FETCH \(uid) BODY.PEEK[]\r\n")
        var message: Data?
        while true {
            let line = try await readLine()
            if let size = literalSize(line) {
                message = try await readBytes(size)
                continue
            }
            if line.hasPrefix("\(tag) ") {
                if line.uppercased().contains(" OK") { break }
                throw IMAPError.commandFailed(line)
            }
        }
        return message
    }

    // MARK: - Command plumbing

    @discardableResult
    private func command(_ cmd: String) async throws -> [String] {
        let tag = nextTag()
        try await send("\(tag) \(cmd)\r\n")
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            if let size = literalSize(line) {
                _ = try await readBytes(size)
                continue
            }
            if line.hasPrefix("\(tag) ") {
                let upper = line.uppercased()
                if upper.contains(" OK") { break }
                throw IMAPError.commandFailed(line)
            }
        }
        return lines
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(tagCounter)"
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func literalSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let inside = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(inside)
    }

    private func send(_ s: String) async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.firstRange(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + n))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + n))
        return out
    }

    private func fill() async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: IMAPError.connectionFailed("closed")); return }
                cont.resume(returning: Data())
            }
        }
        buffer.append(chunk)
    }
}

private final class ResumeBox: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func resume(_ body: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
