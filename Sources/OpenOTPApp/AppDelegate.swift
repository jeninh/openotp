import AppKit
import Carbon.HIToolbox
import OpenOTPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusController: StatusItemController!
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    let codeStore = CodeStore(ttl: 7200, notBefore: Date())
    private var accountManager: AccountManager!
    private let filler = Filler()
    private let hotKey = HotKey()
    private let pill = FillPill()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another copy is already running (e.g. a
        // login item plus a manual launch, or a downloaded copy plus an
        // installed one), hand off to it and quit — otherwise you'd get two
        // menu-bar icons and doubled IMAP connections. (No-op under `swift run`,
        // which has no bundle identifier.)
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
            if let other = others.first {
                other.activate(options: [])
                NSApp.terminate(nil)
                return
            }
        }

        MainMenu.install()

        NSApp.applicationIconImage = AppIcon.image()

        // Repair any previously-saved shortcut that lacks ⌘/⌃ (e.g. an old ⌥V
        // that would type a character instead of firing reliably).
        if !KeyCombo.hasRequiredModifiers(Prefs.hotKeyModifiers) {
            Prefs.hotKeyCode = UInt32(kVK_ANSI_V)
            Prefs.hotKeyModifiers = UInt32(controlKey | optionKey)
        }
        hotKey.register(keyCode: Prefs.hotKeyCode, modifiers: Prefs.hotKeyModifiers) { [weak self] in self?.fillLatest() }
        if !Prefs.hotkeyEnabled { hotKey.unregister() }

        accountManager = AccountManager(store: codeStore)
        accountManager.onStatusChange = { [weak self] _, _ in
            self?.statusController.refreshNow()
        }
        statusController = StatusItemController(codeStore: codeStore, accountManager: accountManager)
        statusController.onSetup = { [weak self] in self?.showOnboarding() }
        statusController.onAddAccount = { [weak self] in self?.showOnboarding() }
        statusController.onPreferences = { [weak self] in self?.showSettings() }
        statusController.install()

        LoginItem.setEnabled(Prefs.launchAtLogin)

        pill.onFill = { [weak self] code in
            guard let self else { return }
            if self.filler.fill(code.code) {
                self.codeStore.markUsed(account: code.account, messageID: code.messageID)
            }
        }

        codeStore.onNewCode = { [weak self] code in
            DispatchQueue.main.async {
                self?.maybeShowPill(for: code)
            }
        }

        accountManager.startAll()

        // Track window closes so the Dock icon disappears when the last
        // window goes away (the app lives on in the menu bar).
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)

        if accountManager.accounts.isEmpty {
            showOnboarding()
        }
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow,
              closing === onboarding?.window || closing === settingsWindow?.window else { return }
        // Defer one runloop turn: the closing window still reads as visible here.
        DispatchQueue.main.async { [weak self] in self?.hideDockIfNoWindows() }
    }

    private func hideDockIfNoWindows() {
        let anyOpen = onboarding?.window?.isVisible == true || settingsWindow?.window?.isVisible == true
        if !anyOpen { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if accountManager.accounts.isEmpty { showOnboarding() } else { showSettings() }
        }
        return true
    }

    private func maybeShowPill(for code: DetectedCode) {
        guard Prefs.pillEnabled, Accessibility.isTrusted else { return }
        let field = FocusedField.current()
        pill.present(code, near: field.isEditable ? field.cocoaFrame : nil)
    }

    /// Apply a hotkey change and warn if the combo can't be registered (already
    /// taken by another app). Keeps the shortcut reliable for everyone.
    private func applyHotkey(code: UInt32, modifiers: UInt32, enabled: Bool) {
        guard enabled else { hotKey.unregister(); return }
        if !hotKey.reregister(keyCode: code, modifiers: modifiers) {
            let alert = NSAlert()
            alert.messageText = "That shortcut is unavailable"
            alert.informativeText = "\(KeyCombo.display(keyCode: code, carbonModifiers: modifiers)) is already used by another app. Try a different combination (something with ⌘ or ⌃)."
            alert.runModal()
        }
    }

    private func fillLatest() {
        guard Prefs.hotkeyEnabled else { return }
        guard Accessibility.isTrusted else { Accessibility.presentOnboarding(); return }
        guard let code = codeStore.latest() else { NSSound.beep(); return }
        if filler.fill(code.code) {
            codeStore.markUsed(account: code.account, messageID: code.messageID)
            pill.dismiss()
        }
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        let controller = settingsWindow ?? makeSettingsWindow()
        settingsWindow = controller
        controller.present()
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let model = SettingsModel()
        model.reloadAccounts = { [weak self] in self?.accountManager.accounts ?? [] }
        model.onAddAccount = { [weak self] in self?.showOnboarding() }
        model.onRemoveAccount = { [weak self] email in
            self?.accountManager.removeAccount(email)
        }
        model.onGrantAccessibility = { Accessibility.presentOnboarding() }
        model.applyMenuBar = { [weak self] visible in self?.statusController.setVisible(visible) }
        model.applyLogin = { on in LoginItem.setEnabled(on) }
        model.applyHotkey = { [weak self] code, mods, enabled in
            self?.applyHotkey(code: code, modifiers: mods, enabled: enabled)
        }
        return SettingsWindowController(model: model)
    }

    private func showOnboarding() {
        let model = OnboardingModel()
        model.connectIMAP = { [weak self] email, appPassword, host in
            try await self?.accountManager.addIMAPAccount(email: email, appPassword: appPassword, host: host)
        }
        model.applyHotkey = { [weak self] code, mods, enabled in
            self?.applyHotkey(code: code, modifiers: mods, enabled: enabled)
        }
        model.applyLogin = { on in LoginItem.setEnabled(on) }
        model.onFinished = { [weak self] in
            self?.onboarding?.close()
            self?.onboarding = nil
        }
        NSApp.setActivationPolicy(.regular)
        let controller = OnboardingWindowController(model: model)
        onboarding = controller
        controller.present()
    }
}
