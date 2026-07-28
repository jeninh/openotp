import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Menu-bar app: no Dock icon by default. AppDelegate switches to .regular
    // while a window (onboarding/settings) is open, and back when it closes.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication.delegate is weak, and nothing else retains the delegate.
    // Release-mode ARC is free to deallocate it right after this assignment,
    // which tears down the status item controller (menu bar icon vanishes)
    // and every other subsystem it owns. Pin it for the app's lifetime.
    withExtendedLifetime(delegate) { app.run() }
}
