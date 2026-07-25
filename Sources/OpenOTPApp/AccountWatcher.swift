import Foundation
import OpenOTPCore

actor AccountWatcher {
    private let source: MailSource
    private let store: CodeStore
    private let pollInterval: TimeInterval
    private let onStatus: @Sendable (AccountStatus) -> Void
    private var task: Task<Void, Never>?

    init(source: MailSource, store: CodeStore, pollInterval: TimeInterval = 2,
         onStatus: @escaping @Sendable (AccountStatus) -> Void = { _ in }) {
        self.source = source
        self.store = store
        self.pollInterval = pollInterval
        self.onStatus = onStatus
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            let started = Date()
            do {
                for message in try await source.poll() {
                    if let detected = OTPv2.extract(from: message) {
                        store.insert(detected)
                    }
                }
                onStatus(.ok)
            } catch let e as AccountError {
                onStatus(Self.status(for: e))
            } catch {
                onStatus(.network(error.localizedDescription))
            }
            // Rate-limit as a FLOOR between poll starts, not an additive delay:
            // an IMAP source that already blocked in IDLE for its window returns
            // slow and sleeps ~0, so IDLE cycles run back-to-back; a fast-returning
            // poll (e.g. one that found mail) is paced to pollInterval.
            let remaining = pollInterval - Date().timeIntervalSince(started)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    private static func status(for e: AccountError) -> AccountStatus {
        switch e {
        case .authFailed(let m): return .authFailed(m)
        case .network(let m): return .network(m)
        }
    }
}
