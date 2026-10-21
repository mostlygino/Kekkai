import SwiftUI

// MARK: Approval panel

/// Floating glass panel listing apps that wait for an answer. Does not steal focus from the app you are in.
struct ApprovalPanel: View {
    @Environment(\.store) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("rememberApproval") private var remember = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BarrierMark(on: true, size: 16)
                Text(store.approvals.count == 1 ? "An app wants to connect" : "\(store.approvals.count) apps want to connect")
                    .font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { dismissWindow(id: "approvals") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide. Unanswered requests are still blocked when their time runs out.")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            if store.approvals.isEmpty {
                Text("Nothing is waiting.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.approvals.enumerated()), id: \.element.id) { i, req in
                            if i > 0 { Divider().padding(.horizontal, 18) }
                            ApprovalRow(request: req, remember: remember, primary: i == 0)
                        }
                    }
                }
                // Explicit height: letting content size drive a .contentSize window is a layout feedback loop.
                .frame(height: min(520, CGFloat(store.approvals.count) * 250))
            }

            Divider()
            HStack {
                Toggle("Remember my choice", isOn: $remember)
                    .toggleStyle(.checkbox)
                Spacer()
                if store.approvals.count > 1 {
                    Button("Block All") { for r in store.approvals { store.decide(r, allow: false, remember: remember) } }
                    Button("Allow All") { for r in store.approvals { store.decide(r, allow: true, remember: remember) } }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onAppear { DispatchQueue.main.async(execute: AppDelegate.configureApprovalPanel) }
        .onChange(of: store.approvals.isEmpty) { _, empty in
            if empty { dismissWindow(id: "approvals") }
        }
    }
}

private struct ApprovalRow: View {
    @Environment(\.store) private var store
    let request: ApprovalRequest
    let remember: Bool
    let primary: Bool

    var body: some View {
        let app = request.app
        let unsigned = app.teamID == nil && !app.isApple
        let policy = AccessPolicy.read(appPath: app.path)
        let countries = Set(request.ips.compactMap(GeoIP.country(for:))).map(GeoIP.name(for:)).sorted()

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: app.icon).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Label(unsigned ? "\(app.signatureSummary). Kekkai can't tell who made it." : app.signatureSummary,
                          systemImage: unsigned ? "exclamationmark.triangle" : "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(unsigned ? Color.ask : .secondary)
                    Text(app.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if !request.hosts.isEmpty { fact("Hosts", request.hosts.joined(separator: ", ")) }
                fact("Addresses", request.ips.joined(separator: ", "))
                if !countries.isEmpty { fact("Countries", countries.joined(separator: ", ")) }
                fact("Ports", request.ports.joined(separator: ", "))
                fact("Attempts", "\(request.count)")
                if let policy, !policy.connections.isEmpty {
                    let declared = request.hosts.filter { h in policy.connections.contains { c in
                        c.host.split(separator: ",").contains { RuleSet.match([RuleSet.normalize(domain: String($0))], host: h, ip: nil) != nil }
                    } }
                    fact("Declared", declared.isEmpty
                         ? "The developer lists \(policy.connections.count) connections, none of these hosts."
                         : "The developer lists \(declared.joined(separator: ", ")).")
                }
            }
            .font(.callout)

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(request.since.addingTimeInterval(TimeInterval(store.rules.approvalTimeout)).timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "Blocked in \(left) s if you don't answer" : "Blocking now")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 210, alignment: .leading)
                }
                Spacer()
                Button("Block") { store.decide(request, allow: false, remember: remember) }
                    .keyboardShortcut(primary ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                    .help(primary ? "Block (⌘⌫)" : "Block")
                Button("Allow") { store.decide(request, allow: true, remember: remember) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.allow)
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(primary ? "Allow (⌘↩)" : "Allow")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.title) wants to connect")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(3).textSelection(.enabled)
        }
    }
}

// MARK: Menu bar

/// Opens the approval panel from anywhere. Set by the first view that has an `openWindow` action.
enum PanelOpener {
    static var openApprovals: (() -> Void)?
}

/// Menu bar icon. Gets its models as plain properties: the label is re-hosted in the status item
/// and does not inherit the scene's environment.
struct MenuBarLabel: View {
    let store: Store
    let filter: FilterControl
    @Environment(\.openWindow) private var openWindow
    /// Briefly marks a block next to the stone, then settles back.
    @State private var flash = false

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StoneGlyph.image(tied: filter.state == .on && store.connected))
            if flash { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
            if !store.approvals.isEmpty { Text("\(store.approvals.count)").monospacedDigit() }
        }
        .onAppear {
            if PanelOpener.openApprovals == nil { PanelOpener.openApprovals = { openWindow(id: "approvals") } }
            // The menu bar label exists from launch, so it is the one view that can always reach the main window.
            if AppDelegate.openMain == nil { AppDelegate.openMain = { openWindow(id: "main"); NSApp.activate() } }
        }
        .onChange(of: store.blockedTick) { _, _ in
            guard !flash else { return }
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { flash = false }
        }
        .accessibilityLabel(store.approvals.isEmpty ? "Kekkai" : "Kekkai, \(store.approvals.count) waiting")
    }
}

struct MenuBarPanel: View {
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let on = filter.state == .on
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BarrierMark(on: on && store.connected, size: 26, lineWidth: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kekkai").font(.headline)
                    Text(on ? (store.connected ? "Barrier up" : "Connecting…") : store.watching ? "Watching, nothing blocked" : "Barrier down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Filter", isOn: Binding(get: { on }, set: { $0 ? filter.turnOn() : filter.turnOff() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Color.shu)
                    .disabled(filter.state == .installing || filter.state == .checking)
            }
            .padding(14)

            if on {
                ModePicker()
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }

            if !store.approvals.isEmpty {
                Button {
                    openWindow(id: "approvals")
                } label: {
                    Label(store.approvals.count == 1 ? "1 app is waiting for you" : "\(store.approvals.count) apps are waiting for you",
                          systemImage: Verdict.ask.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.ask)
                .padding(.horizontal, 14).padding(.bottom, 12)
            }

            Divider()

            TrafficChart(samples: store.samples, compact: true)
                .frame(height: 64)
                .padding(.horizontal, 14).padding(.top, 12)

            let blocked = store.recentlyBlocked
            if !blocked.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recently Blocked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show All") {
                            UserDefaults.standard.set(true, forKey: "blockedOnly")
                            store.show(.apps)
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    ForEach(blocked) { e in
                        HStack(spacing: 8) {
                            Image(nsImage: e.app.icon).resizable().frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.host ?? e.ip).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(e.app.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(ago(e.date))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .help(e.reason ?? "")
                    }
                }
                .padding(14)
                Divider()
            }

            let totals = store.totals
            VStack(alignment: .leading, spacing: 10) {
                Text("\(totals.connections.formatted()) connections, \(totals.blocked.formatted()) blocked, \(bytes(totals.bytesIn + totals.bytesOut)) moved")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                let top = store.apps.values.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }.prefix(5)
                if top.isEmpty {
                    Text("No traffic yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(top)) { a in
                    HStack(spacing: 8) {
                        Image(nsImage: a.app.icon).resizable().frame(width: 18, height: 18)
                        Text(a.app.title).lineLimit(1)
                        Spacer()
                        Text(bytes(a.bytesIn + a.bytesOut)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(14)

            Divider()
            HStack(spacing: 4) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Label("Open Kekkai", systemImage: "macwindow")
                }
                Spacer()
                Button("Search", systemImage: "magnifyingglass") { CommandPalette.shared.show() }
                    .labelStyle(.iconOnly)
                    .help("Search and actions (⌘K)")
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button("Quit Kekkai", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .help("Quit Kekkai")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 320)
    }
}
