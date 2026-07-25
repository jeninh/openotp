import AppKit
import ApplicationServices

@MainActor
final class Filler {

    /// Fill `code` into the focused field by pasting it — but only after the
    /// trigger hotkey's modifier keys are released, so the synthetic ⌘V isn't
    /// turned into something else by keys you're still holding.
    ///
    /// One mechanism only. An earlier version also tried an Accessibility
    /// set-value first, but on a settable native field that wrote the code on
    /// key-down AND then pasted again on key-up (a double insert), because the
    /// AX read-back verification could fail even when the write took. A single
    /// paste is reliable across browsers, Electron, native fields, and Terminal.
    @discardableResult
    func fill(_ code: String) -> Bool {
        guard Accessibility.isTrusted else {
            Accessibility.presentOnboarding()
            return false
        }
        pasteWhenModifiersClear(code)
        return true
    }

    /// Poll until Command/Control/Option are no longer held, then paste. Falls
    /// through after a short timeout so a stuck key never blocks the fill forever.
    private func pasteWhenModifiersClear(_ code: String, attempt: Int = 0) {
        let held = NSEvent.modifierFlags.intersection([.command, .control, .option])
        if held.isEmpty || attempt >= 40 {
            paste(code)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.pasteWhenModifiersClear(code, attempt: attempt + 1)
            }
        }
    }

    private func paste(_ code: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(code, forType: .string)

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSPasteboard.general.string(forType: .string) == code {
                NSPasteboard.general.clearContents()
                if let saved { NSPasteboard.general.setString(saved, forType: .string) }
            }
        }
    }
}
