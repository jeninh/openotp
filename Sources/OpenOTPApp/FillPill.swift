import AppKit
import OpenOTPCore

@MainActor
final class FillPill {

    var onFill: ((DetectedCode) -> Void)?

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var current: DetectedCode?

    private let width: CGFloat = 300
    private let height: CGFloat = 56

    func present(_ code: DetectedCode, near anchor: CGRect?) {
        dismiss()
        current = code

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Screen-capture privacy: exclude the pill (which shows the raw code)
        // from all screen recording/sharing/screenshots. It stays fully visible
        // to the person at the Mac, but is a blank hole to any capture.
        panel.sharingType = Prefs.hideFromCapture ? .none : .readWrite

        panel.contentView = buildContent(code: code)
        position(panel, near: anchor)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.alphaValue = 0.85
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        current = nil
    }

    /// Spell a code out character-by-character so VoiceOver reads "4 8 3 9 2 0"
    /// rather than "four hundred eighty-three thousand…".
    private func spelledOut(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    private func buildContent(code: DetectedCode) -> NSView {
        let container = PillContainer(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("OpenOTP suggested verification code \(spelledOut(code.code)) from \(code.sender)")

        let chip = NSView(frame: NSRect(x: 12, y: (height - 34) / 2, width: 34, height: 34))
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        if let glyph = IconSet.emailCheck(size: 22, color: .labelColor) {
            let iv = NSImageView(image: glyph)
            iv.frame = NSRect(x: 6, y: 6, width: 22, height: 22)
            chip.addSubview(iv)
        }
        container.addSubview(chip)

        let codeLabel = NSTextField(labelWithString: code.code)
        codeLabel.font = .monospacedSystemFont(ofSize: 19, weight: .semibold)
        codeLabel.frame = NSRect(x: 56, y: height/2 - 2, width: 130, height: 24)
        codeLabel.setAccessibilityLabel("Code \(spelledOut(code.code))")
        container.addSubview(codeLabel)

        let caption = NSTextField(labelWithString: "Verification code")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 56, y: height/2 - 20, width: 150, height: 14)
        container.addSubview(caption)

        let fill = NSButton(title: "Fill", target: self, action: #selector(fillClicked))
        fill.bezelStyle = .rounded
        fill.keyEquivalent = "\r"
        fill.controlSize = .large
        fill.frame = NSRect(x: width - 108, y: (height - 30) / 2, width: 60, height: 30)
        fill.setAccessibilityLabel("Fill code into the focused field")
        container.addSubview(fill)

        let close = NSButton(title: "", target: self, action: #selector(closeClicked))
        close.bezelStyle = .circular
        close.isBordered = false
        if let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss") {
            let iv = x
            iv.isTemplate = true
            close.image = iv
        } else { close.title = "×" }
        close.contentTintColor = .tertiaryLabelColor
        close.frame = NSRect(x: width - 34, y: (height - 22) / 2, width: 22, height: 22)
        close.setAccessibilityLabel("Dismiss")
        container.addSubview(close)

        return container
    }

    private func position(_ panel: NSPanel, near anchor: CGRect?) {
        let size = NSSize(width: width, height: height)
        let origin: NSPoint
        if let a = anchor, a.width > 0 {
            origin = NSPoint(x: a.minX, y: a.minY - size.height - 8)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            origin = NSPoint(x: f.maxX - size.width - 20, y: f.maxY - size.height - 20)
        } else {
            origin = NSPoint(x: 200, y: 200)
        }
        panel.setFrameOrigin(origin)
    }

    @objc private func fillClicked() {
        guard let code = current else { return }
        onFill?(code)
        dismiss()
    }

    @objc private func closeClicked() { dismiss() }
}

private final class PillContainer: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        if subviews.first(where: { $0 is NSVisualEffectView }) == nil {
            let effect = NSVisualEffectView(frame: bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            addSubview(effect, positioned: .below, relativeTo: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }
}
