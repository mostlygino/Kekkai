import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case apps, destinations, activity, map, rules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .destinations: "Destinations"
        case .activity: "Activity"
        case .map: "Map"
        case .rules: "Rules"
        }
    }

    var icon: String {
        switch self {
        case .apps: "square.stack.3d.up"
        case .destinations: "point.3.connected.trianglepath.dotted"
        case .activity: "list.bullet.below.rectangle"
        case .map: "globe.europe.africa"
        case .rules: "checklist"
        }
    }
}

struct ContentView: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @SceneStorage("pane") private var pane: Pane = .apps
    @State private var search = ""
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("onboardingDone") private var onboardingDone = false

    @ViewBuilder
    private func paneView(_ p: Pane) -> some View {
        switch p {
        case .apps: AppsPane(search: search)
        case .destinations: DestinationsPane(search: search)
        case .activity: ActivityPane(search: search)
        case .map: MapPane()
        case .rules: RulesPane()
        }
    }

    private var showOnboarding: Bool { filter.state != .on && !store.watching && store.apps.isEmpty }

    var body: some View {
        NavigationSplitView {
            Sidebar(pane: $pane)
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: 220, max: 280)
        } detail: {
            // Every pane stays built; switching only changes which one is visible. Tearing a pane's AppKit tables
            // and forms down inside the split view's detail column ran a move transition through AppKit's layout
            // and looped it ("more Update Constraints in Window passes than there are views"). Nothing is
            // inserted or removed here after the first frame, so that path is never taken.
            ZStack {
                ForEach(Pane.allCases) { p in
                    paneView(p)
                        .environment(\.paneActive, p == pane && !showOnboarding)
                        .opacity(p == pane && !showOnboarding ? 1 : 0)
                        .allowsHitTesting(p == pane && !showOnboarding)
                        .accessibilityHidden(p != pane || showOnboarding)
                }
                if showOnboarding { OnboardingView() }
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            // Floats over the pane (an overlay, not an inset: it must never change the detail column's size).
            .overlay(alignment: .bottom) {
                if !showOnboarding && pane != .rules { PendingFirewallBar().padding(.bottom, 26).padding(.horizontal, 16) }
            }
            .navigationTitle(showOnboarding ? "Kekkai" : pane.title)
            // Attached here, outside the pane switch, so the modifier is never removed while it animates.
            // Same presentation on every pane: showing and hiding the column on a pane switch changed the window's
            // minimum width mid-layout and sent AppKit into its Update Constraints loop.
            .inspector(isPresented: Binding(get: { showInspector && !showOnboarding },
                                            set: { showInspector = $0 })) {
                // Both stay built, for the same reason as the panes: swapping them on a pane switch went through
                // the same AppKit layout loop.
                ZStack {
                    OverviewInspector()
                        .environment(\.paneActive, pane != .apps && showInspector)
                        .opacity(pane != .apps ? 1 : 0)
                        .allowsHitTesting(pane != .apps)
                    Group {
                        if let key = store.inspectedApp, let traffic = store.apps[key] {
                            AppInspector(traffic: traffic)
                        } else {
                            GardenEmpty(title: "No app selected", symbol: "sidebar.trailing",
                                        message: "Select an app to see its signature, rule and destinations.")
                        }
                    }
                    .opacity(pane == .apps ? 1 : 0)
                    .allowsHitTesting(pane == .apps)
                }
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .inspectorColumnWidth(min: Layout.inspectorMin, ideal: 320, max: 420)
            }
            // A fixed minimum for the detail column. Without it the column's minimum followed each pane's content,
            // and NavigationSplitView re-ran constraints on every switch until AppKit gave up (NSGenericException).
            .frame(minWidth: Layout.detailMin, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Apps, hosts, addresses")
        // One toolbar for every pane. Pane-specific toolbar items made AppKit re-layout the toolbar on every switch,
        // which looped next to the search field and crashed (NSGenericException, too many Update Constraints passes).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StatusPill()
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .disabled(showOnboarding)
                    .help(showInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        // The welcome is its own window, not a sheet: a sheet made the app ignore Quit while it was open.
        .task {
            // First use: welcome once the main window is on screen (plain demo runs have their own flags).
            try? await Task.sleep(for: .milliseconds(450))
            if Demo.welcome || (!Demo.isOn && !onboardingDone) { openWindow(id: "welcome") }
        }
        .onChange(of: store.welcomeRequested) { _, asked in
            if asked { openWindow(id: "welcome"); store.welcomeRequested = false }
        }
        .onChange(of: store.requestedPane) { _, p in
            if let p { pane = p; store.requestedPane = nil }
        }
        .onChange(of: store.requestedSearch) { _, s in
            if let s { search = s; store.requestedSearch = nil }
        }
        .onAppear {
            if let p = store.requestedPane { pane = p; store.requestedPane = nil }
            if let s = store.requestedSearch { search = s; store.requestedSearch = nil }
            PaletteActions.openSettings = { openSettings(); NSApp.activate() }
            PaletteActions.openAbout = { openWindow(id: "about"); NSApp.activate() }
            PanelOpener.openApprovals = { openWindow(id: "approvals") }
            AppDelegate.openMain = { openWindow(id: "main"); NSApp.activate() }
        }
        .task {
            // After scene storage has restored, so the demo flag wins.
            if let p = Demo.pane { try? await Task.sleep(for: .milliseconds(300)); pane = p }
            if Demo.tour {
                // Self-report for scripted runs: where every window is, so a missing one shows up in the log.
                for w in NSApp.windows {
                    NSLog("Kekkai tour window id=%@ visible=%d activeSpace=%d frame=%@ screen=%@",
                          w.identifier?.rawValue ?? "-", w.isVisible, w.isOnActiveSpace,
                          NSStringFromRect(w.frame), w.screen.map { NSStringFromRect($0.frame) } ?? "none")
                }
                for look in [NSAppearance.Name.darkAqua, .aqua] {
                    NSApp.appearance = NSAppearance(named: look)
                    for p in Pane.allCases {
                        pane = p
                        try? await Task.sleep(for: .seconds(3))
                    }
                    // The surfaces outside the main window, each for three seconds.
                    openWindow(id: "about")
                    try? await Task.sleep(for: .seconds(3))
                    dismissWindow(id: "about")
                    openWindow(id: "demo-menubar")
                    try? await Task.sleep(for: .seconds(3))
                    dismissWindow(id: "demo-menubar")
                    CommandPalette.shared.show(query: look == .darkAqua ? "" : "goo")
                    try? await Task.sleep(for: .seconds(3))
                    CommandPalette.shared.close()
                }
                openSettings()
                // Scripted runs end themselves, so nothing has to kill them.
                try? await Task.sleep(for: .seconds(4))
                NSApp.terminate(nil)
            }
        }
        // Size budget, kept in one place: sidebar min + detail min + inspector min, plus slack for dividers.
        // Every pane's content must fit `Layout.detailMin`; a minimum the window can't meet loops AppKit's layout.
        .frame(minWidth: Layout.sidebarMin + Layout.detailMin + Layout.inspectorMin + 20, minHeight: 560)
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Environment(\.store) private var store
    @Binding var pane: Pane

    var body: some View {
        List(selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) {
            Section {
                ForEach([Pane.apps, .destinations, .activity, .map]) { p in
                    Label(p.title, systemImage: p.icon)
                        .badge(badge(for: p))
                        .tag(p)
                }
            }
            Section("Barrier") {
                Label(Pane.rules.title, systemImage: Pane.rules.icon)
                    .badge(store.rules.domains.count + store.rules.apps.count)
                    .tag(Pane.rules)
            }
        }
        .safeAreaInset(edge: .bottom) { StatusFooter().padding(14) }
    }

    private func badge(for pane: Pane) -> Int {
        switch pane {
        case .apps: store.apps.count
        case .destinations: Set(store.apps.values.flatMap { $0.destinations.keys }).count
        default: 0
        }
    }
}

struct StatusFooter: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BarrierMark(on: filter.state == .on && store.connected, size: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if store.watching && filter.state != .on { return "Watching" }
        return switch filter.state {
        case .on where store.connected: store.isDemo ? "Demo traffic" : "Barrier up"
        case .on: "Connecting"
        case .off: "Barrier down"
        case .checking: "Checking"
        case .installing: "Installing"
        case .needsUserApproval: "Needs your approval"
        case .failed: "Couldn't start"
        }
    }

    private var detail: String {
        if store.watching && filter.state != .on { return "Live connections from macOS. Nothing is blocked." }
        switch filter.state {
        case .on where store.connected:
            if let since = store.resumedFrom {
                return "\(store.rules.mode.title) mode. History since \(since.formatted(date: .abbreviated, time: .shortened))."
            }
            return "\(store.rules.mode.title) mode."
        case .on: return "The filter is on. Waiting for the extension to answer."
        case .off: return "Traffic is not inspected."
        case .checking: return "Reading the filter configuration."
        case .installing: return "macOS is installing the extension."
        case .needsUserApproval: return "Allow Kekkai in System Settings, General, Login Items & Extensions."
        case .failed(let message): return message
        }
    }
}

// MARK: Toolbar

struct ModePicker: View {
    @Environment(\.store) private var store

    var body: some View {
        Picker("Mode", selection: Binding(get: { store.rules.mode }, set: { m in store.update { $0.mode = m } })) {
            ForEach(FilterMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!store.connected)
        .help(store.rules.mode.summary)
    }
}

/// The whole state of the barrier in one place: a pill in the toolbar that says what is happening
/// ("Watching", "Block List", "Barrier down"), with the controls in a popover. Replaces a mode menu that sat
/// disabled whenever the filter wasn't running.
struct StatusPill: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @State private var open = false

    private var up: Bool { filter.state == .on && store.connected }

    private var title: String {
        if up { return store.rules.mode.title }
        if store.watching { return "Watching" }
        switch filter.state {
        case .on: return "Connecting"
        case .installing, .checking: return "Starting"
        case .needsUserApproval: return "Needs approval"
        default: return "Barrier down"
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                BarrierMark(on: up, size: 15)
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            // A fixed width: the label changes, the toolbar layout must not.
            .frame(width: 150, alignment: .leading)
        }
        .help("Barrier status and controls")
        .popover(isPresented: $open, arrowEdge: .bottom) { StatusPopover() }
        .accessibilityLabel("Barrier: \(title)")
    }
}

private struct StatusPopover: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @AppStorage("watchMode") private var watchMode = false

    var body: some View {
        let up = filter.state == .on && store.connected
        VStack(alignment: .leading, spacing: 14) {
            StatusFooter()
            Divider()
            if up {
                Picker("Mode", selection: Binding(get: { store.rules.mode }, set: { m in store.update { $0.mode = m } })) {
                    ForEach(FilterMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title)
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Button("Lower the Barrier") { filter.turnOff() }
            } else {
                if filter.state == .needsUserApproval {
                    Button("Open System Settings") { FilterControl.openExtensionSettings() }.buttonStyle(.borderedProminent)
                } else if FilterControl.canLoadFilter {
                    Button("Raise the Barrier") { filter.turnOn() }.buttonStyle(.borderedProminent).tint(Color.shu)
                }
                Toggle("Watch connections without the filter", isOn: Binding(get: { store.watching }, set: { on in
                    watchMode = on
                    on ? Watcher.shared.start(store) : Watcher.shared.stop()
                }))
                Button {
                    store.show(.rules)
                } label: {
                    Label("Block with the System Firewall…", systemImage: "lock.shield")
                }
                .buttonStyle(.link)
                if !FilterControl.canLoadFilter {
                    Text("This copy of Kekkai isn't signed by a developer team, so macOS won't load its filter. Watching and the system firewall work without it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter

    private func startWatching() {
        UserDefaults.standard.set(true, forKey: "watchMode")
        Watcher.shared.start(store)
    }

    private var filterSteps: some View {
        VStack(spacing: 0) {
            Step(number: 1, title: "Turn on the filter",
                 detail: "Kekkai installs a network extension. macOS asks for your password.",
                 done: [.needsUserApproval, .on].contains(filter.state)) {
                if filter.state == .installing { ProgressView().controlSize(.small) }
                else { Button("Turn On") { filter.turnOn() }.buttonStyle(.borderedProminent).tint(Color.shu) }
            }
            Divider().padding(.leading, 52)
            Step(number: 2, title: "Allow it in System Settings",
                 detail: "General, Login Items & Extensions, Network Extensions.",
                 done: filter.state == .on) {
                Button("Open Settings") { FilterControl.openExtensionSettings() }
                    .disabled(filter.state != .needsUserApproval)
            }
            Divider().padding(.leading, 52)
            Step(number: 3, title: "Choose how strict",
                 detail: "Block List suits most people. Require Approval asks before any new app connects.",
                 done: false) {
                ModePicker()
            }
        }
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
        .frame(maxWidth: 560)
    }

    private var watchInstead: some View {
        VStack(spacing: 8) {
            Button { startWatching() } label: {
                Label("Watch Without the Filter", systemImage: "eye").frame(minWidth: 220)
            }
            .controlSize(.large)
            Text("See which apps connect where, right now. Nothing is blocked, and hostnames need the filter.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
                    .padding(.top, 36)
                VStack(spacing: 10) {
                    Text("Raise the barrier")
                        .font(.garden(.largeTitle))
                    Text("Kekkai shows every app that talks to the network, where it goes, and stops the ones you don't trust. Everything stays on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }

                if FilterControl.canLoadFilter {
                    filterSteps
                    watchInstead
                } else {
                    // Builds without a developer team can't load the filter: lead with what works.
                    HStack(alignment: .top, spacing: 14) {
                        Choice(symbol: "eye", title: "Watch your Mac",
                               detail: "See every app that connects, where to and how much, live. Nothing is blocked.",
                               action: "Start Watching", prominent: true) { startWatching() }
                        Choice(symbol: "lock.shield", title: "Block on this Mac",
                               detail: "Block domains and addresses for every app with macOS's own firewall. Asks for your password.",
                               action: "Set Up Blocking", prominent: false) { startWatching(); store.show(.rules) }
                    }
                    .frame(maxWidth: 620)
                    Text("Blocking one app at a time and asking before new apps connect need Kekkai's network filter, which only loads in a copy signed by a developer team.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }

                if case .failed(let message) = filter.state {
                    Label {
                        Text("\(message) Builds without a signing team can't load the extension; see the README.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.callout)
                    .foregroundStyle(Color.shu)
                    .frame(maxWidth: 560, alignment: .leading)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background { RakedGround(center: .init(x: 0.5, y: 0.16)) }
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                StoneShape().stroke(done ? Color.shu : Color.secondary.opacity(0.5), lineWidth: 1.5)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.shu)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.garden(.headline))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
    }
}

/// The inspector on panes without a selection: today at a glance.
struct OverviewInspector: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.paneActive) private var active
    @State private var frozen = Frozen()

    var body: some View {
        let t = frozen.keep("totals", live: active) { store.totals }
        let countries = frozen.keep("countries", live: active) {
            Dictionary(store.destinations.compactMap { d in d.country.map { ($0, d.connections) } }, uniquingKeysWith: +)
        }
            .sorted { $0.value > $1.value }.prefix(5)
        let busiest = store.apps.values.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }.prefix(5)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    BarrierMark(on: filter.state == .on && store.connected, size: 22, lineWidth: 1.8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Overview").font(.garden(.title2))
                        Text(store.watching && filter.state != .on ? "Watching, nothing blocked" : "\(store.rules.mode.title) mode")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    stat("Apps", store.apps.count.formatted())
                    stat("Connections", t.connections.formatted())
                    stat("Blocked", t.blocked.formatted(), tint: t.blocked > 0 ? .shu : nil)
                    stat("Sent", bytes(t.bytesOut))
                    stat("Received", bytes(t.bytesIn))
                }
                if !busiest.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Busiest Apps").font(.garden(.headline))
                        ForEach(Array(busiest)) { a in
                            HStack(spacing: 8) {
                                Image(nsImage: a.app.icon).resizable().frame(width: 18, height: 18)
                                Text(a.app.title).lineLimit(1)
                                Spacer()
                                Text(bytes(a.bytesIn + a.bytesOut)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                if !countries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Countries").font(.garden(.headline))
                        ForEach(Array(countries), id: \.key) { cc, n in
                            HStack {
                                Text(GeoIP.name(for: cc)).lineLimit(1)
                                Spacer()
                                Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
        .font(.callout)
    }
}

/// The main window's width budget. Table column minimums in each pane add up to well under `detailMin`.
enum Layout {
    static let sidebarMin: CGFloat = 200
    static let detailMin: CGFloat = 560
    static let inspectorMin: CGFloat = 280
}

/// One of the two ways in, on the start screen of a build that can't load the filter.
private struct Choice: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let prominent: Bool
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(prominent ? Color.shu : .secondary)
                .frame(height: 28)
            Text(title).font(.garden(.title3))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if prominent {
                Button(action, action: run).buttonStyle(.borderedProminent).tint(Color.shu).controlSize(.large)
            } else {
                Button(action, action: run).controlSize(.large)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }
}

/// Without the filter, blocking from Apps, Destinations or ⌘K only edits the Block List. This bar says when the
/// list and what this Mac enforces differ, and applies it in one click.
struct PendingFirewallBar: View {
    @Environment(\.store) private var store
    @State private var fw = SystemFirewall.shared

    var body: some View {
        let plan = SystemFirewallPlan(rules: store.rules, seenHosts: store.seenHosts)
        let show = !store.connected && (store.watching || fw.applied != nil) && !fw.isCurrent(plan)
            && !(plan.isEmpty && fw.applied == nil)
        if show {
            HStack(spacing: 12) {
                Image(systemName: fw.clearedByRestart ? "arrow.clockwise.circle" : "lock.shield")
                    .foregroundStyle(Color.ask)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fw.clearedByRestart ? "A restart cleared the address blocks" : "Your Block List isn't on this Mac yet")
                        .font(.callout.weight(.semibold))
                    Text(fw.clearedByRestart ? "Name blocks are still in place." : "Apply it to block for every app. macOS asks for your password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Review") { store.show(.rules) }
                Button(fw.busy ? "Applying…" : "Apply…") { Task { await fw.apply(plan) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.shu)
                    .disabled(fw.busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
