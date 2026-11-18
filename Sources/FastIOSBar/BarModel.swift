import AppKit
import FastIOSCore
import Observation

/// Light or full, from the simulator's real state. A running simulator keeps
/// the services it started with until it restarts, so the switch and the
/// buttons can change what it becomes without changing what it is now.
enum LightStatus: Equatable {
    case light
    case full
    /// Running light, but it comes back full at its next start (the switch
    /// was turned off while it ran).
    case lightUntilRestart
    /// Running full, but it starts light next time (the switch was turned on
    /// while it ran).
    case fullUntilRestart

    /// What it uses now: the state the memory figure belongs to.
    var isLightNow: Bool { self == .light || self == .lightUntilRestart }
}

/// One simulator as the menu shows it.
struct SimRow: Identifiable, Hashable {
    let device: SimDevice
    /// Optional services turned off right now: the running launchd's own list
    /// when the simulator is running, else the overrides it will start with.
    let disabled: Set<String>
    let light: LightStatus
    let record: FastIOSState.DeviceRecord?
    let measurement: SimMeasurement?
    /// Seconds since boot, when booted.
    let bootAge: TimeInterval?
    /// Who holds this simulator through `fast-ios lease`, if anyone.
    var lease: Lease? = nil
    /// The latest service fast-ios switched back on (or failed to) for an app
    /// on this simulator, from repairs.jsonl.
    var lastRepair: HealEvent? = nil

    var id: String { device.udid }
    /// Light now or from its next start: the row's actions offer Make Full.
    var hasLightSettings: Bool { light == .light || light == .fullUntilRestart }
    /// Memory keeps rising for about three minutes after boot.
    var isSettling: Bool { (bootAge ?? .infinity) < Savings.settleSeconds }

    var symbol: String {
        let type = device.deviceTypeIdentifier ?? ""
        if type.contains("iPad") { return "ipad" }
        if type.contains("Watch") { return "applewatch" }
        if type.contains("Apple-TV") { return "appletv" }
        if type.contains("Vision") { return "vision.pro" }
        return "iphone"
    }

    /// "Light for MyApp", "Light, general set", "Full", "Full after it restarts".
    var stateTitle: String {
        switch light {
        case .full: return "Full"
        // Short enough for the row; the header and the details say what follows.
        case .lightUntilRestart: return "Light until it restarts"
        case .fullUntilRestart: return "Full until it restarts"
        case .light: break
        }
        // Nothing is off in its launchd, yet it runs light: `off` allowed its
        // services while it ran and they have not started (see RowDetail).
        if disabled.isEmpty { return "Light" }
        guard let name = record?.profileName else { return "Light, set by another tool" }
        if name.hasPrefix("auto: ") {
            let app = String(name.dropFirst(6))
            return "Light for \(app.hasSuffix(".app") ? String(app.dropLast(4)) : app)"
        }
        if name == "full" { return "Light, every optional service off" }
        if name == "general" { return "Light, general set" }
        return "Light, \(name) set"
    }
}

/// What the menu should show above the list.
enum LoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

struct Banner: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor
@Observable
final class BarModel {
    var rows: [SimRow] = []
    var load: LoadState = .loading
    /// Device id -> what is running on it right now, shown in the row.
    var busy: [String: String] = [:]
    var banner: Banner?
    var expanded: String?
    /// Saved across running light simulators, from FastIOSCore's `Savings`,
    /// the same rule and the same full sizes `fast-ios` prints. nil when no
    /// running light simulator has been measured.
    private(set) var savings: Savings.Total?
    private var poller: Task<Void, Never>?
    /// Set by `--fixture`: the model shows canned data and never polls.
    let fixture: Fixture?

    init(fixture: Fixture? = nil) {
        self.fixture = fixture
        if let fixture {
            fixture.apply(to: self)
            if !fixture.isLive { return }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Reading

    func refresh() async {
        guard fixture?.isLive ?? true else { return }
        let devices: [SimDevice]
        do {
            devices = try await Simctl.listDevices()
        } catch {
            if rows.isEmpty { load = .failed(error.localizedDescription) }
            return
        }
        let available = devices.filter(\.isAvailable)
        let state = StateStore.load()
        let leases = LeaseStore.readOnly()
        let pending = PendingLight.load()
        var repairs: [String: HealEvent] = [:]
        for event in HealStore.repairs(limit: 200) { repairs[event.udid] = event }
        let booted = available.filter(\.isBooted).map(\.udid)
        async let mem = Measure.many(booted)
        async let ages = Measure.bootAge(booted)
        async let liveSets = Self.liveDisabled(booted)
        let (memory, age, live) = await (mem, ages, liveSets)

        var observations: [Savings.Observation] = []
        let next = available.map { d -> SimRow in
            let diskAll = DisabledStore.disabledLabels(d.udid)
            let onDisk = diskAll.intersection(ServiceCatalog.slimmable)
            let running = live[d.udid].map { $0.intersection(ServiceCatalog.slimmable) }
            let status: LightStatus
            if d.isBooted {
                let o = Savings.Observation(d, diskDisabled: diskAll, liveDisabled: live[d.udid],
                                            measurement: memory[d.udid], bootAge: age[d.udid], state: state)
                observations.append(o)
                if let running, !running.isEmpty {
                    status = .light
                } else if o.startedBeforeMadeFull() {
                    // `off` allowed its services while it ran; they start
                    // only at its next start. With the switch on again it is
                    // pending and starts light, so it stays light throughout.
                    status = pending.contains(d.udid) ? .light : .lightUntilRestart
                } else if running == nil, !onDisk.isEmpty {
                    status = .light  // its launchd did not answer: what it started with
                } else if pending.contains(d.udid) || !onDisk.isEmpty {
                    status = .fullUntilRestart
                } else {
                    status = .full
                }
            } else {
                status = onDisk.isEmpty ? .full : .light
            }
            return SimRow(device: d, disabled: running ?? onDisk, light: status,
                          record: state.devices[d.udid], measurement: memory[d.udid], bootAge: age[d.udid],
                          lease: leases[d.udid], lastRepair: repairs[d.udid])
        }
        // A simulator that is really full is measured on the way, so its own
        // full size replaces the estimate (FastIOSCore decides what counts).
        var store = BaselineStore.load()
        if store.record(observations) { try? store.save() }
        savings = Savings.total(observations.compactMap { Savings.saving(for: $0, store: store) })
        rows = next
        load = .loaded
    }

    /// The running launchd's disabled list for each simulator, as `fast-ios`
    /// reads it (`LightState`); a simulator that does not answer is left out.
    nonisolated static func liveDisabled(_ udids: [String]) async -> [String: Set<String>] {
        await withTaskGroup(of: (String, Set<String>?).self) { group in
            for udid in udids { group.addTask { (udid, await LightState.liveDisabled(udid)) } }
            var out: [String: Set<String>] = [:]
            for await (udid, set) in group { if let set { out[udid] = set } }
            return out
        }
    }

    /// A row keeps its section while an action on it runs (making a running
    /// simulator light restarts it), so it does not jump.
    private var bootedWhenStarted: [String: Bool] = [:]
    private func listedAsRunning(_ row: SimRow) -> Bool { bootedWhenStarted[row.id] ?? row.device.isBooted }

    var booted: [SimRow] { rows.filter(listedAsRunning) }
    var shutDown: [SimRow] { rows.filter { !listedAsRunning($0) } }

    // MARK: Counts (the one place every count in the app comes from)

    /// Simulators that are light now, running or stopped, a still-light one
    /// included. The same count as "Simulators: N, M light" in `fast-ios`.
    var lightCount: Int { rows.filter(\.light.isLightNow).count }
    var runningLight: [SimRow] { booted.filter(\.light.isLightNow) }
    /// Running full now and staying full.
    var runningFull: [SimRow] { booted.filter { $0.light == .full } }
    /// Running full now, light from the next start.
    var turningLight: [SimRow] { booted.filter { $0.light == .fullUntilRestart } }
    /// Running light now, full from the next start.
    var turningFull: [SimRow] { booted.filter { $0.light == .lightUntilRestart } }

    // MARK: Actions

    func toggle(_ row: SimRow) {
        expanded = expanded == row.id ? nil : row.id
        selected = row.id
    }

    /// The panel opens with every row closed, as a menu does.
    func panelClosed() {
        expanded = nil
        selected = nil
    }

    /// The row the arrow keys have reached.
    var selected: String?

    /// Up and down arrows, in the order the list shows the rows.
    func moveSelection(_ step: Int) {
        let order = (booted + shutDown).map(\.id)
        guard !order.isEmpty else { return }
        guard let current = selected, let i = order.firstIndex(of: current) else {
            selected = step > 0 ? order.first : order.last
            return
        }
        selected = order[min(max(i + step, 0), order.count - 1)]
    }

    func toggleSelected() {
        guard let row = rows.first(where: { $0.id == selected }) else { return }
        toggle(row)
    }

    /// The set "Make Light" uses: the one fast-ios last read from an app,
    /// else every optional service off.
    var lastProfile: SlimProfile? { StateStore.load().defaultProfile }

    func makeLight(_ row: SimRow, profile: SlimProfile? = nil) {
        let chosen = profile ?? lastProfile ?? Profiler.full()
        let note = row.device.isBooted ? "Making it light. The simulator restarts." : "Making it light."
        run(row, note: note, failure: "Could not make \(row.device.name) light") { device in
            _ = try await Slimmer.slim(device, profile: chosen)
        }
    }

    func makeLightEverythingOff(_ row: SimRow) { makeLight(row, profile: Profiler.full()) }

    /// Asks for an app, reads what it needs, remembers it and makes the
    /// simulator light for it.
    func makeLightForChosenApp(_ row: SimRow) {
        let panel = NSOpenPanel()
        panel.title = "Choose your app"
        panel.message = "Pick a simulator .app, its Build/Products folder or the project folder."
        panel.prompt = "Make Light"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // FASTIOSBAR_PICK answers the panel in automated tests.
        let picked: URL?
        if let path = ProcessInfo.processInfo.environment["FASTIOSBAR_PICK"] {
            picked = URL(fileURLWithPath: path)
        } else {
            NSApp.activate()
            picked = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url = picked else { return }
        run(row, note: "Reading the app.", failure: "Could not make \(row.device.name) light for that app") { [weak self] device in
            let app = try AppInspector.locateApp(url.path)
            let facts = try await AppInspector.inspect(app)
            let profile = Profiler.derive(from: facts).profile
            try StateStore.update { $0.defaultProfile = profile }
            await MainActor.run {
                self?.busy[device.udid] = device.isBooted ? "Making it light. The simulator restarts." : "Making it light."
            }
            _ = try await Slimmer.slim(device, profile: profile)
        }
    }

    func makeFull(_ row: SimRow) {
        let note = row.device.isBooted ? "Making it full. The simulator restarts." : "Making it full."
        run(row, note: note, failure: "Could not make \(row.device.name) full") { device in
            _ = try await Slimmer.restore(device)
        }
    }

    func boot(_ row: SimRow) {
        let note = row.light == .full ? "Starting. Its memory figure appears once it is up." : "Starting light. Its memory figure appears once it is up."
        run(row, note: note, failure: "Could not start \(row.device.name)") { device in
            try await Simctl.bootAndWait(device.udid)
        }
    }

    func shutDown(_ row: SimRow) {
        run(row, note: "Stopping.", failure: "Could not stop \(row.device.name)") { device in
            try await Simctl.shutdownAndWait(device.udid)
        }
    }

    func copyUDID(_ row: SimRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.device.udid, forType: .string)
    }

    func retry() {
        load = .loading
        Task { await refresh() }
    }

    private func run(_ row: SimRow, note: String, failure: String,
                     _ work: @escaping @Sendable (SimDevice) async throws -> Void) {
        guard busy[row.id] == nil else { return }
        busy[row.id] = note
        bootedWhenStarted[row.id] = row.device.isBooted
        banner = nil
        Task {
            do {
                try await work(row.device)
            } catch {
                banner = Banner(title: failure, detail: error.localizedDescription)
            }
            // Refresh before clearing the spinner, so the row never shows the
            // state from before the action.
            await refresh()
            busy[row.id] = nil
            bootedWhenStarted[row.id] = nil
        }
    }
}
