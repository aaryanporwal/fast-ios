import AppKit

/// Quit says once that the background helper keeps running, and offers to
/// turn it off too. After that first time, Quit just quits.
@MainActor
enum QuitFlow {
    static let explainedKey = "quitExplained"
    /// Closes the menu-bar window before the alert, set by StatusController.
    static var beforeAlert: () -> Void = {}

    enum Choice { case keepLight, turnOff, cancel }

    static func quit(keepLight: KeepLight) {
        guard keepLight.isOn, !UserDefaults.standard.bool(forKey: explainedKey) else {
            NSApp.terminate(nil)
            return
        }
        beforeAlert()
        switch ask() {
        case .cancel:
            return
        case .keepLight:
            UserDefaults.standard.set(true, forKey: explainedKey)
            NSApp.terminate(nil)
        case .turnOff:
            UserDefaults.standard.set(true, forKey: explainedKey)
            Task {
                await keepLight.change(false)
                NSApp.terminate(nil)
            }
        }
    }

    static func ask() -> Choice {
        let alert = NSAlert()
        alert.messageText = "Keep simulators light after you quit?"
        alert.informativeText = "The menu-bar icon goes away, but fast-ios keeps running in the background and new simulators still start light. To make simulators full again, turn it off too."
        alert.addButton(withTitle: "Quit and Keep Light")
        alert.addButton(withTitle: "Turn Off and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepLight
        case .alertSecondButtonReturn: return .turnOff
        default: return .cancel
        }
    }
}
