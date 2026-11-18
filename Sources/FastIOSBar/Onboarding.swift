import AppKit
import FastIOSCore
import SwiftUI

/// First launch: what fast-ios does, a check of the Mac, and the switch.
/// Shown once; `--onboarding` shows it again.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let doneKey = "onboardingDone"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private var window: NSWindow?
    private let keepLight: KeepLight
    private let model: BarModel
    private let openMenu: () -> Void
    private let openWindow: () -> Void
    let state: OnboardingState

    init(keepLight: KeepLight, model: BarModel, fixture: OnboardingState.Fixture?, page: Int,
         openMenu: @escaping () -> Void, openWindow: @escaping () -> Void) {
        self.keepLight = keepLight
        self.model = model
        self.openMenu = openMenu
        self.openWindow = openWindow
        state = OnboardingState(fixture: fixture, page: page)
    }

    var isShowing: Bool { window?.isVisible == true }

    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func show() {
        let view = OnboardingView(state: state, keepLight: keepLight, model: model,
                                  done: { [weak self] in self?.finish(window: false) },
                                  openInWindow: { [weak self] in self?.finish(window: true) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }

    private func finish(window inWindow: Bool) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
        if inWindow { openWindow() } else { openMenu() }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early still counts as seen; the menu-bar item stays.
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }
}

/// One row of the Mac check, in plain words.
struct SetupCheck: Identifiable, Equatable {
    /// `info`: nothing to fix, but worth knowing (no simulators yet).
    enum Status { case checking, ok, info, warn, fail }
    let id: String
    var title: String
    var detail: String
    var status: Status
    /// A command to paste into Terminal, when that is the fix.
    var command: String?
    /// A button that opens something, when that is the fix.
    var action: SetupAction?

    static func == (a: SetupCheck, b: SetupCheck) -> Bool {
        a.id == b.id && a.title == b.title && a.detail == b.detail && a.status == b.status && a.command == b.command
    }
}

enum SetupAction: Equatable {
    case getXcode, openXcode

    var title: String {
        switch self {
        case .getXcode: "Get Xcode"
        case .openXcode: "Open Xcode"
        }
    }

    func perform() {
        switch self {
        case .getXcode: NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!)
        case .openXcode:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
    }
}

@MainActor
@Observable
final class OnboardingState {
    /// Canned answers for states a working Mac cannot show.
    enum Fixture: String { case checksFail = "checks-fail", loginApproval = "login-approval", finished }

    var page: Int
    var checks: [SetupCheck] = []
    var keepLightChoice = true
    var installCLI = true
    /// Off by default: the user opts in to a login item.
    var openAtLogin = false
    /// Where `fast-ios` already is on the PATH, if it is; then there is
    /// nothing to install and the row says so instead of showing a switch.
    let cliAlreadyAt: URL?
    /// After Finish: what happened to each choice.
    var applying = false
    var applied = false
    var cliResult: String?
    var cliFailed = false
    var loginState: LoginItem.State = .off
    let fixture: Fixture?

    init(fixture: Fixture?, page: Int) {
        self.fixture = fixture
        self.page = page
        cliAlreadyAt = CLIInstaller.installed
        installCLI = cliAlreadyAt == nil
        openAtLogin = false
        if fixture == .loginApproval || fixture == .finished {
            applied = true
            cliResult = "Installed as /opt/homebrew/bin/fast-ios. Type fast-ios in a new Terminal window to try it."
            loginState = fixture == .loginApproval ? .needsApproval : .on
        }
    }

    var hasBlocker: Bool { checks.contains { $0.status == .fail } }
    var canRecheck: Bool { !checks.isEmpty && !checks.contains { $0.status == .checking } && checks.contains { $0.status != .ok } }

    func runChecks() {
        if fixture == .checksFail {
            checks = [
                SetupCheck(id: "xcode", title: "Xcode is missing", detail: "fast-ios works through Xcode's simulators. Install Xcode, open it once, then check again.", status: .fail, action: .getXcode),
                SetupCheck(id: "xcode-license", title: "Agree to the Xcode licence", detail: "Simulators do not start until the licence is accepted. Paste this in Terminal; it asks for your password.", status: .fail, command: "sudo xcodebuild -license accept"),
                SetupCheck(id: "runtimes", title: "No iOS runtime yet", detail: "Simulators need one. Download it with this command, or in Xcode > Settings > Components.", status: .fail, command: "xcodebuild -downloadPlatform iOS"),
                SetupCheck(id: "simslim-watch", title: "Another tool also makes simulators light", detail: "simslim's helper is running. Keep one of them on so they do not undo each other.", status: .warn, command: "launchctl bootout gui/$(id -u)/ai.example.simslim-watch"),
            ]
            return
        }
        checks = ["xcode", "xcode-license", "runtimes", "simulators"].map {
            SetupCheck(id: $0, title: Self.checkingTitle($0), detail: "", status: .checking)
        }
        Task {
            async let doctor = Doctor.run()
            async let firstLaunch = Doctor.firstLaunchCheck()
            async let devices = try? Simctl.listDevices()
            let (d, f, list) = await (doctor, firstLaunch, devices)
            var result: [SetupCheck] = []
            for raw in d.checks + [f] {
                if let check = Self.plain(raw) { result.append(check) }
            }
            if let list { result.append(Self.simulatorsCheck(list)) }
            let order = ["xcode", "xcode-license", "runtimes", "simulators", "simslim-watch"]
            checks = result.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
        }
    }

    static func checkingTitle(_ id: String) -> String {
        switch id {
        case "xcode": "Looking for Xcode"
        case "xcode-license": "Checking the Xcode licence"
        case "runtimes": "Looking for iOS runtimes"
        default: "Counting your simulators"
        }
    }

    /// The simulators that exist now, from `simctl list devices`: not the
    /// runtimes they would run on. None is fine: the next one starts light.
    static func simulatorsCheck(_ devices: [SimDevice]) -> SetupCheck {
        let usable = devices.filter(\.isAvailable)
        guard !usable.isEmpty else {
            return SetupCheck(id: "simulators", title: "No simulators yet",
                              detail: "That is fine. Create one in Xcode under Window > Devices and Simulators. With fast-ios on, it starts light.",
                              status: .info)
        }
        let iPads = usable.filter { ($0.deviceTypeIdentifier ?? "").contains("iPad") }.count
        let iPhones = usable.filter { ($0.deviceTypeIdentifier ?? "").contains("iPhone") }.count
        var kinds: [String] = []
        if iPhones > 0 { kinds.append(iPhones == 1 ? "1 iPhone" : "\(iPhones) iPhones") }
        if iPads > 0 { kinds.append(iPads == 1 ? "1 iPad" : "\(iPads) iPads") }
        let others = usable.count - iPhones - iPads
        if others > 0 { kinds.append(others == 1 ? "1 other" : "\(others) others") }
        let title = usable.count == 1 ? "1 simulator found" : "\(usable.count) simulators found"
        return SetupCheck(id: "simulators", title: title, detail: kinds.joined(separator: ", ") + ".", status: .ok)
    }

    /// Doctor's findings, rewritten for someone who has never used a terminal.
    static func plain(_ c: DoctorCheck) -> SetupCheck? {
        let command = c.fix.flatMap(firstCommand)
        switch (c.id, c.status) {
        case ("xcode", "ok"):
            let version = c.summary.split(separator: " ").prefix(2).joined(separator: " ")
            return SetupCheck(id: c.id, title: "\(version) is ready", detail: "Simulators come from Xcode, and it is installed.", status: .ok)
        case ("xcode", _):
            if c.summary.contains("Command Line Tools") {
                return SetupCheck(id: c.id, title: "Xcode is installed but not chosen", detail: "Your Mac points at the Command Line Tools instead. Paste this in Terminal; it asks for your password.", status: .fail, command: command)
            }
            return SetupCheck(id: c.id, title: "Xcode is missing", detail: "fast-ios works through Xcode's simulators. Install Xcode, open it once, then check again.", status: .fail, action: .getXcode)
        case ("xcode-license", "ok"):
            return SetupCheck(id: c.id, title: "Xcode is set up", detail: "Its licence is accepted and its parts are installed.", status: .ok)
        case ("xcode-license", _):
            if c.summary.contains("licence") {
                return SetupCheck(id: c.id, title: "Agree to the Xcode licence", detail: "Simulators do not start until the licence is accepted. Paste this in Terminal; it asks for your password.", status: .fail, command: command, action: .openXcode)
            }
            return SetupCheck(id: c.id, title: "Let Xcode finish installing", detail: "Open Xcode once and let it install its parts, then check again.", status: .fail, command: command, action: .openXcode)
        case ("runtimes", "ok"):
            let names = c.summary.replacingOccurrences(of: "iOS runtimes: ", with: "")
            return SetupCheck(id: c.id, title: "iOS runtimes are installed", detail: names, status: .ok)
        case ("runtimes", "warn"):
            return SetupCheck(id: c.id, title: "Your iOS runtime is old", detail: "Light settings do not survive a restart on iOS older than 18.5. Download a current one.", status: .warn, command: command)
        case ("runtimes", _):
            return SetupCheck(id: c.id, title: "No iOS runtime yet", detail: "Simulators need one. Download it with this command, or in Xcode > Settings > Components.", status: .fail, command: "xcodebuild -downloadPlatform iOS")
        case ("simslim-watch", "warn"):
            return SetupCheck(id: c.id, title: "Another tool also makes simulators light", detail: "simslim's helper is running. Keep one of them on so they do not undo each other.", status: .warn, command: command)
        default:
            return nil
        }
    }

    /// The first `backticked` command in a Doctor fix line.
    static func firstCommand(_ fix: String) -> String? {
        let parts = fix.split(separator: "`", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    /// Applies the three choices, then shows what happened.
    func apply(keepLight: KeepLight) {
        guard fixture == nil else { applied = true; return }
        applying = true
        Task {
            if keepLightChoice && !keepLight.isOn {
                keepLight.set(true)
                while case .working = keepLight.phase { try? await Task.sleep(for: .milliseconds(200)) }
            }
            if installCLI && cliAlreadyAt == nil {
                do {
                    let r = try CLIInstaller.install()
                    cliResult = r.onPath
                        ? "Installed as \(r.link.path). Type fast-ios in a new Terminal window to try it."
                        : "Installed as \(r.link.path). Add \(r.link.deletingLastPathComponent().path) to your PATH to use it from Terminal."
                } catch {
                    cliFailed = true
                    cliResult = error.localizedDescription
                }
            }
            if openAtLogin {
                try? LoginItem.set(true)
            }
            loginState = LoginItem.state
            applying = false
            applied = true
        }
    }
}

// MARK: Views

struct OnboardingView: View {
    let state: OnboardingState
    let keepLight: KeepLight
    let model: BarModel
    let done: () -> Void
    let openInWindow: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.page {
                case 0: WelcomePage()
                case 1: CheckPage(state: state)
                default:
                    if state.applied {
                        DonePage(state: state, keepLight: keepLight, model: model)
                    } else {
                        SetUpPage(state: state)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            footer
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        // Switches keep their colour while another app is in front, so on
        // and off stay easy to tell apart.
        .environment(\.controlActiveState, .key)
    }

    private var footer: some View {
        HStack {
            PageDots(count: 3, current: state.page)
            Spacer()
            if state.page == 1 && state.canRecheck {
                Button("Check Again") { state.runChecks() }
            }
            if state.page > 0 && !state.applied {
                Button("Back") { go(state.page - 1) }
                    .keyboardShortcut(.cancelAction)
            }
            primary
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var primary: some View {
        switch state.page {
        case 0:
            Button("Continue") { go(1) }.keyboardShortcut(.defaultAction)
        case 1:
            Button(state.hasBlocker ? "Continue Anyway" : "Continue") { go(2) }
                .keyboardShortcut(.defaultAction)
                .disabled(state.checks.contains { $0.status == .checking })
        default:
            if state.applied {
                Button("Open in a Window", action: openInWindow)
                    .help("For when the menu bar is full and the tiger is hidden")
                Button("Show Me in the Menu Bar", action: done).keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { state.apply(keepLight: keepLight) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.applying)
            }
        }
    }

    private func go(_ page: Int) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { state.page = page }
        if page == 1 && state.checks.isEmpty { state.runChecks() }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
                .padding(.top, 44)
            VStack(spacing: 8) {
                Text("Lighter iOS simulators")
                    .font(.system(size: 26, weight: .bold))
                Text("fast-ios turns off background services that apps rarely use, on iPhone and iPad simulators, so each one needs far less memory. When an app asks for one of them, it comes back on.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 0) {
                Measurement(title: "Full", memory: "2,845 MB", processes: "277 processes", tint: .secondary)
                Divider().frame(height: 56)
                Measurement(title: "Light", memory: "829 MB", processes: "93 processes", tint: .accentColor)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: 400)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            .padding(.top, 6)
            Text("Measured on an iPhone 18 Pro simulator with iOS 27.0, 3 minutes after it started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }
}

struct Measurement: View {
    let title: String
    let memory: String
    let processes: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(tint)
            Text(memory).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(processes).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct CheckPage: View {
    let state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Checking your Mac",
                      subtitle: state.hasBlocker ? "Fix the items marked in red, then check again. Everything else is ready." : "fast-ios needs Xcode and an iOS runtime. Simulators can come later.")
            VStack(spacing: 0) {
                ForEach(Array(state.checks.enumerated()), id: \.element.id) { i, check in
                    if i > 0 { Divider().padding(.leading, 44) }
                    CheckRow(check: check)
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, 40).padding(.top, 30)
        .onAppear { if state.checks.isEmpty { state.runChecks() } }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CheckRow: View {
    let check: SetupCheck
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.body.weight(.medium))
                if !check.detail.isEmpty {
                    Text(check.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = check.command, check.status != .ok {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.background.opacity(0.7), in: .rect(cornerRadius: 6))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                if let action = check.action, check.status != .ok {
                    Button(action.title) { action.perform() }.controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch check.status {
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.title3)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.title3)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        }
    }
}

struct SetUpPage: View {
    let state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Set up fast-ios", subtitle: "You can change these later from the menu bar.")
            VStack(spacing: 0) {
                ChoiceRow(symbol: "hare.fill", title: "Keep simulators light",
                          detail: "New simulators start light. When an app asks for a service that is off, fast-ios turns it back on. macOS shows a notice that fast-ios added a background item.",
                          isOn: Binding(get: { state.keepLightChoice }, set: { state.keepLightChoice = $0 }))
                Divider().padding(.leading, 52)
                if let path = state.cliAlreadyAt {
                    ChoiceRow(symbol: "terminal", title: "Command line tool",
                              detail: "Already installed as \(path.path). Type fast-ios in Terminal to use it.",
                              isOn: nil)
                } else {
                    ChoiceRow(symbol: "terminal", title: "Install the command line tool",
                              detail: "Adds the fast-ios command for Terminal and coding agents. No password needed.",
                              isOn: Binding(get: { state.installCLI }, set: { state.installCLI = $0 }))
                }
                Divider().padding(.leading, 52)
                ChoiceRow(symbol: "power", title: "Open at login",
                          detail: "Puts the menu-bar icon back after you restart your Mac. Simulators stay light without it.",
                          isOn: Binding(get: { state.openAtLogin }, set: { state.openAtLogin = $0 }))
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            .environment(\.choicesLocked, state.applying)
            if state.applying {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Setting up").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 40).padding(.top, 30)
    }
}

/// After Finish: what each choice did, then where fast-ios lives.
struct DonePage: View {
    let state: OnboardingState
    let keepLight: KeepLight
    let model: BarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: keepLight.isOn ? "fast-ios is on" : "Setup is done",
                      subtitle: "Here is what changed.")
            VStack(alignment: .leading, spacing: 0) {
                ResultRow(title: "Keep simulators light", result: keepLightResult)
                Divider().padding(.leading, 40)
                ResultRow(title: "Command line tool", result: cliResult)
                Divider().padding(.leading, 40)
                ResultRow(title: "Open at login", result: loginResult)
                if state.openAtLogin && state.loginState == .needsApproval {
                    Button("Open Login Items") { LoginItem.openSettings() }
                        .controlSize(.small).padding(.leading, 40).padding(.bottom, 10)
                }
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            MenuBarPointer()
        }
        .padding(.horizontal, 40).padding(.top, 30)
    }

    private var keepLightResult: (ResultRow.Outcome, String) {
        if case .failed(let message, let nextStep) = keepLight.phase { return (.problem, "\(message) \(nextStep)") }
        if !keepLight.isOn { return (.off, "Off. Simulators run full. Turn it on any time from the menu bar.") }
        return (.done, KeepLightRow.summary(on: true, model: model))
    }

    private var cliResult: (ResultRow.Outcome, String) {
        if let path = state.cliAlreadyAt { return (.done, "Already installed as \(path.path).") }
        if !state.installCLI { return (.off, "Not installed. The app works without it.") }
        return (state.cliFailed ? .problem : .done, state.cliResult ?? "Installed.")
    }

    private var loginResult: (ResultRow.Outcome, String) {
        guard state.openAtLogin else { return (.off, "Off. After a restart, open fast-ios from Applications to see the icon again.") }
        switch state.loginState {
        case .on: return (.done, "On. fast-ios opens when you log in.")
        case .needsApproval: return (.problem, "macOS is waiting for you to allow it under System Settings > General > Login Items & Extensions.")
        case .off, .unavailable: return (.problem, "macOS did not add it. Move fast-ios to your Applications folder and try again from the menu bar.")
        }
    }
}

/// One line of the done page: a mark, the choice, and what happened.
struct ResultRow: View {
    enum Outcome { case done, off, problem }
    let title: String
    let result: (Outcome, String)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.font(.title3).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(result.1).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch result.0 {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .off: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}

/// A switch row with its state written beside the switch ("On" or "Off"),
/// so the two states differ in words as well as in colour. `isOn` nil: a
/// fact, not a choice (the command line tool is already installed).
struct ChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Binding<Bool>?
    @Environment(\.choicesLocked) private var locked

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let isOn {
                HStack(spacing: 8) {
                    Text(isOn.wrappedValue ? "On" : "Off")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
                        .frame(width: 26, alignment: .trailing)
                        .accessibilityHidden(true)
                    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(AccentSwitchStyle()).disabled(locked)
                        .accessibilityLabel(title)
                }
            } else {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(DotLabelStyle())
            }
        }
        .padding(12)
    }
}

/// Where the tiger is, drawn as the right end of a menu bar, and what to do
/// when it is hidden.
struct MenuBarPointer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Image(systemName: "wifi").accessibilityHidden(true)
                Image(systemName: "battery.75percent").accessibilityHidden(true)
                Group {
                    if let tiger = AppBundle.menuBarImage(filled: true) {
                        Image(nsImage: tiger).renderingMode(.template)
                    }
                }
                .frame(width: 18, height: 18)
                .padding(4)
                .background(Color.accentColor.opacity(0.25), in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1.5))
                Text("Mon 9:41").font(.callout).accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
            Text("fast-ios lives in the menu bar at the top right of your screen. Click the tiger to see your simulators and the memory saved.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Menu bar full? The tiger can hide behind the camera notch or other icons. Then open fast-ios again from Applications or Spotlight: it shows the same controls in a window.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct ChoicesLockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// After Finish the choices are fixed, but the result buttons still work.
    var choicesLocked: Bool {
        get { self[ChoicesLockedKey.self] }
        set { self[ChoicesLockedKey.self] = newValue }
    }
}
