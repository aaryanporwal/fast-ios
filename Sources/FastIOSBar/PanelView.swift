import AppKit
import FastIOSCore
import SwiftUI

/// The menu-bar window: the saved figure, then every simulator.
struct PanelView: View {
    let model: BarModel
    let keepLight: KeepLight
    /// Shown in a normal window (the icon is hidden) instead of under the icon.
    var inWindow = false
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @AppStorage(MenuBarLabel.storageKey) private var labelMode = MenuBarLabel.Mode.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The switch is in every state, so it can always be seen and changed.
            KeepLightRow(keepLight: keepLight, model: model)
            Divider().padding(.horizontal, 12)
            switch model.load {
            case .loading:
                SavingsHeader(model: model).redacted(reason: .placeholder)
                Divider().padding(.horizontal, 12)
                LoadingList()
            case .failed(let message):
                ErrorState(message: message, retry: model.retry)
            case .loaded where model.rows.isEmpty:
                EmptyState(keepLightOn: keepLight.isOn)
            case .loaded:
                SavingsHeader(model: model)
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider().padding(.horizontal, 12)
                SimulatorList(model: model)
            }
            Divider().padding(.horizontal, 12)
            Footer(labelMode: $labelMode, keepLight: keepLight)
        }
        .frame(width: 360)
        // A menu-bar window is in use whenever it is open, like Control
        // Center: draw controls active even while another app stays frontmost.
        .environment(\.controlActiveState, .key)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }
}

// MARK: Switch

/// "Keep simulators light", the same switch as `fast-ios on` and `off`.
struct KeepLightRow: View {
    let keepLight: KeepLight
    let model: BarModel

    private var working: Bool { if case .working = keepLight.phase { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: keepLight.isOn ? "hare.fill" : "hare")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(keepLight.isOn ? Color.white : Color.primary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(keepLight.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep simulators light").font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("Keep simulators light", isOn: Binding(get: { keepLight.isOn }, set: { keepLight.set($0) }))
                        .labelsHidden()
                        .disabled(keepLight.conflict != nil || !keepLight.isKnown)
                        .toggleStyle(AccentSwitchStyle(small: true))
                        .accessibilityLabel("Keep simulators light")
                        .help(keepLight.isOn ? "Turn off: simulators become full" : "Turn on: simulators become light")
                }
            }
            if case .failed(let message, let nextStep) = keepLight.phase {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: message, detail: nextStep,
                       button: ("Try Again", { keepLight.set(!keepLight.isOn) }))
            } else if let conflict = keepLight.conflict {
                Notice(symbol: "arrow.triangle.2.circlepath", tint: .orange,
                       title: "Another tool already keeps simulators light",
                       detail: "\(conflict.label) changes the same simulators, so the two would undo each other. Stop it first; fast-ios can then take over.",
                       button: ("Copy Stop Command", {
                           NSPasteboard.general.clearContents()
                           NSPasteboard.general.setString("launchctl bootout gui/$(id -u)/\(conflict.label)", forType: .string)
                       }))
            } else if keepLight.isOn && keepLight.helperPaused {
                Notice(symbol: "pause.circle.fill", tint: .orange,
                       title: "macOS paused the background helper",
                       detail: "New simulators stay full until you allow fast-ios under Login Items & Extensions.",
                       button: ("Open Login Items", { LoginItem.openSettings() }))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear { keepLight.refresh() }
    }

    private var subtitle: String {
        if case .working(let on) = keepLight.phase {
            return on ? "Turning on. Stopped simulators become light now." : "Turning off. Stopped simulators become full now."
        }
        return KeepLightRow.summary(on: keepLight.isOn, model: model)
    }

    /// The switch's state in one or two sentences, with counts from the
    /// simulator list. Also the onboarding's last screen.
    @MainActor
    static func summary(on: Bool, model: BarModel) -> String {
        let total = model.rows.count
        var parts: [String] = []
        if on {
            if total == 0 {
                parts.append("On. The next simulator you create starts light.")
            } else {
                let light = model.lightCount
                parts.append(total == 1 ? "On. \(light) of 1 simulator is light." : "On. \(light) of \(total) simulators are light.")
            }
            if let first = model.turningLight.first {
                let others = model.turningLight.count - 1
                parts.append(others == 0 ? "\(first.device.name) is running full and starts light next time."
                                         : "\(first.device.name) and \(others) more are running full and start light next time.")
            } else if total > 0 {
                parts.append("New simulators start light.")
            }
        } else {
            parts.append("Off. Simulators run full, as Xcode set them up.")
            if let first = model.turningFull.first {
                let others = model.turningFull.count - 1
                parts.append(others == 0 ? "\(first.device.name) stays light until it restarts."
                                         : "\(first.device.name) and \(others) more stay light until they restart.")
            }
        }
        return parts.joined(separator: " ")
    }
}

/// A tinted box with a title, a sentence and one button.
struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var button: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let button {
                    Button(button.0, action: button.1).controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Header

struct SavingsHeader: View {
    let model: BarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showBasis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = model.savings {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Bytes.short(s.saved))
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(s.saved)))
                        .animation(reduceMotion ? nil : .smooth, value: s.saved)
                    Text("saved").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    basisButton(s)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Bytes.short(s.saved)) saved\(isEstimate(s) ? ", estimated" : "")")
                UsageBar(current: s.current, full: s.full)
                Text(summary(s))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = changingNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showBasis {
                    Text(basisText(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        .transition(.opacity)
                }
                if s.settling {
                    Label("Settling after boot. Memory climbs for about 3 minutes, so saved will shrink a little.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(idleTitle).font(.title3.weight(.semibold))
                Text(idleDetail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private func isEstimate(_ s: Savings.Total) -> Bool {
        if case .estimated = s.source { return true }
        return false
    }

    @ViewBuilder
    private func basisButton(_ s: Savings.Total) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showBasis.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(isEstimate(s) ? "Estimate" : "Measured")
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("How the saved figure is worked out")
        .accessibilityLabel(isEstimate(s) ? "Saved figure is an estimate. Show how it is worked out." : "Saved figure is measured. Show how it is worked out.")
        .accessibilityAddTraits(showBasis ? .isSelected : [])
    }

    private func summary(_ s: Savings.Total) -> String {
        s.count == 1 ? "1 light simulator running." : "\(s.count) light simulators running."
    }

    /// Running simulators whose state changes at their next start.
    private var changingNote: String? {
        var parts: [String] = []
        if let row = model.turningFull.first {
            parts.append("\(row.device.name) runs light until it restarts, then full.")
        }
        if let row = model.runningFull.first {
            parts.append("\(row.device.name) is running full.")
        }
        if let row = model.turningLight.first {
            parts.append("\(row.device.name) runs full until it restarts, then light.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func basisText(_ s: Savings.Total) -> String {
        switch s.source {
        case .measured(let date):
            return "Saved is full minus now. The full figure was measured on this simulator while it ran full, \(date.formatted(date: .abbreviated, time: .shortened)). The fast-ios command uses the same figure."
        case .sameModel:
            return "Saved is full minus now. The full figure was measured on another simulator of the same model and iOS version while it ran full. The fast-ios command uses the same figure."
        case .estimated:
            return "Saved is full minus now. Full is \(Savings.estimateDescription). To measure your own, make a simulator full, restart it and leave it running for 3 minutes. The fast-ios command uses the same figure."
        }
    }

    private var idleTitle: String {
        model.booted.isEmpty ? "No simulators running" : "Nothing saved yet"
    }

    private var idleDetail: String {
        if let (id, note) = model.busy.first, let row = model.rows.first(where: { $0.id == id }) {
            return "\(row.device.name): \(note)"
        }
        if model.booted.isEmpty {
            return "Start one below or from Xcode. Light simulators need far less memory."
        }
        if let row = model.turningLight.first {
            return "\(row.device.name) runs full until it restarts, then light. Make it light now to restart it."
        }
        let full = model.runningFull.count
        if full > 0 {
            return full == 1 ? "1 simulator is running full. Make it light to free memory." : "\(full) simulators are running full. Make them light to free memory."
        }
        return "Measuring memory. This takes a few seconds after boot."
    }
}

/// Now against full, as one bar: the filled part is what is in use, the
/// rest is what light saves. Labelled at both ends.
struct UsageBar: View {
    let current: Int64
    let full: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let fraction = full > 0 ? min(1, Double(current) / Double(full)) : 1
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(6, geo.size.width * fraction))
                }
                .animation(reduceMotion ? nil : .smooth, value: fraction)
            }
            .frame(height: 6)
            HStack {
                Label { Text("In use \(Bytes.mb(current))") } icon: {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Spacer()
                Text("Full \(Bytes.mb(full))")
            }
            .labelStyle(DotLabelStyle())
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In use \(Bytes.mb(current)) of \(Bytes.mb(full)) a full simulator would use")
    }
}

/// A small dot beside a caption, closer than the default label spacing.
struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// MARK: List

struct SimulatorList: View {
    let model: BarModel
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    section("Running", model.booted)
                    section("Stopped", model.shutDown)
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
            // Arrow keys pick a row and Return or Space opens it, with or
            // without Full Keyboard Access, as in the system menus.
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onKeyPress(keys: [.return, .space]) { _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { model.toggleSelected() }
                return .handled
            }
            .onChange(of: model.selected) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { focused = true }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [SimRow]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                SimRowView(row: row, model: model)
            }
        }
    }
}

struct LoadingList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Running").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    Circle().fill(.quaternary).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iPhone 18 Pro").font(.body.weight(.medium))
                        Text("iOS 27.0, Light for an app").font(.caption)
                    }
                    Spacer()
                    Text("829 MB")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .redacted(reason: .placeholder)
        .padding(.horizontal, 6).padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading simulators")
    }
}

// MARK: States

struct EmptyState: View {
    let keepLightOn: Bool

    /// Xcode's Simulator app, inside whichever Xcode macOS knows about.
    static var simulatorApp: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") { return url }
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { return nil }
        let url = xcode.appendingPathComponent("Contents/Developer/Applications/Simulator.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No simulators yet").font(.headline)
            Text(keepLightOn
                 ? "Create one in Xcode under Window > Devices and Simulators. It appears here and starts light."
                 : "Create one in Xcode under Window > Devices and Simulators. It appears here. Turn on the switch above to make it light before it starts.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let app = Self.simulatorApp {
                Button("Open Simulator") { NSWorkspace.shared.open(app) }
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.orange)
            Text("Can't read your simulators").font(.headline)
            Text("fast-ios gets the list from Xcode, and Xcode did not answer. Check that Xcode is installed and chosen in Xcode > Settings > Locations, then try again.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            HStack {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.medium))
                Text(banner.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Footer

struct Footer: View {
    @Binding var labelMode: MenuBarLabel.Mode
    let keepLight: KeepLight

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Menu Bar Shows", selection: $labelMode) {
                    ForEach(MenuBarLabel.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Options", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")
            // Only when fast-ios was pointed at another simulator folder
            // (--set or FASTIOS_DEVICE_SET); Xcode's own simulators show nothing.
            if let set = Simctl.deviceSet {
                Text("Simulators from \(URL(fileURLWithPath: set).lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(set)
            }
            Spacer()
            Button("Quit") { QuitFlow.quit(keepLight: keepLight) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// A switch that is the accent colour when on and grey when off, also while
/// another app is in front (the system switch turns grey then, so on and off
/// look alike). Same size as the system's small and regular switches;
/// Space toggles it when focused, and VoiceOver reads it as a switch.
struct AccentSwitchStyle: ToggleStyle {
    var small = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let width: CGFloat = small ? 32 : 40
        let height: CGFloat = small ? 18 : 22
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(configuration.isOn ? 0 : 0.12), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // A button that VoiceOver reads as a switch; callers give the label
        // with .accessibilityLabel, as the visible label is hidden.
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}
