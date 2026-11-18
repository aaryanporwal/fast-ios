import AppKit
import FastIOSCore
import Observation
import SwiftUI

/// The menu-bar item and the window under it. An NSStatusItem plus a
/// borderless panel, instead of SwiftUI's MenuBarExtra, so the window can be
/// opened from code (`--open-menu`) and the label can carry live text.
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    let model: BarModel
    let keepLight = KeepLight()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var hosting: NSView?
    private var outsideClick: Any?
    /// `--keep-open`: clicks elsewhere do not close the window (for tests).
    var keepOpen = false

    init(model: BarModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown])
            button.imagePosition = .imageLeading
        }
        item.behavior = []
        updateLabel()
        keepLight.afterChange = { [weak model] in await model?.refresh() }
        QuitFlow.beforeAlert = { [weak self] in
            self?.close()
            self?.window?.close()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.render(MenuBarLabel.content(model: self.model, mode: MenuBarLabel.mode))
            }
        }
    }

    // MARK: Label

    /// Redraws the label now and again whenever what it reads changes.
    private func updateLabel() {
        withObservationTracking {
            render(MenuBarLabel.content(model: model, mode: MenuBarLabel.mode))
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    private func render(_ content: MenuBarLabel.Content) {
        guard let button = item.button else { return }
        button.image = AppBundle.menuBarImage(filled: content.symbol == "hare.fill")
        if let text = content.text {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [.font: font])
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(content.accessibility)
        button.toolTip = content.accessibility
    }

    /// Draws the label for `mode` the way the status button shows it (same
    /// symbol, text and font) on a light or dark strip, for docs. The menu
    /// bar can hide the real item behind the notch, so it is not captured.
    func labelSnapshot(mode: MenuBarLabel.Mode, dark: Bool) -> NSBitmapImageRep? {
        let content = MenuBarLabel.content(model: model, mode: mode)
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.image = AppBundle.menuBarImage(filled: content.symbol == "hare.fill")
        button.contentTintColor = dark ? .white : .black
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.attributedTitle = NSAttributedString(string: content.text.map { " " + $0 } ?? "",
                                                    attributes: [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black])
        button.sizeToFit()
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 24, height: 24))
        strip.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        button.setFrameOrigin(NSPoint(x: 12, y: (24 - button.frame.height) / 2))
        strip.addSubview(button)
        guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return nil }
        strip.cacheDisplay(in: strip.bounds, to: rep)
        return rep
    }

    // MARK: Panel

    @objc func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = hosting?.fittingSize ?? NSSize(width: 360, height: 400)
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // The shadow follows the rounded glass only once it has drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { panel.invalidateShadow() }
        button.highlight(true)
        guard !keepOpen else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        let wasOpen = panel?.isVisible == true
        panel?.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        if wasOpen && window?.isVisible != true { model.panelClosed() }
    }

    // MARK: Hidden icon

    /// The menu-bar icon can be seen: it is on a screen, not under the
    /// camera notch, and its window is not covered. A full menu bar on a
    /// notched Mac puts new icons under the notch, and menu-bar managers
    /// move hidden ones off screen. An icon covered by another app's
    /// window cannot be detected; the onboarding's window button covers it.
    var iconIsVisible: Bool {
        guard item.isVisible, let button = item.button, let window = button.window,
              let screen = window.screen else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard rect.width > 0, screen.frame.contains(rect) else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Both areas are set only on a screen with a notch; between them is the notch.
            let l = left.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            let r = right.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            if !(l.insetBy(dx: -1, dy: -1).contains(rect) || r.insetBy(dx: -1, dy: -1).contains(rect)) { return false }
        }
        return true
    }

    /// Opening fast-ios again (Finder, Spotlight, Launchpad, `open -a`):
    /// the window under the icon when the icon can be seen, else a normal
    /// window with the same contents, as menu-bar apps such as Ice and
    /// Rectangle open a window when launched again.
    func openAnywhere() {
        let visible = iconIsVisible
        if ProcessInfo.processInfo.environment["FASTIOSBAR_DEBUG"] != nil {
            print("fastiosbar open-anywhere icon-visible=\(visible) rect=\(statusItemRectTopLeft.map { "\($0)" } ?? "none")")
            fflush(stdout)
        }
        if visible { open() } else { showWindow() }
        if ProcessInfo.processInfo.environment["FASTIOSBAR_DEBUG"] != nil {
            if let n = panelWindowNumber { print("fastiosbar panel-window \(n)") }
            if let n = windowNumber { print("fastiosbar window \(n)") }
            fflush(stdout)
        }
    }

    private var window: NSWindow?

    /// The same contents as the menu-bar window, in a normal titled window.
    func showWindow() {
        close()
        if window == nil {
            let host = NSHostingController(rootView: PanelView(model: model, keepLight: keepLight, inWindow: true))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "fast-ios"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("fast-ios window")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    /// The status item's frame in screen points from the top-left, the
    /// space `screencapture -R` takes.
    var statusItemRectTopLeft: CGRect? {
        guard let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.screens.first else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    var panelWindowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: PanelView(model: model, keepLight: keepLight, onHeightChange: { [weak self] height in self?.fit(height: height) }))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting
        let radius: CGFloat = 16
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            // Dense text needs a steadier backdrop than clear glass gives
            // over a busy desktop; the system colour keeps light and dark.
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8)
            glass.contentView = hosting
            container = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .menu
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: blur.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            container = blur
        }
        // A clear root view, so the window's corners outside the rounded
        // material stay transparent and the shadow follows the rounded shape.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        return panel
    }

    /// Follows the content's height as rows expand, keeping the top edge fixed.
    private func fit(height: CGFloat) {
        guard let panel, panel.isVisible, abs(height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        // An open panel (NSOpenPanel) takes key; keep the window then.
        if !keepOpen, NSApp.modalWindow == nil, NSApp.keyWindow == nil { close() }
    }
}

/// A borderless panel that can become key (for keyboard navigation) and
/// closes on Escape.
final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
