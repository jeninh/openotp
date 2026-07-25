import Foundation
import Carbon.HIToolbox

enum Prefs {
    private static let d = UserDefaults.standard

    static var pillEnabled: Bool {
        get { d.object(forKey: "pillEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "pillEnabled") }
    }

    static var hotkeyEnabled: Bool {
        get { d.object(forKey: "hotkeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotkeyEnabled") }
    }

    static var menuBarVisible: Bool {
        get { d.object(forKey: "menuBarVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "menuBarVisible") }
    }

    /// When on, codes never appear on any surface that can be screen-captured:
    /// the floating pill is excluded from capture (still visible to the user),
    /// and the menu — which the system draws and we can't exclude — omits the
    /// digits entirely. Secure by default.
    static var hideFromCapture: Bool {
        get { d.object(forKey: "hideFromCapture") as? Bool ?? true }
        set { d.set(newValue, forKey: "hideFromCapture") }
    }

    static var launchAtLogin: Bool {
        get { d.object(forKey: "launchAtLogin") as? Bool ?? false }
        set { d.set(newValue, forKey: "launchAtLogin") }
    }

    static var hotKeyCode: UInt32 {
        get { d.object(forKey: "hotKeyCode") as? UInt32 ?? UInt32(kVK_ANSI_V) }
        set { d.set(newValue, forKey: "hotKeyCode") }
    }

    static var hotKeyModifiers: UInt32 {
        // Default ⌃⌥V: Control-based combos are rarely claimed by apps, unlike
        // ⌘⇧V which is "Paste and Match Style" in many editors/browsers.
        get { d.object(forKey: "hotKeyModifiers") as? UInt32 ?? UInt32(controlKey | optionKey) }
        set { d.set(newValue, forKey: "hotKeyModifiers") }
    }
}
