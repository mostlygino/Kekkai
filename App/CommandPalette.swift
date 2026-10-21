import AppKit
import SwiftUI

/// ⌘K: one floating field for every action, app, destination and country, from any Kekkai window.
/// Same shape as Shīru's palette: a non-activating glass panel in the upper third of the screen.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: PalettePanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show(query: String = "") {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: PaletteView.width, height: 420),
                                 styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.title = "Command Palette"
        panel.contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.close() }, initialQuery: query))

        // Upper third of the screen the user is working on, like Spotlight.
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let top = frame.maxY - frame.height * 0.18
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - PaletteView.width / 2, y: top))
            panel.top = top
        }
        self.panel?.close()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel)
    }

    /// SwiftUI's focus request can land before the hosting view is in the panel, so the cursor goes into
    /// the search field from AppKit as well.
    private func focusField(in panel: NSPanel) {
        DispatchQueue.main.async {
            guard let field = Self.textField(in: panel.contentView) else { return }
            panel.makeFirstResponder(field)
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { if !Demo.tour { close() } }
}

/// Borderless panels refuse key status by default; this one takes typing.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The panel resizes with its results; keep the search field where it is and grow downwards.
    var top: CGFloat?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let top { frame.origin.y = top - frame.height }
        super.setFrame(frame, display: flag)
    }
}

// MARK: Items

struct PaletteItem: Identifiable {
    enum Icon { case symbol(String, Color? = nil), app(AppIdentity), mark(Bool) }
    enum Group: Int { case suggested, rules, actions, apps, destinations, countries }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    var keywords: [String] = []
    let group: Group
    let run: () -> Void
    /// ⌘Return: block (an app or a destination).
    var alternate: (label: String, run: () -> Void)?
    /// ⌥Return: allow.
    var option: (label: String, run: () -> Void)?
}

/// Fuzzy match: prefix beats word start beats substring beats letters in order.
enum PaletteSearch {
    /// Both lowercased already.
    static func score(_ q: String, _ text: String, fuzzy: Bool = true) -> Int? {
        if text.hasPrefix(q) { return 1000 - text.count }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - text.count }
        if text.contains(q) { return 600 - text.count }
        guard fuzzy else { return nil }
        // Letters in order, fewer gaps first ("blkdm" finds "block domain").
        var gaps = 0, index = text.startIndex
        for ch in q {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            gaps += text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return max(1, 400 - gaps * 10 - text.count)
    }
}

@MainActor
enum PaletteCatalog {
    /// Everything the palette can find, built once when it opens. Searching it per keystroke is then
    /// only string matching; nothing is rebuilt from the store while the palette is up.
    struct Index {
        fileprivate let suggested: [PaletteItem]
        fileprivate let entries: [(item: PaletteItem, title: String, other: [String])]
    }

    static func index(store: Store, filter: FilterControl) -> Index {
        let actions = actionItems(store: store, filter: filter)
        // Before typing: what people open this for, then the apps that were just blocked.
        let suggestedIDs = ["barrier", "approvals", "blocked-only", "go-map", "go-rules"]
        let top = suggestedIDs.compactMap { id in actions.first { $0.id == id } }.map {
            PaletteItem(id: $0.id, title: $0.title, subtitle: $0.subtitle, icon: $0.icon, shortcut: $0.shortcut, group: .suggested, run: $0.run)
        }
        let blockedApps = store.recentlyBlocked.prefix(4).compactMap { e in store.apps[e.app.key] }.map { appItem($0, store: store) }

        let candidates = actions + store.apps.values.map { appItem($0, store: store) }
            + store.destinations.map { destinationItem($0, store: store) } + countryItems(store: store)
        return Index(suggested: top + uniqued(blockedApps), entries: candidates.map {
            ($0, $0.title.lowercased(), $0.keywords.map { $0.lowercased() })
        })
    }

    static func items(query: String, in index: Index, store: Store) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return index.suggested }
        let q = trimmed.lowercased()

        // The title counts most and may match loosely; keywords (IDs, addresses, country codes) only by prefix or substring.
        let scored = index.entries.compactMap { e -> (item: PaletteItem, score: Int)? in
            let title = PaletteSearch.score(q, e.title).map { $0 + 200 }
            let other = e.other.compactMap { PaletteSearch.score(q, $0, fuzzy: false) }.max()
            return [title, other].compactMap { $0 }.max().map { (e.item, $0) }
        }
        // One section per group, the group with the best match first.
        let best = Dictionary(scored.map { ($0.item.group, $0.score) }, uniquingKeysWith: max)
        let results = scored.sorted {
            let (a, b) = (best[$0.item.group] ?? 0, best[$1.item.group] ?? 0)
            return a != b ? a > b : $0.score > $1.score
        }.map(\.item).prefix(60)
        return entryItems(trimmed, store: store) + Array(results)
    }

    private static func uniqued(_ items: [PaletteItem]) -> [PaletteItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Typed something that is a domain or an IP: offer to block or allow it right away.
    private static func entryItems(_ text: String, store: Store) -> [PaletteItem] {
        guard store.canEditLists, let entry = RuleSet.entry(text), entry.contains(".") || RuleSet.isIP(entry) else { return [] }
        var items: [PaletteItem] = []
        if !store.rules.domains.contains(entry) {
            items.append(PaletteItem(id: "block-entry", title: "Block “\(entry)”",
                                     subtitle: RuleSet.isIP(entry) ? "Add the address to the Block List" : "Add it and its subdomains to the Block List",
                                     icon: .symbol(Verdict.block.symbol, .shu), group: .rules) {
                store.update { $0.domains.append(entry); $0.allowDomains.removeAll { $0 == entry } }
            })
        }
        if !store.rules.allowDomains.contains(entry), !store.rules.domains.contains(entry) {
            items.append(PaletteItem(id: "allow-entry", title: "Allow “\(entry)”", subtitle: "Add it to the Allow List",
                                     icon: .symbol(Verdict.allow.symbol, .allow), group: .rules) {
                store.update { $0.allowDomains.append(entry) }
            })
        }
        return items
    }

    private static func actionItems(store: Store, filter: FilterControl) -> [PaletteItem] {
        let up = filter.state == .on
        var items: [PaletteItem] = [
            PaletteItem(id: "barrier", title: up ? "Lower the Barrier" : "Raise the Barrier",
                        subtitle: up ? "Turn the filter off" : "Turn the filter on", icon: .mark(up),
                        shortcut: "⇧⌘K", keywords: ["filter", "on", "off", "enable", "disable", "start", "stop"], group: .actions) {
                up ? filter.turnOff() : filter.turnOn()
            },
            PaletteItem(id: "blocked-only", title: "Show What Was Blocked", subtitle: "Apps and destinations with blocked connections",
                        icon: .symbol(Verdict.block.symbol), keywords: ["blocked", "denied", "dropped", "recent"], group: .actions) {
                UserDefaults.standard.set(true, forKey: "blockedOnly")
                store.show(.apps)
            },
            PaletteItem(id: "updates", title: "Check for Updates…", icon: .symbol("arrow.down.circle"),
                        keywords: ["update", "version", "release", "upgrade"], group: .actions) {
                Task { await Updater.shared.check(interactive: true) }
            },
            PaletteItem(id: "about", title: "About Kekkai", icon: .symbol("info.circle"), keywords: ["version", "build", "credits"], group: .actions) {
                PaletteActions.openAbout?()
            },
            PaletteItem(id: "settings", title: "Settings…", icon: .symbol("gearshape"), shortcut: "⌘,",
                        keywords: ["preferences", "login", "notifications", "quic", "timeout", "history"], group: .actions) {
                PaletteActions.openSettings?()
            },
        ]
        for (i, mode) in FilterMode.allCases.enumerated() where store.connected && store.rules.mode != mode {
            items.append(PaletteItem(id: "mode-\(mode.rawValue)", title: "Switch to \(mode.title)", subtitle: mode.summary,
                                     icon: .symbol("dial.medium"), shortcut: "⌥⌘\(i + 1)", keywords: ["mode", "strict"], group: .actions) {
                store.update { $0.mode = mode }
            })
        }
        for pane in Pane.allCases {
            items.append(PaletteItem(id: "go-\(pane.rawValue)", title: "Go to \(pane.title)", icon: .symbol(pane.icon),
                                     keywords: ["open", "show", "view"], group: .actions) {
                store.show(pane)
            })
        }
        if !store.approvals.isEmpty {
            let n = store.approvals.count
            items.insert(PaletteItem(id: "approvals", title: n == 1 ? "1 App Is Waiting for You" : "\(n) Apps Are Waiting for You",
                                     subtitle: "Open the approval panel", icon: .symbol(Verdict.ask.symbol, .ask),
                                     keywords: ["approve", "pending", "ask"], group: .actions) {
                PanelOpener.openApprovals?()
            }, at: 0)
        }
        return items
    }

    private static func appItem(_ a: AppTraffic, store: Store) -> PaletteItem {
        let key = a.id
        let rule = store.rules.apps[key]
        var item = PaletteItem(
            id: "app-\(key)", title: a.app.title,
            subtitle: ["\(a.connections) \(a.connections == 1 ? "connection" : "connections")", a.blocked > 0 ? "\(a.blocked) blocked" : nil,
                       rule == true ? "always allowed" : rule == false ? "blocked" : nil].compactMap { $0 }.joined(separator: " · "),
            icon: .app(a.app), keywords: [a.app.signingID ?? ""], group: .apps
        ) {
            store.show(.apps, search: a.app.title)
        }
        if store.connected {
            item.alternate = rule == false ? ("Remove block", { store.update { $0.apps[key] = nil } })
                                           : ("Block app", { store.update { $0.apps[key] = false } })
            item.option = rule == true ? ("Remove allow", { store.update { $0.apps[key] = nil } })
                                       : ("Always allow", { store.update { $0.apps[key] = true } })
        } else if !store.isDemo {
            // Without the filter: block the addresses only this app used, through the system firewall.
            item.alternate = store.isAddressBlocked(key)
                ? ("Unblock on this Mac", { store.unblockByAddress(key); Task { await SystemFirewall.shared.applyCurrent() } })
                : ("Block on this Mac", { store.blockByAddress(key); Task { await SystemFirewall.shared.applyCurrent() } })
        }
        return item
    }

    private static func destinationItem(_ d: Destination, store: Store) -> PaletteItem {
        let entry = d.host.map(RuleSet.normalize(domain:)) ?? d.ips.sorted().first ?? d.name
        let blockedBy = store.rules.blockingRule(host: d.host, ip: d.ips.first)
        var item = PaletteItem(
            id: "dest-\(d.id)", title: d.name,
            subtitle: [d.country.map(GeoIP.name(for:)), "\(d.apps.count) \(d.apps.count == 1 ? "app" : "apps")",
                       blockedBy.map { "blocked by \($0)" }].compactMap { $0 }.joined(separator: " · "),
            icon: .symbol(d.host == nil ? "number" : "globe", blockedBy == nil ? nil : .shu), keywords: Array(d.ips), group: .destinations
        ) {
            store.show(.destinations, search: d.name)
        }
        if store.canEditLists {
            item.alternate = store.rules.domains.contains(entry)
                ? ("Unblock", { store.update { $0.domains.removeAll { $0 == entry } } })
                : ("Block", { store.update { $0.domains.append(entry); $0.allowDomains.removeAll { $0 == entry } } })
            item.option = ("Allow", { store.update { $0.allowDomains.append(entry); $0.domains.removeAll { $0 == entry } } })
        }
        return item
    }

    private static func countryItems(store: Store) -> [PaletteItem] {
        var counts: [String: Int] = [:]
        for d in store.destinations { if let cc = d.country { counts[cc, default: 0] += d.connections } }
        return counts.map { cc, n in
            PaletteItem(id: "country-\(cc)", title: GeoIP.name(for: cc), subtitle: "\(n) \(n == 1 ? "connection" : "connections") · show on the map",
                        icon: .symbol("globe.europe.africa"), keywords: [cc], group: .countries) {
                store.show(.map, country: cc)
            }
        }
    }
}

/// Window actions the palette can't reach through the environment (it lives in its own panel).
enum PaletteActions {
    static var openSettings: (() -> Void)?
    static var openAbout: (() -> Void)?
}

// MARK: View

struct PaletteView: View {
    static let width: CGFloat = 640

    let close: () -> Void
    var initialQuery = ""
    @Environment(\.store) private var store
    @Environment(\.filter) private var filter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var index: PaletteCatalog.Index?
    @State private var items: [PaletteItem] = []
    @State private var selectedID: String?
    /// Set by the arrow keys only: hovering selects without scrolling, so rows don't slide under the pointer.
    @State private var scrollTarget: String?
    @State private var pointer = Pointer()
    @State private var appeared = false
    @FocusState private var fieldFocused: Bool

    private var selected: PaletteItem? { items.first { $0.id == selectedID } ?? items.first }

    /// The last pointer position seen by a hover. Rows passing under a still pointer while the list
    /// scrolls also report hover; only a pointer that moved changes the selection.
    private final class Pointer { var last = NSPoint(x: -1, y: -1) }

    var body: some View {
        let selectedID = selected?.id
        VStack(spacing: 0) {
            field
            if !items.isEmpty {
                Divider().opacity(0.5)
                results(items, selectedID: selectedID)
                Divider().opacity(0.5)
                footer
            } else if !query.isEmpty {
                Divider().opacity(0.5)
                Text("Nothing matches “\(query)”. Try an app, a host, a country, or an action such as “block”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: Self.width)
        .modifier(PaletteGlass())
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            index = PaletteCatalog.index(store: store, filter: filter)
            query = initialQuery
            refresh()
            fieldFocused = true
            withAnimation(.spring(duration: 0.28, bounce: 0.12)) { appeared = true }
        }
        .onChange(of: query) { refresh() }
        .onExitCommand(perform: close)
    }

    private var field: some View {
        HStack(spacing: 12) {
            BarrierMark(on: filter.state == .on && store.connected, size: 26, lineWidth: 2)
                .frame(width: 30, height: 30)
            TextField("Search apps, hosts and actions, or type a domain to block", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($fieldFocused)
                .onSubmit { run(selected) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.command), let alt = selected?.alternate { finish(alt.run, activate: false); return .handled }
                    if press.modifiers.contains(.option), let opt = selected?.option { finish(opt.run, activate: false); return .handled }
                    return .ignored
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func results(_ items: [PaletteItem], selectedID: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].group != item.group {
                            groupHeader(item.group).frame(height: index == 0 ? Self.firstHeaderHeight : Self.headerHeight, alignment: .bottomLeading)
                        }
                        row(item, isSelected: item.id == selectedID).id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            // A ScrollView has no height of its own, and the panel sizes itself to its content: without an
            // explicit height the list collapsed to nothing while typing. Rows and headers have fixed heights,
            // so the list's height is known up front.
            .frame(height: min(Self.listHeight(items), 380))
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
                scrollTarget = nil
            }
        }
    }

    private func groupHeader(_ group: PaletteItem.Group) -> some View {
        let title = switch group {
        case .suggested: "Suggested"
        case .rules: "Rules"
        case .actions: "Actions"
        case .apps: "Apps"
        case .destinations: "Destinations"
        case .countries: "Countries"
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private static let rowHeight: CGFloat = 46, headerHeight: CGFloat = 30, firstHeaderHeight: CGFloat = 22, spacing: CGFloat = 2

    private static func listHeight(_ items: [PaletteItem]) -> CGFloat {
        let groups = zip(items, items.dropFirst()).filter { $0.group != $1.group }.count + (items.isEmpty ? 0 : 1)
        let children = items.count + groups
        return CGFloat(items.count) * rowHeight + firstHeaderHeight + CGFloat(max(groups - 1, 0)) * headerHeight
            + CGFloat(max(children - 1, 0)) * spacing + 8
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            icon(item.icon, selected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.shu.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.shu.opacity(0.35), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { run(item) }
        .onHover { inside in
            let location = NSEvent.mouseLocation
            guard inside, location != pointer.last else { return }
            pointer.last = location
            selectedID = item.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon, selected: Bool) -> some View {
        switch icon {
        case .app(let app):
            Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
        case .mark(let up):
            BarrierMark(on: up, size: 30)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? (selected ? Color.shu : .secondary))
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(selected ? 0.0 : 0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↵", selected.map { if case .app = $0.icon { "Show" } else if $0.group == .destinations || $0.group == .countries { "Show" } else { "Run" } } ?? "Run")
            if let alt = selected?.alternate { hint("⌘↵", alt.label) }
            if let opt = selected?.option { hint("⌥↵", opt.label) }
            Spacer()
            hint("esc", "Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }

    private func refresh() {
        guard let index else { return }
        items = PaletteCatalog.items(query: query, in: index, store: store)
        selectedID = nil
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selected?.id } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
        scrollTarget = items[next].id
    }

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        finish(item.run, activate: true)
    }

    /// Rule changes (⌘↵, ⌥↵) don't need Kekkai in front; navigation does.
    private func finish(_ action: @escaping () -> Void, activate: Bool) {
        close()
        if activate { NSApp.activate() }
        DispatchQueue.main.async(execute: action)
    }
}

/// Liquid Glass over a faint ground, so text stays readable on busy desktops.
private struct PaletteGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        content
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: shape)
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}
