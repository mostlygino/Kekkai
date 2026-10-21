import SwiftUI

// MARK: Scope bar

/// Time range and "blocked only", shared by the traffic panes. Lives in the content, not the toolbar:
/// pane-specific toolbar items sent AppKit into a constraint loop (see MainWindow).
struct ScopeBar<Trailing: View>: View {
    @Environment(\.store) private var store
    @AppStorage("timeScope") private var scope: TimeScope = .day
    @AppStorage("blockedOnly") private var blockedOnly = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Picker("Time", selection: $scope) {
                ForEach(TimeScope.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            // Watch mode can't block, so there is nothing to narrow down to.
            if !store.watching || store.connected {
                // A filter chip: neutral when off, filled shu when on, so its state is never ambiguous.
                Button {
                    blockedOnly.toggle()
                } label: {
                    Label("Blocked Only", systemImage: blockedOnly ? "xmark.octagon.fill" : Verdict.block.symbol)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(blockedOnly ? Color.white : Color.secondary)
                        .background(blockedOnly ? AnyShapeStyle(Color.shu) : AnyShapeStyle(.quaternary), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.18), value: blockedOnly)
                .help("Show only apps and destinations with blocked connections")
                .accessibilityAddTraits(blockedOnly ? .isSelected : [])
            }
            Spacer()
            trailing
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

extension ScopeBar where Trailing == EmptyView {
    init() { trailing = EmptyView() }
}

private func number(_ n: Int) -> some View { Text(n, format: .number).monospacedDigit() }

private func matches(_ search: String, _ fields: String?...) -> Bool {
    let q = search.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
}

// MARK: Apps

/// One row in the Apps outline: an app, or one of its destinations.
struct TrafficRow: Identifiable {
    enum Kind { case app(AppTraffic), destination(Destination, appKey: String) }
    let kind: Kind
    var id: String {
        switch kind {
        case .app(let a): a.id
        case .destination(let d, let key): key + "→" + d.id
        }
    }
    var name: String {
        switch kind {
        case .app(let a): a.app.title
        case .destination(let d, _): d.name
        }
    }
    var connections: Int { switch kind { case .app(let a): a.connections; case .destination(let d, _): d.connections } }
    var blocked: Int { switch kind { case .app(let a): a.blocked; case .destination(let d, _): d.blocked } }
    var bytesIn: UInt64 { switch kind { case .app(let a): a.bytesIn; case .destination(let d, _): d.bytesIn } }
    var bytesOut: UInt64 { switch kind { case .app(let a): a.bytesOut; case .destination(let d, _): d.bytesOut } }
    var lastSeen: Date { switch kind { case .app(let a): a.lastSeen; case .destination(let d, _): d.lastSeen } }
    var total: UInt64 { bytesIn + bytesOut }
    var appKey: String { switch kind { case .app(let a): a.id; case .destination(_, let key): key } }
}

struct AppsPane: View {
    @Environment(\.store) private var store
    @Environment(\.paneActive) private var active
    @State private var frozen = Frozen()
    let search: String
    @AppStorage("timeScope") private var scope: TimeScope = .day
    @AppStorage("blockedOnly") private var blockedOnly = false
    @AppStorage("showInspector") private var showInspector = true
    @State private var selection: TrafficRow.ID?
    @State private var expanded: Set<String> = []
    @State private var order = [KeyPathComparator(\TrafficRow.lastSeen, order: .reverse)]

    var body: some View {
        let apps = frozen.keep("apps", live: active) {
            store.apps(in: scope, blockedOnly: blockedOnly).filter { a in
                matches(search, a.app.title, a.app.path, a.app.signingID)
                    || a.destinations.values.contains { d in matches(search, d.name) || d.ips.contains { matches(search, $0) } }
            }
        }
        let rows = apps.map { TrafficRow(kind: .app($0)) }.sorted(using: order)

        VStack(spacing: 0) {
            TrafficChart(samples: frozen.keep("samples", live: active) { store.samples })
                .frame(height: 148)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            ScopeBar {
                Text(apps.count == 1 ? "1 app" : "\(apps.count) apps").foregroundStyle(.secondary).monospacedDigit()
            }
            Divider()
            Table(of: TrafficRow.self, selection: $selection, sortOrder: $order) {
                TableColumn("App", value: \.name) { row in
                    switch row.kind {
                    case .app(let a): AppCell(traffic: a)
                    case .destination(let d, _): DestinationCell(destination: d)
                    }
                }
                .width(min: 140, ideal: 160)
                TableColumn("Connections", value: \.connections) { number($0.connections) }.width(min: 80, ideal: 82)
                TableColumn("Blocked", value: \.blocked) { r in number(r.blocked).foregroundStyle(r.blocked > 0 ? Color.shu : .secondary) }
                    .width(min: 56, ideal: 56)
                TableColumn("Data", value: \.total) { DataCell(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }.width(min: 118, ideal: 124)
                TableColumn("Seen", value: \.lastSeen) { r in
                    // No timer per row: the table redraws whenever traffic arrives, which refreshes this.
                    Text(ago(r.lastSeen)).monospacedDigit().foregroundStyle(.secondary)
                        .help(r.lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                .width(min: 52, ideal: 54)
            } rows: {
                ForEach(rows) { row in
                    if case .app(let a) = row.kind {
                        DisclosureTableRow(row, isExpanded: Binding(
                            get: { expanded.contains(row.id) || !search.isEmpty },
                            set: { if $0 { expanded.insert(row.id) } else { expanded.remove(row.id) } })) {
                            ForEach(a.destinations.values.map { TrafficRow(kind: .destination($0, appKey: a.id)) }.sorted(using: order)) {
                                TableRow($0)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never, axes: .horizontal)
            .contextMenu(forSelectionType: TrafficRow.ID.self) { ids in
                if let id = ids.first, let row = find(id, in: apps) {
                    switch row.kind {
                    case .app(let a): AppActions(app: a.app)
                    case .destination(let d, _): DestinationActions(destination: d)
                    }
                }
                Divider()
                Button("Expand All") { expanded = Set(rows.map(\.id)) }
                Button("Collapse All") { expanded = [] }
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                showInspector = true
            }
            .overlay {
                if rows.isEmpty {
                    if !search.isEmpty { ContentUnavailableView.search(text: search) }
                    else if blockedOnly {
                        GardenEmpty(title: "Nothing blocked", symbol: Verdict.block.symbol, message: "No connections were blocked in this time range.")
                    } else {
                        GardenEmpty(title: "No connections yet", symbol: "network", message: "Apps appear here the moment they open a connection.")
                    }
                }
            }
        }
        // The inspector itself lives on ContentView, so it is never torn down with this pane (see there).
        .onChange(of: selection) { _, id in store.inspectedApp = id.flatMap { find($0, in: apps)?.appKey } }
        .onAppear {
            if selection == nil { selection = rows.first?.id }
            store.inspectedApp = selection.flatMap { find($0, in: apps)?.appKey }
        }
    }

    private func find(_ id: TrafficRow.ID, in apps: [AppTraffic]) -> TrafficRow? {
        for a in apps {
            if a.id == id { return TrafficRow(kind: .app(a)) }
            for d in a.destinations.values where a.id + "→" + d.id == id { return TrafficRow(kind: .destination(d, appKey: a.id)) }
        }
        return nil
    }
}

struct AppCell: View {
    @Environment(\.store) private var store
    let traffic: AppTraffic

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: traffic.app.icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(traffic.app.title).lineLimit(1)
                Text([traffic.app.processName, traffic.app.signatureSummary].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            RuleTag(rule: store.rules.apps[traffic.id])
        }
        .help(traffic.app.path)
    }
}

private struct DestinationCell: View {
    @Environment(\.store) private var store
    let destination: Destination

    var body: some View {
        let blockedBy = store.rules.blockingRule(host: destination.host, ip: destination.ips.first)
        let allowedBy = store.rules.allowingRule(host: destination.host, ip: destination.ips.first)
        HStack(spacing: 6) {
            Image(systemName: destination.host == nil ? "number" : "globe")
                .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.name).lineLimit(1).truncationMode(.middle)
                Text([destination.country.map(GeoIP.name(for:)), destination.host == nil ? "No hostname seen" : nil]
                    .compactMap { $0 }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let blockedBy {
                Image(systemName: Verdict.block.symbol).foregroundStyle(Color.shu)
                    .help("Blocked by \(blockedBy)").accessibilityLabel("Blocked by \(blockedBy)")
            } else if let allowedBy {
                Image(systemName: Verdict.allow.symbol).foregroundStyle(Color.allow)
                    .help("Allowed by \(allowedBy)").accessibilityLabel("Allowed by \(allowedBy)")
            }
        }
    }
}

/// Small marker for an app's standing rule. Nothing when the default applies.
struct RuleTag: View {
    let rule: Bool?

    var body: some View {
        if let rule {
            Image(systemName: rule ? Verdict.allow.symbol : Verdict.block.symbol)
                .foregroundStyle(rule ? Color.allow : Color.shu)
                .help(rule ? "Always allowed" : "Blocked by your rule")
                .accessibilityLabel(rule ? "Always allowed" : "Blocked by your rule")
        }
    }
}

struct AppActions: View {
    @Environment(\.store) private var store
    let app: AppIdentity

    var body: some View {
        let rule = store.rules.apps[app.key]
        if !store.connected && !store.isDemo {
            if store.isAddressBlocked(app.key) {
                Button("Unblock \(app.title)", systemImage: "arrow.uturn.backward") {
                    store.unblockByAddress(app.key)
                    Task { await SystemFirewall.shared.applyCurrent() }
                }
            } else {
                Button("Block \(app.title) on This Mac…", systemImage: Verdict.block.symbol) {
                    store.blockByAddress(app.key)
                    Task { await SystemFirewall.shared.applyCurrent() }
                }
                .disabled(store.exclusiveEntries(for: app.key).isEmpty)
            }
            Divider()
        }
        Button("Always Allow", systemImage: Verdict.allow.symbol) { store.update { $0.apps[app.key] = true } }
            .disabled(rule == true || !store.connected)
        Button("Block App", systemImage: Verdict.block.symbol) { store.update { $0.apps[app.key] = false } }
            .disabled(rule == false || !store.connected)
        if rule != nil {
            Button("Remove Rule", systemImage: "arrow.uturn.backward") { store.update { $0.apps[app.key] = nil } }
                .disabled(!store.connected)
        }
        Divider()
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
        Button("Copy Path", systemImage: "doc.on.doc") { copy(app.path) }
        if let id = app.signingID { Button("Copy Signing ID", systemImage: "doc.on.doc") { copy(id) } }
        Divider()
        Button("Remove from History", systemImage: "trash") { store.removeFromHistory(app.key) }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: Inspector

struct AppInspector: View {
    @Environment(\.store) private var store
    let traffic: AppTraffic
    @State private var signature: SignatureInfo?
    @State private var policy: AccessPolicy?

    var body: some View {
        let app = traffic.app
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(nsImage: app.icon).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.title).font(.garden(.title2)).lineLimit(2)
                        if let id = app.signingID { Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }

                if !store.connected {
                    AddressBlockSection(app: app)
                } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rule").font(.garden(.headline))
                    Picker("Rule", selection: Binding(get: { store.rules.apps[app.key] },
                                                      set: { v in store.update { $0.apps[app.key] = v } })) {
                        Text("Default").tag(Bool?.none)
                        Text("Allow").tag(Bool?.some(true))
                        Text("Block").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!store.connected)
                    Text(ruleNote(store.rules.apps[app.key])).font(.caption).foregroundStyle(.secondary)
                }
                }

                SignatureSection(info: signature, path: app.path)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    stat("Connections", traffic.connections.formatted())
                    stat("Blocked", traffic.blocked.formatted())
                    stat("Sent", bytes(traffic.bytesOut))
                    stat("Received", bytes(traffic.bytesIn))
                    stat("Last seen", traffic.lastSeen.formatted(date: .abbreviated, time: .standard))
                }

                if let policy { PolicySection(policy: policy) }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Location").font(.garden(.headline))
                    Text(app.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                        Button("Copy") { copy(app.path) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(20)
        }
        .task(id: app.path) {
            let path = app.path
            let (sig, pol) = await Task.detached(priority: .userInitiated) {
                (SignatureInfo.read(path: path), AccessPolicy.read(appPath: path))
            }.value
            signature = sig
            policy = pol
        }
    }

    private func ruleNote(_ rule: Bool?) -> String {
        switch rule {
        case .some(true): !store.connected ? "Saved. Takes effect when the filter runs." : "Always allowed. Blocked domains still apply."
        case .some(false): !store.connected ? "Saved. Takes effect when the filter runs." : "Every connection from this app is blocked."
        case .none:
            !store.connected ? "Rules for one app need the filter; the system firewall can't tell apps apart."
                : store.rules.mode == .requireApproval ? "Kekkai asks the next time it connects." : "Follows the current mode."
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// The code signature, the way a careful person would check it: who signed, through which chain, and how.
struct SignatureSection: View {
    let info: SignatureInfo?
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signature").font(.garden(.headline))
            if let info {
                if case .missing = info.status {
                    Label(info.title, systemImage: "questionmark.app.dashed").foregroundStyle(.secondary)
                } else {
                    Label(info.title, systemImage: info.trustworthy ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(info.trustworthy ? Color.allow : Color.ask)
                }
                if case .invalid(let why) = info.status {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let team = info.teamID { row("Team", team) }
                    if let id = info.identifier { row("Identifier", id) }
                    if case .missing = info.status {} else {
                        row("Hardened runtime", info.hardenedRuntime ? "Yes" : "No")
                    }
                    if let at = info.signedAt { row("Signed", at.formatted(date: .abbreviated, time: .omitted)) }
                }
                .font(.caption)
                if !info.chain.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(info.chain.enumerated()), id: \.offset) { i, name in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: i == 0 ? "doc.badge.gearshape" : "arrow.turn.left.up")
                                    .foregroundStyle(.secondary).font(.caption2).frame(width: 14)
                                Text(name).font(.caption).textSelection(.enabled)
                            }
                            .padding(.leading, CGFloat(i) * 12)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// What the developer says the app connects to (Internet Access Policy in the app bundle).
struct PolicySection: View {
    let policy: AccessPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the Developer Declares").font(.garden(.headline))
            if let summary = policy.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(policy.connections) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: c.incoming ? "arrow.down.left" : "arrow.up.right")
                            .font(.caption2).foregroundStyle(.secondary).accessibilityLabel(c.incoming ? "Incoming" : "Outgoing")
                        Text(c.host + (c.port.map { ":\($0)" } ?? "")).font(.callout).lineLimit(2)
                    }
                    if let purpose = c.purpose { Text(purpose).font(.caption).foregroundStyle(.secondary) }
                    if let deny = c.denyConsequences {
                        Text("If blocked: \(deny)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Without the filter: block an app by blocking the addresses only it has used, through the system firewall.
struct AddressBlockSection: View {
    @Environment(\.store) private var store
    @State private var fw = SystemFirewall.shared
    let app: AppIdentity

    var body: some View {
        let blocked = store.isAddressBlocked(app.key)
        let entries = blocked ? (store.rules.addressBlocks[app.key] ?? []) : store.exclusiveEntries(for: app.key)
        let shared = (store.apps[app.key]?.destinations.count ?? 0) - entries.count
        VStack(alignment: .leading, spacing: 10) {
            Text("Block").font(.garden(.headline))
            if blocked {
                Label("Blocking \(entries.count) \(entries.count == 1 ? "address" : "addresses") \(app.title) used",
                      systemImage: "lock.shield.fill")
                    .foregroundStyle(Color.shu)
                Button("Unblock \(app.title)") {
                    store.unblockByAddress(app.key)
                    Task { await fw.applyCurrent() }
                }
                .disabled(fw.busy || store.isDemo)
                Text("New addresses \(app.title) uses are added as Kekkai sees them; apply them from the bar at the bottom.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    store.blockByAddress(app.key)
                    Task { await fw.applyCurrent() }
                } label: {
                    Label("Block \(app.title) on This Mac…", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.shu)
                .disabled(entries.isEmpty || fw.busy || store.isDemo)
                Text(entries.isEmpty
                     ? "\(app.title) hasn't reached any address of its own yet, so there is nothing to block without cutting off other apps."
                     : "Blocks the \(entries.count) \(entries.count == 1 ? "address" : "addresses") only \(app.title) has used, for every app on this Mac. macOS asks for your password."
                       + (shared > 0 ? " \(shared) shared with other apps stay open." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = fw.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.ask)
            }
            Text("Blocking one app exactly, and asking before new apps connect, needs Kekkai's network filter.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
