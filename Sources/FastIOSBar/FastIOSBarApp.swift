import AppKit
import FastIOSCore

@main
@MainActor
enum FastIOSBarMain {
    static func main() {
        let app = NSApplication.shared
        // A menu-bar app: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        let options = LaunchOptions(CommandLine.arguments)
        options.applyAppearance()
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    var controller: StatusController?
    var onboarding: OnboardingController?

    init(options: LaunchOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusController(model: BarModel(fixture: options.fixture))
        controller.keepOpen = options.keepOpen
        self.controller = controller
        if options.openMenu { DebugHooks.openSoon(controller) }
        if options.showWindow { DebugHooks.showWindowSoon(controller) }
        if let dir = options.labelDir { DebugHooks.writeLabels(controller, to: dir) }
        if options.showOnboarding || (!OnboardingController.isDone && options.fixture == nil && !options.openMenu && !options.showWindow) {
            let onboarding = OnboardingController(keepLight: controller.keepLight, model: controller.model,
                                                  fixture: options.onboardingFixture, page: options.onboardingPage,
                                                  openMenu: { [weak controller] in controller?.openAnywhere() },
                                                  openWindow: { [weak controller] in controller?.showWindow() })
            self.onboarding = onboarding
            onboarding.show()
            if options.showOnboarding {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if let n = onboarding.windowNumber { print("fastiosbar onboarding-window \(n)"); fflush(stdout) }
                }
            }
        }
    }

    /// Opening the app again while it runs: show it, under the icon or in a
    /// window when the icon is hidden (see StatusController.openAnywhere).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let onboarding, onboarding.isShowing {
            onboarding.bringToFront()
        } else {
            controller?.openAnywhere()
        }
        return false
    }
}

/// What the menu-bar item shows: the memory saved now, the number of slim
/// simulators, or the symbol alone. Only the outlined symbol while no slim
/// simulator is running.
enum MenuBarLabel {
    enum Mode: String, CaseIterable, Identifiable {
        case saved, count, icon
        var id: String { rawValue }
        var title: String {
            switch self {
            case .saved: "Memory Saved"
            case .count: "Light Simulators Running"
            case .icon: "Icon Only"
            }
        }
    }

    struct Content: Equatable {
        var symbol: String
        var text: String?
        var accessibility: String
    }

    static let storageKey = "menuBarShows"

    static var mode: Mode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Mode.init(rawValue:)) ?? .saved
    }

    @MainActor
    static func content(model: BarModel, mode: Mode) -> Content {
        let slim = model.runningLight.count
        let savings = model.savings
        var text: String?
        switch mode {
        case .saved: if let savings, savings.saved > 0 { text = Bytes.short(savings.saved) }
        case .count: if slim > 0 { text = "\(slim)" }
        case .icon: break
        }
        let sims = slim == 1 ? "1 light simulator" : "\(slim) light simulators"
        let spoken: String
        if slim == 0 { spoken = "fast-ios, no light simulators running" }
        else if let savings { spoken = "fast-ios, about \(Bytes.short(savings.saved)) saved by \(sims)" }
        else { spoken = "fast-ios, \(sims) running" }
        return Content(symbol: slim > 0 ? "hare.fill" : "hare", text: text, accessibility: spoken)
    }
}

/// Flags for checking the design without clicking:
/// `--fixture loading|empty|error`, `--appearance light|dark`, `--open-menu`,
/// `--keep-open`, `--label-snapshots <dir>`, `--onboarding`,
/// `--onboarding-page <0-2>`, `--fixture checks-fail|login-approval|finished`.
struct LaunchOptions {
    var fixture: Fixture?
    var appearance: String?
    var openMenu = false
    var keepOpen = false
    var labelDir: String?
    var showOnboarding = false
    /// `--show-window`: the panel in a normal window, as when the icon is hidden.
    var showWindow = false
    var onboardingPage = 0
    var onboardingFixture: OnboardingState.Fixture?

    init(_ args: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        fixture = value("--fixture").flatMap(Fixture.init(rawValue:))
        appearance = value("--appearance")
        openMenu = args.contains("--open-menu")
        keepOpen = args.contains("--keep-open")
        labelDir = value("--label-snapshots")
        showOnboarding = args.contains("--onboarding")
        showWindow = args.contains("--show-window")
        onboardingPage = value("--onboarding-page").flatMap(Int.init) ?? 0
        onboardingFixture = value("--fixture").flatMap(OnboardingState.Fixture.init(rawValue:))
    }

    @MainActor
    func applyAppearance() {
        switch appearance {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

/// Canned states for the ones that are hard to reach on a working Mac.
enum Fixture: String {
    case loading, empty, error
    /// Live data plus the banner a failed action shows.
    case banner

    var isLive: Bool { self == .banner }

    @MainActor
    func apply(to model: BarModel) {
        switch self {
        case .loading: model.load = .loading
        case .empty: model.load = .loaded
        case .error:
            model.load = .failed("xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")
        case .banner:
            model.banner = Banner(title: "Could not boot iPhone 17e",
                                  detail: "Unable to boot device because it cannot be located on disk.")
        }
    }
}

/// Opens the menu-bar window after launch and prints its window number, so
/// `screencapture -l` can take real screenshots of it.
@MainActor
enum DebugHooks {
    /// After the first refresh, writes the menu-bar label in each mode as
    /// `label-<mode>-<light|dark>.png`.
    static func writeLabels(_ controller: StatusController, to dir: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            for mode in MenuBarLabel.Mode.allCases {
                for dark in [false, true] {
                    guard let png = controller.labelSnapshot(mode: mode, dark: dark)?.representation(using: .png, properties: [:]) else { continue }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("label-\(mode.rawValue)-\(dark ? "dark" : "light").png")
                    try? png.write(to: url)
                    print("fastiosbar label \(url.path)")
                }
            }
            fflush(stdout)
        }
    }

    static func showWindowSoon(_ controller: StatusController) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            controller.showWindow()
            try? await Task.sleep(for: .seconds(0.5))
            if let number = controller.windowNumber { print("fastiosbar window \(number)") }
            print("fastiosbar icon-visible \(controller.iconIsVisible)")
            fflush(stdout)
        }
    }

    static func openSoon(_ controller: StatusController) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            controller.open()
            try? await Task.sleep(for: .seconds(0.5))
            if let number = controller.panelWindowNumber { print("fastiosbar panel-window \(number)") }
            if let rect = controller.statusItemRectTopLeft {
                print("fastiosbar status-rect \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
            }
            fflush(stdout)
        }
    }
}
