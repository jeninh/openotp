import AppKit
import OpenOTPCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let codeStore: CodeStore
    private let accountManager: AccountManager
    private var statusItem: NSStatusItem!
    private var isMenuOpen = false
    private var ticker: Timer?

    var onSetup: (() -> Void)?
    var onAddAccount: (() -> Void)?
    var onPreferences: (() -> Void)?

    init(codeStore: CodeStore, accountManager: AccountManager) {
        self.codeStore = codeStore
        self.accountManager = accountManager
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Stable key for the item's saved position/visibility (default is "Item-0").
        statusItem.autosaveName = "OpenOTPStatusItem"
        if let button = statusItem.button {
            if let img = IconSet.emailCheck(size: 18, color: .labelColor, template: true) {
                button.image = img
                button.imagePosition = .imageLeading
            } else {
                button.title = "OTP"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        codeStore.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        setVisible(Prefs.menuBarVisible)
        refresh()
    }

    func setVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    /// Force an immediate menu-bar refresh (e.g. an account status changed).
    func refreshNow() { refresh() }

    private func refresh() {
        let count = codeStore.fresh().count
        let needsAttention = accountManager.accounts.contains { accountManager.status($0).needsUserAction }
        if let button = statusItem.button {
            if needsAttention {
                button.title = count > 0 ? " \(count) ⚠️" : " ⚠️"
                button.toolTip = "An account needs attention — open the menu"
            } else {
                button.title = count > 0 ? " \(count)" : ""
                button.toolTip = count > 0 ? "\(count) recent code\(count == 1 ? "" : "s")" : "OpenOTP"
            }
        }
        if isMenuOpen, let menu = statusItem.menu {
            build(into: menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) { build(into: menu) }

    private func build(into menu: NSMenu) {
        menu.removeAllItems()

        let codes = codeStore.active()
        if codes.isEmpty {
            let empty = NSMenuItem(title: "No recent codes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent codes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for code in codes {
                menu.addItem(codeItem(code))
            }
            let shortcut = KeyCombo.display(keyCode: Prefs.hotKeyCode, carbonModifiers: Prefs.hotKeyModifiers)
            let hintText = Prefs.hotkeyEnabled ? "Click to copy · \(shortcut) fills the focused field" : "Click to copy"
            let hint = NSMenuItem(title: hintText, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let historyCodes = codeStore.history()
        if !historyCodes.isEmpty {
            let historyItem = NSMenuItem(title: "History (last 12h)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for code in historyCodes {
                sub.addItem(codeItem(code))
            }
            historyItem.submenu = sub
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())

        if !Accessibility.isTrusted {
            let ax = NSMenuItem(title: "⚠️ Enable Code Filling (Accessibility)…", action: #selector(enableAccessibilityClicked), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
            menu.addItem(.separator())
        }

        let accounts = accountManager.accounts
        if accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for email in accounts {
                let status = accountManager.status(email)
                let item: NSMenuItem
                if status.needsUserAction {
                    // Actionable error: clicking reconnects via onboarding.
                    item = NSMenuItem(title: "⚠️ \(email) — \(status.shortLabel)",
                                      action: #selector(reconnectClicked), keyEquivalent: "")
                    item.target = self
                    item.toolTip = "Reconnect this account"
                } else {
                    let mark = status.isError ? "…" : "✓"
                    item = NSMenuItem(title: "\(mark) \(email)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if status.isError { item.toolTip = status.shortLabel }
                }
                menu.addItem(item)
            }
        }

        if !accountManager.accounts.isEmpty {
            let add = NSMenuItem(title: "Add Email Account…", action: #selector(addAccountClicked), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        } else {
            let setup = NSMenuItem(title: "Set Up OpenOTP…", action: #selector(setupClicked), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(preferencesClicked), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let quit = NSMenuItem(title: "Quit OpenOTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func setupClicked() { onSetup?() }
    @objc private func addAccountClicked() { onAddAccount?() }
    @objc private func reconnectClicked() { onAddAccount?() }
    @objc private func preferencesClicked() { onPreferences?() }
    @objc private func enableAccessibilityClicked() { Accessibility.presentOnboarding() }

    private func codeItem(_ code: DetectedCode) -> NSMenuItem {
        // The menu's dropdown is a system-drawn window we can't exclude from
        // screen capture, so when capture-hiding is on we omit the digits (full
        // mask) — the code stays readable on the capture-excluded pill, and
        // clicking still copies it.
        let title = Prefs.hideFromCapture
            ? "Copy code  ·  \(shortSender(code.sender))"
            : "\(code.code)  —  \(shortSender(code.sender))"
        let item = NSMenuItem(title: title, action: #selector(copyCode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = code
        item.toolTip = "\(code.subject) · \(code.account)"
        return item
    }

    @objc private func copyCode(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? DetectedCode else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code.code, forType: .string)
        codeStore.markUsed(account: code.account, messageID: code.messageID)
        let value = code.code
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
        }
    }

    private func shortSender(_ sender: String) -> String {
        if let lt = sender.firstIndex(of: "<") {
            let name = sender[..<lt].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return sender.trimmingCharacters(in: .whitespaces)
    }
}
