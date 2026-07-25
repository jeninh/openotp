import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up OpenOTP"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 600))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
