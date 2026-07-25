import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsModel: ObservableObject {
    @Published var pillEnabled = Prefs.pillEnabled
    @Published var hotkeyEnabled = Prefs.hotkeyEnabled
    @Published var menuBarVisible = Prefs.menuBarVisible
    @Published var hideFromCapture = Prefs.hideFromCapture
    @Published var launchAtLogin = Prefs.launchAtLogin
    @Published var hotKeyCode = Prefs.hotKeyCode
    @Published var hotKeyModifiers = Prefs.hotKeyModifiers
    @Published var accounts: [String] = []
    @Published var accessibilityTrusted = Accessibility.isTrusted

    var reloadAccounts: (() -> [String])?
    var onAddAccount: (() -> Void)?
    var onRemoveAccount: ((String) -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var applyHotkey: ((UInt32, UInt32, Bool) -> Void)?
    var applyMenuBar: ((Bool) -> Void)?
    var applyLogin: ((Bool) -> Void)?

    func refresh() {
        accounts = reloadAccounts?() ?? []
        accessibilityTrusted = Accessibility.isTrusted
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ABOUT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        GitHubCard()
                    }
                    if !model.accessibilityTrusted { accessibilityBanner }
                    generalCard
                    shortcutCard
                    accountsCard
                    footer
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.ink)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: AppIcon.image(size: 64))
                .resizable().frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenOTP").font(.system(size: 20, weight: .semibold))
                Text("Email one-time codes, on your Mac")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Glyph(name: "private-outline", size: 22, color: Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable code filling").font(.callout.weight(.medium))
                Text("OpenOTP needs Accessibility to type codes into other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Enable…") { model.onGrantAccessibility?(); model.refresh() }
                .buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillStrong))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private var generalCard: some View {
        Card(title: "General") {
            SettingRow(icon: "email-fill",
                       title: "Menu-bar icon", subtitle: "Show the OpenOTP icon in the menu bar") {
                Toggle("", isOn: $model.menuBarVisible).labelsHidden()
                    .onChange(of: model.menuBarVisible) { v in Prefs.menuBarVisible = v; model.applyMenuBar?(v) }
            }
            Divider()
            SettingRow(icon: "check-circle-fill",
                       title: "Floating pill", subtitle: "Show a floating fill button when a code arrives") {
                Toggle("", isOn: $model.pillEnabled).labelsHidden()
                    .onChange(of: model.pillEnabled) { v in Prefs.pillEnabled = v }
            }
            Divider()
            SettingRow(icon: "private-outline",
                       title: "Hide codes from screen recording",
                       subtitle: "Codes stay visible to you but never appear in screen shares, recordings, or screenshots") {
                Toggle("", isOn: $model.hideFromCapture).labelsHidden()
                    .onChange(of: model.hideFromCapture) { v in Prefs.hideFromCapture = v }
            }
            Divider()
            SettingRow(icon: "play-circle-fill",
                       title: "Launch at login", subtitle: "Start OpenOTP automatically") {
                Toggle("", isOn: $model.launchAtLogin).labelsHidden()
                    .onChange(of: model.launchAtLogin) { v in Prefs.launchAtLogin = v; model.applyLogin?(v) }
            }
        }
    }

    private var shortcutCard: some View {
        Card(title: "Fill Shortcut") {
            SettingRow(icon: "bolt-circle-fill",
                       title: "Global shortcut", subtitle: "Types the latest code into the focused field") {
                Toggle("", isOn: $model.hotkeyEnabled).labelsHidden()
                    .onChange(of: model.hotkeyEnabled) { v in
                        Prefs.hotkeyEnabled = v
                        model.applyHotkey?(model.hotKeyCode, model.hotKeyModifiers, v)
                    }
            }
            Divider()
            HStack {
                Text("Shortcut").foregroundStyle(model.hotkeyEnabled ? .primary : .secondary)
                Spacer()
                KeyRecorder(keyCode: $model.hotKeyCode, carbonModifiers: $model.hotKeyModifiers) { code, mods in
                    Prefs.hotKeyCode = code; Prefs.hotKeyModifiers = mods
                    model.applyHotkey?(code, mods, model.hotkeyEnabled)
                }
                .frame(width: 150, height: 28)
                .opacity(model.hotkeyEnabled ? 1 : 0.5)
                .disabled(!model.hotkeyEnabled)
            }
            .padding(.horizontal, 4)
        }
    }

    private var accountsCard: some View {
        Card(title: "Connected Accounts") {
            if model.accounts.isEmpty {
                Text("No accounts connected.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            } else {
                ForEach(Array(model.accounts.enumerated()), id: \.element) { i, email in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        Glyph(name: "badge-check-fill", size: 16, color: Theme.ink)
                        Text(email)
                        Spacer()
                        Button("Remove") { model.onRemoveAccount?(email); model.refresh() }
                            .buttonStyle(.borderless).foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Divider()
            }
            Button { model.onAddAccount?() } label: {
                HStack(spacing: 6) {
                    Glyph(name: "plus-fill", size: 14, color: Theme.ink)
                    Text("Add email account…")
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("OpenOTP · reads your Gmail locally, nothing leaves your Mac")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.chipRadius)
                .fill(Theme.fill)
                .frame(width: 28, height: 28)
                .overlay(Glyph(name: icon, size: 21, color: Theme.ink))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var carbonModifiers: UInt32
    var onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.keyCode = keyCode; v.carbonModifiers = carbonModifiers
        v.onCapture = { code, mods in keyCode = code; carbonModifiers = mods; onCapture(code, mods) }
        return v
    }
    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.keyCode = keyCode; nsView.carbonModifiers = carbonModifiers; nsView.needsDisplay = true
    }
}

final class RecorderNSView: NSView {
    var keyCode: UInt32 = 0
    var carbonModifiers: UInt32 = 0
    var onCapture: ((UInt32, UInt32) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true; window?.makeFirstResponder(self); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
        guard KeyCombo.hasRequiredModifiers(mods) else { NSSound.beep(); return }
        keyCode = UInt32(event.keyCode); carbonModifiers = mods
        recording = false
        onCapture?(keyCode, carbonModifiers); needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? "Type shortcut…" : KeyCombo.display(keyCode: keyCode, carbonModifiers: carbonModifiers)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .semibold),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }
}
