import AppKit
import ApplicationServices

enum Accessibility {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func presentOnboarding() {
        let alert = NSAlert()
        alert.messageText = "Allow OpenOTP to fill codes"
        alert.informativeText = """
        To type codes into other apps, OpenOTP needs Accessibility access.

        Click "Open Settings", enable OpenOTP under Accessibility, then try again. \
        (Copying codes from the menu never needs this.)
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            promptIfNeeded()
            openSettings()
        }
    }
}
