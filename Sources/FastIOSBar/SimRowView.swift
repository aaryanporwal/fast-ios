import AppKit
import FastIOSCore
import SwiftUI

/// One simulator. Click to show its actions and what is turned off.
struct SimRowView: View {
    let row: SimRow
    let model: BarModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { model.expanded == row.id }
    private var busyNote: String? { model.busy[row.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { model.toggle(row) }
            } label: {
                summary.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(isExpanded ? "Hides actions" : "Shows actions and what is turned off")
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                RowDetail(row: row, model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(background, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .id(row.id)
        .contextMenu {
            Button("Copy UDID") { model.copyUDID(row) }
        }
    }

    private var background: some ShapeStyle {
        if isExpanded { return AnyShapeStyle(.quaternary.opacity(0.55)) }
        return AnyShapeStyle(hovering || model.selected == row.id ? Color.primary.opacity(0.06) : .clear)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            DeviceBadge(symbol: row.symbol, booted: row.device.isBooted, light: row.light.isLightNow)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.device.name).font(.body.weight(.medium)).lineLimit(1)
                if let busyNote {
                    Text(busyNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(row.device.runtimeName), \(row.lease.map { "leased by \($0.owner)" } ?? row.stateTitle)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    @ViewBuilder
    private var trailing: some View {
        if busyNote != nil {
            ProgressView().controlSize(.small)
        } else if let m = row.measurement {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Bytes.mb(m.bytes))
                    .font(.callout).monospacedDigit()
                    .contentTransition(.numericText(value: Double(m.bytes)))
                    .animation(reduceMotion ? nil : .smooth, value: m.bytes)
                Text("\(m.processes) processes")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if row.device.isBooted {
            Text("Measuring").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accessibilitySummary: String {
        var parts = [row.device.name, row.device.runtimeName, row.device.isBooted ? "running" : "shut down", row.stateTitle]
        if let lease = row.lease { parts.append("leased by \(lease.owner)") }
        if let m = row.measurement { parts.append("\(Bytes.mb(m.bytes)), \(m.processes) processes") }
        if let busyNote { parts.append(busyNote) }
        return parts.joined(separator: ", ")
    }
}

/// The device symbol in a circle: filled with the accent colour when the
/// simulator runs light, grey otherwise. Shut-down devices are dimmed.
struct DeviceBadge: View {
    let symbol: String
    let booted: Bool
    let light: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(light && booted ? Color.white : Color.primary.opacity(booted ? 0.8 : 0.5))
            .frame(width: 28, height: 28)
            .background(Circle().fill(light && booted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            .overlay(alignment: .bottomTrailing) {
                if booted {
                    Circle().fill(.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Actions, the profile and what is turned off.
struct RowDetail: View {
    let row: SimRow
    let model: BarModel
    @State private var showOff = false

    private var busy: Bool { model.busy[row.id] != nil }
    /// Running, or was running when the current action started (slimming a
    /// running simulator shuts it down for a few seconds).
    private var running: Bool { row.device.isBooted || model.booted.contains { $0.id == row.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lease = row.lease {
                Label("Leased by \(lease.owner) until \(lease.expiresAt.formatted(date: .omitted, time: .shortened)). Changing it now can break their run.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            profile
            actions
            if !row.disabled.isEmpty { whatIsOff }
        }
        .padding(.leading, 48).padding(.trailing, 12).padding(.bottom, 10)
    }

    @ViewBuilder
    private var profile: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch row.light {
            case .light where row.disabled.isEmpty:
                Text("It still runs light from before fast-ios was turned off. Its services start only when it restarts, and fast-ios makes it light again then.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .light:
                Text("\(row.disabled.count) of \(ServiceCatalog.slimmable.count) optional services off.")
                    .font(.caption).foregroundStyle(.secondary)
                if let app = row.record?.appPath {
                    Text("Keeps what \(URL(fileURLWithPath: app).lastPathComponent) needs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(app)
                } else if row.record?.profileName == "general" {
                    Text("No app known yet, so it has the general light set. When an app asks for a service that is off, fast-ios turns it back on and remembers it for that app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let kept = keptSummary {
                    Text(kept).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let repair = row.lastRepair, repairStillOn(repair) { RepairLine(event: repair) }
            case .full:
                Text("Every service runs, as Xcode set it up.").font(.caption).foregroundStyle(.secondary)
            case .lightUntilRestart:
                Text("Its services are allowed again, but it keeps running light until it restarts. Stop and start it to make it full.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .fullUntilRestart:
                Text("It started before fast-ios was on, so it runs full until it restarts. Make Light restarts it now.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One recommended action and Start or Stop; everything else is under
    /// More, so a first-time user sees two buttons.
    private var actions: some View {
        HStack(spacing: 6) {
            if row.light == .light {
                Button("Make Full") { model.makeFull(row) }
                    .fixedSize()
                    .buttonStyle(.bordered)
                    .help(running ? "Turns every service back on. The simulator restarts." : "Turns every service back on.")
            } else {
                Button("Make Light") { model.makeLight(row) }
                    .fixedSize()
                    .buttonStyle(AccentButtonStyle())
                    .help(lightHelp(model.lastProfile))
            }
            Group {
                if running {
                    Button("Stop") { model.shutDown(row) }
                } else {
                    Button("Start") { model.boot(row) }
                }
            }
            .fixedSize()
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
            moreMenu
        }
        .controlSize(.small)
        .disabled(busy)
    }

    /// Other profiles and the simulator's id.
    private var moreMenu: some View {
        let last = model.lastProfile
        return Menu {
            Section("Make Light") {
                if let last {
                    Button(last.appPath.map { "Light for \(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)" } ?? "Light with the Last Set") {
                        model.makeLight(row, profile: last)
                    }
                }
                Button("Light for an App…") { model.makeLightForChosenApp(row) }
                Button("Turn Off Every Optional Service") { model.makeLightEverythingOff(row) }
            }
            Divider()
            Button("Copy Simulator ID") { model.copyUDID(row) }
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func lightHelp(_ last: SlimProfile?) -> String {
        let what = last?.appPath.map { "keeps what \(URL(fileURLWithPath: $0).lastPathComponent) needs" } ?? "turns off every optional service"
        return "Makes this simulator light: \(what)."
    }

    /// "Kept on: Push Notifications, Photos." The optional services that are
    /// not off, by feature, so "167 of 173" says which 6 stay and why.
    private var keptSummary: String? {
        let kept = ServiceCatalog.slimmable.subtracting(row.disabled)
        guard !kept.isEmpty else { return nil }
        // The reasons the set itself gives ("push notifications", "heal
        // learned it for MyApp"); a label with none falls back to its feature.
        let reasons = row.record?.profileName == "general" ? AutoMode.generalProfile().keep : [:]
        var names: [String] = []
        for label in kept.sorted() {
            let why = reasons[label]?.first.map { $0.replacingOccurrences(of: "general profile: ", with: "") }
            let name = why ?? ServiceCatalog.categories(containing: label).first?.name ?? label
            if !names.contains(name) { names.append(name) }
        }
        return "Kept on: \(names.joined(separator: ", "))."
    }

    /// A repair line is shown only while that service is still on; once the
    /// simulator is made light again it would contradict the list below.
    private func repairStillOn(_ event: HealEvent) -> Bool {
        guard event.event != "repair-failed", let label = event.label else { return true }
        return !row.disabled.contains(label)
    }

    private var whatIsOff: some View {
        DisclosureGroup(isExpanded: $showOff) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(OffGroup.groups(for: row.disabled)) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.name).font(.caption.weight(.medium))
                            Spacer()
                            // After a repair a group is partly on: say what is on.
                            Text(group.off == group.total ? "All \(group.total) off" : "\(group.total - group.off) of \(group.total) on")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(group.downside)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("What's turned off").font(.caption.weight(.medium))
                .accessibilityLabel("What's turned off")
        }
    }
}

/// Disabled services grouped by the feature they serve.
struct OffGroup: Identifiable {
    let id: String
    let name: String
    let downside: String
    let off: Int
    let total: Int

    static func groups(for disabled: Set<String>) -> [OffGroup] {
        ServiceCatalog.categories.compactMap { c in
            let labels = Set(c.labels).intersection(ServiceCatalog.slimmable)
            let off = labels.intersection(disabled).count
            guard off > 0 else { return nil }
            return OffGroup(id: c.id, name: c.name, downside: c.downside, off: off, total: labels.count)
        }
        .sorted { ($0.off == $0.total ? 0 : 1, $0.name) < ($1.off == $1.total ? 0 : 1, $1.name) }
    }
}

/// Accent-filled, sized like a small bordered button. Unlike
/// `.borderedProminent` it stays in the accent colour while another app is
/// frontmost, which is the usual case for a menu-bar window.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
    }
}

/// "Photos & Media Analysis switched on for MyApp, 1.6 s", from the latest
/// self-repair `fast-ios heal` logged for this simulator.
struct RepairLine: View {
    let event: HealEvent

    var body: some View {
        Label(text, systemImage: failed ? "exclamationmark.triangle" : "wrench.and.screwdriver")
            .font(.caption)
            .foregroundStyle(failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .help(event.evidence ?? event.label ?? "")
    }

    private var failed: Bool { event.event == "repair-failed" }

    private var feature: String {
        guard let label = event.label else { return "A service" }
        return ServiceCatalog.categories(containing: label).first?.name ?? label
    }

    private var app: String {
        event.bundleIdentifier.split(separator: ".").last.map(String.init) ?? event.bundleIdentifier
    }

    private var when: String {
        guard let date = ISO8601DateFormatter().date(from: event.time) else { return "" }
        return ", " + date.formatted(.relative(presentation: .named))
    }

    private var text: String {
        if failed { return "Could not switch on \(feature) for \(app)\(when)." }
        let took = event.repairMs.map { ", in " + (Double($0) / 1000).formatted(.number.precision(.fractionLength(1))) + " s" } ?? ""
        return "\(feature) switched on for \(app)\(took)\(when)."
    }
}
