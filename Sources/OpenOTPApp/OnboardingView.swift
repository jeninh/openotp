import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class OnboardingModel: ObservableObject {
    var connectIMAP: ((String, String, String) async throws -> Void)?
    var applyHotkey: ((UInt32, UInt32, Bool) -> Void)?
    var applyLogin: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
}

private enum Step: Int, CaseIterable {
    case welcome, connect, accessibility, shortcut, ready
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var step: Step = .welcome
    @State private var connected = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
            Divider()
            footer
        }
        .frame(width: 540, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.ink)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .connect: ConnectStep(model: model, onConnected: { connected = true; advance() })
        case .accessibility: AccessibilityStep()
        case .shortcut: CustomizeStep(model: model)
        case .ready: ReadyStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }.buttonStyle(.borderless)
            }
            Spacer()
            StepDots(count: Step.allCases.count, index: step.rawValue)
            Spacer()
            rightButton
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    @ViewBuilder private var rightButton: some View {
        switch step {
        case .connect:
            Button("Continue") { advance() }.buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white).disabled(!connected)
        case .ready:
            Button("Get Started") { model.onFinished?() }.buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white)
        default:
            Button("Continue") { advance() }.buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white)
        }
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.18)) { step = next }
        }
    }
    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            withAnimation(.easeInOut(duration: 0.18)) { step = prev }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: AppIcon.image(size: 128))
                .resizable().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            Text("Welcome to OpenOTP").font(.system(size: 24, weight: .bold))
            Text("Your email verification codes, autofilled on your Mac —\nprivate, local, and no server involved.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "email-check", text: "Codes surface in your menu bar the moment they land")
                FeatureRow(icon: "bolt-circle-fill", text: "One shortcut fills it into the focused field")
                FeatureRow(icon: "private-outline", text: "Read locally — nothing leaves your Mac")
            }
            .padding(.top, 6)
            Spacer()
        }
    }
}

private struct ConnectStep: View {
    @ObservedObject var model: OnboardingModel
    var onConnected: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            StepHeader(title: "Connect your email", subtitle: "Pick how OpenOTP should read your inbox.")
            ConnectPicker(model: model, onConnected: onConnected)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }
}

private struct AccessibilityStep: View {
    @State private var trusted = Accessibility.isTrusted
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconBadge(system: "private-outline", size: 72)
            Text("Allow code filling").font(.system(size: 22, weight: .bold))
            Text("To type codes into other apps, OpenOTP needs macOS Accessibility access —\nthe same permission Raycast and Alfred use. Copying never needs it.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)

            if trusted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                Button("Open Accessibility Settings") { Accessibility.presentOnboarding() }
                    .buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white)
                Text("You can also do this later — the app will ask when you first fill a code.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .onReceive(timer) { _ in trusted = Accessibility.isTrusted }
    }
}

private struct CustomizeStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var keyCode = Prefs.hotKeyCode
    @State private var mods = Prefs.hotKeyModifiers
    @State private var pill = Prefs.pillEnabled
    @State private var login = Prefs.launchAtLogin

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            IconBadge(system: "bolt-circle-fill", size: 64)
            Text("Set it up your way").font(.system(size: 22, weight: .bold))
            Text("You can change all of this later in Settings.")
                .font(.system(size: 13)).foregroundStyle(.secondary)

            VStack(spacing: 14) {
                HStack {
                    Text("Fill shortcut")
                    Spacer()
                    KeyRecorder(keyCode: $keyCode, carbonModifiers: $mods) { code, m in
                        Prefs.hotKeyCode = code; Prefs.hotKeyModifiers = m
                        model.applyHotkey?(code, m, Prefs.hotkeyEnabled)
                    }
                    .frame(width: 150, height: 28)
                }
                Divider()
                Toggle("Floating fill pill", isOn: $pill)
                    .onChange(of: pill) { v in Prefs.pillEnabled = v }
                Toggle("Launch at login", isOn: $login)
                    .onChange(of: login) { v in Prefs.launchAtLogin = v; model.applyLogin?(v) }
            }
            .padding(16)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            Spacer(minLength: 0)
        }
    }
}

private struct ReadyStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconBadge(system: "check-circle-fill", size: 84)
            Text("You're all set").font(.system(size: 24, weight: .bold))
            Text("OpenOTP is watching your inbox. When a code arrives you'll get a\nmenu-bar entry and a floating fill button.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Look for the envelope icon in your menu bar.")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            Spacer()
        }
    }
}

// MARK: - Connect picker (Gmail / Other)

private enum ConnectMethod { case none, gmail, other }

private struct ConnectPicker: View {
    @ObservedObject var model: OnboardingModel
    var onConnected: () -> Void
    @State private var method: ConnectMethod = .none

    var body: some View {
        switch method {
        case .none:
            VStack(spacing: 12) {
                MethodCard(title: "Gmail", badge: "Recommended", subtitle: "Connect Gmail with an app password. About a minute.", icon: "email-check") { method = .gmail }
                MethodCard(title: "Connect other email", badge: nil, subtitle: "iCloud, Outlook, Fastmail, or any IMAP provider.", icon: "email-fill") { method = .other }
            }
        case .gmail:
            IMAPForm(model: model, gmail: true, back: { method = .none }, onConnected: onConnected)
        case .other:
            IMAPForm(model: model, gmail: false, back: { method = .none }, onConnected: onConnected)
        }
    }
}

private struct IMAPForm: View {
    @ObservedObject var model: OnboardingModel
    let gmail: Bool
    var back: () -> Void
    var onConnected: () -> Void
    @State private var email = ""
    @State private var appPassword = ""
    @State private var host = ""
    @State private var showServer = false
    @State private var busy = false
    @State private var error: String?

    private var steps: [StepItem] {
        gmail ? [
            StepItem(1, "Turn on 2-Step Verification, then create an app password named “OpenOTP”.", ("Open Google App Passwords", "https://myaccount.google.com/apppasswords")),
            StepItem(2, "Enter your Gmail address and the 16-character app password.", nil),
        ] : [
            StepItem(1, "Turn on IMAP access in your provider's settings.", nil),
            StepItem(2, "Enable 2-step verification and create an app-specific password.", nil),
            StepItem(3, "Enter your email and app password. Server auto-detects.", nil),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackLink(action: back)
            StepList(steps: steps)
            TextField(gmail ? "you@gmail.com" : "you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .onChange(of: email) { _ in if !gmail && !showServer { host = IMAPProvider.guessHost(for: email) } }
                .onAppear { if gmail { host = "imap.gmail.com" } }
            SecureField("app password", text: $appPassword).textFieldStyle(.roundedBorder)
            Button(showServer ? "Hide server" : "Server: \(host.isEmpty ? "auto" : host)") {
                showServer.toggle(); if host.isEmpty { host = IMAPProvider.guessHost(for: email) }
            }.buttonStyle(.link).font(.caption)
            if showServer { TextField("IMAP server", text: $host).textFieldStyle(.roundedBorder) }
            if !gmail && host != "imap.gmail.com" {
                Button("Is this a Google Workspace address? Use Gmail's server") {
                    host = "imap.gmail.com"; showServer = true
                }.buttonStyle(.link).font(.caption)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button { Task { await connect() } } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.borderedProminent).tint(.black).foregroundStyle(.white).disabled(busy || email.isEmpty || appPassword.isEmpty)
            }
        }
    }

    private func connect() async {
        busy = true; error = nil
        do {
            let h = host.isEmpty ? IMAPProvider.guessHost(for: email) : host
            try await model.connectIMAP?(email.trimmingCharacters(in: .whitespaces),
                                         appPassword.replacingOccurrences(of: " ", with: ""),
                                         h.trimmingCharacters(in: .whitespaces))
            onConnected()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}

// MARK: - Small components

private struct StepItem: Identifiable {
    let n: Int; let text: String; let link: (String, String)?
    init(_ n: Int, _ text: String, _ link: (String, String)?) { self.n = n; self.text = text; self.link = link }
    var id: Int { n }
}

private struct StepList: View {
    let steps: [StepItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps) { s in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(s.n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        if let link = s.link {
                            Button(link.0) { if let u = URL(string: link.1) { NSWorkspace.shared.open(u) } }
                                .buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct MethodCard: View {
    let title: String; let badge: String?; let subtitle: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(system: icon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if let badge {
                            Text(badge).font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)
                        }
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

private struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 12) {
            IconBadge(system: icon, size: 26)
            Text(text).font(.system(size: 13))
            Spacer()
        }
    }
}

private struct IconBadge: View {
    let system: String; let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.ink)
            .frame(width: size, height: size)
            .overlay(Glyph(name: system, size: size * 0.72, color: Theme.paper))
    }
}

private struct StepHeader: View {
    let title: String; let subtitle: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

private struct StepDots: View {
    let count: Int; let index: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

private struct BackLink: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) { Label("Back", systemImage: "chevron.left").font(.system(size: 12)) }
            .buttonStyle(.borderless)
    }
}
