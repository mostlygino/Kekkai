import Charts
import SwiftUI
import UniformTypeIdentifiers

private func matches(_ search: String, _ fields: String?...) -> Bool {
    let q = search.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
}

private func number(_ n: Int) -> some View { Text(n, format: .number).monospacedDigit() }

// MARK: Destinations

struct DestinationActions: View {
    @Environment(\.store) private var store
    let destination: Destination

    var body: some View {
        let entry = destination.host.map(RuleSet.normalize(domain:)) ?? destination.ips.sorted().first
        if let entry {
            let blocked = store.rules.domains.contains(entry)
            let allowed = store.rules.allowDomains.contains(entry)
            if blocked {
                Button("Remove \(entry) from Block List", systemImage: "arrow.uturn.backward") {
                    store.update { $0.domains.removeAll { $0 == entry } }
                }
            } else if let parent = store.rules.blockingRule(host: destination.host, ip: destination.ips.first) {
                Button("Blocked by \(parent)") {}.disabled(true)
            } else {
                Button("Add \(entry) to Block List", systemImage: Verdict.block.symbol) {
                    store.update { $0.domains.append(entry); $0.allowDomains.removeAll { $0 == entry } }
                }
                if let host = destination.host, let parent = parentDomain(host) {
                    Button("Block All of *.\(parent)", systemImage: "xmark.octagon.fill") { store.update { $0.domains.append(parent) } }
                }
            }
            if allowed {
                Button("Remove \(entry) from Allow List", systemImage: "arrow.uturn.backward") {
                    store.update { $0.allowDomains.removeAll { $0 == entry } }
                }
            } else if !blocked {
                Button("Add \(entry) to Allow List", systemImage: Verdict.allow.symbol) { store.update { $0.allowDomains.append(entry) } }
            }
        }
        Divider()
        if let cc = destination.country {
            Button("Show in Map", systemImage: "globe.europe.africa") { store.show(.map, country: cc) }
        }
        if let host = destination.host { Button("Copy Host", systemImage: "doc.on.doc") { copy(host) } }
        Button("Copy Addresses", systemImage: "doc.on.doc") { copy(destination.ips.sorted().joined(separator: "\n")) }
    }

    /// "a.b.example.com" -> "example.com". Naive: two labels, so it is wrong for "co.uk"-style suffixes; offered next to the exact host.
    private func parentDomain(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count > 2, !RuleSet.isIP(host) else { return nil }
        return parts.suffix(2).joined(separator: ".")
    }
}

struct DestinationsPane: View {
    @Environment(\.store) private var store
    @Environment(\.paneActive) private var active
    @State private var frozen = Frozen()
    let search: String
    @AppStorage("timeScope") private var scope: TimeScope = .day
    @AppStorage("blockedOnly") private var blockedOnly = false
    @State private var order = [KeyPathComparator(\Destination.lastSeen, order: .reverse)]
    @State private var selection: Destination.ID?

    var body: some View {
        let cutoff = Date().addingTimeInterval(-scope.seconds)
        let rows = frozen.keep("rows", live: active) {
            store.destinations
                .filter { $0.lastSeen >= cutoff && (!blockedOnly || $0.blocked > 0) }
                .filter { matches(search, $0.name, $0.country.map(GeoIP.name(for:))) || $0.ips.contains { matches(search, $0) } }
        }
            .sorted(using: order)
        VStack(spacing: 0) {
        ScopeBar {
            Text(rows.count == 1 ? "1 destination" : "\(rows.count) destinations").foregroundStyle(.secondary).monospacedDigit()
        }
        Divider()
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Destination", value: \.name) { d in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).lineLimit(1).truncationMode(.middle)
                        // Address and country share the second line, so the table needs no Country column.
                        Text([d.host != nil ? d.ips.sorted().first : "No hostname seen", d.country.map(GeoIP.name(for:))]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(d.ips.sorted().joined(separator: ", "))
                    }
                    Spacer(minLength: 4)
                    if let rule = store.rules.blockingRule(host: d.host, ip: d.ips.first) {
                        Image(systemName: Verdict.block.symbol).foregroundStyle(Color.shu)
                            .help("Blocked by \(rule)").accessibilityLabel("Blocked by \(rule)")
                    } else if let rule = store.rules.allowingRule(host: d.host, ip: d.ips.first) {
                        Image(systemName: Verdict.allow.symbol).foregroundStyle(Color.allow)
                            .help("Allowed by \(rule)").accessibilityLabel("Allowed by \(rule)")
                    }
                }
            }
            .width(min: 150, ideal: 200)
            TableColumn("Connections", value: \.connections) { d in
                VStack(alignment: .leading, spacing: 1) {
                    number(d.connections)
                    Text(d.apps.count == 1 ? "1 app" : "\(d.apps.count) apps").font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 92)
            TableColumn("Blocked", value: \.blocked) { d in number(d.blocked).foregroundStyle(d.blocked > 0 ? Color.shu : .secondary) }
                .width(min: 48, ideal: 76)
            TableColumn("Data", value: \.total) { DataCell(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }.width(min: 118, ideal: 124)
        }
        .scrollIndicators(.never, axes: .horizontal)
        .contextMenu(forSelectionType: Destination.ID.self) { ids in
            if let id = ids.first, let d = rows.first(where: { $0.id == id }) { DestinationActions(destination: d) }
        }
        .overlay {
            if rows.isEmpty {
                if !search.isEmpty { ContentUnavailableView.search(text: search) }
                else if blockedOnly {
                    GardenEmpty(title: "Nothing blocked", symbol: Verdict.block.symbol, message: "No destination was blocked in this time range.")
                } else {
                    GardenEmpty(title: "No destinations yet", symbol: Pane.destinations.icon, message: "Every host and address your apps reach shows up here.")
                }
            }
        }
        }
    }
}

// MARK: Activity

struct ActivityPane: View {
    @Environment(\.store) private var store
    @Environment(\.paneActive) private var active
    @State private var frozen = Frozen()
    let search: String
    @State private var filter: Verdict?

    var body: some View {
        let rows = frozen.keep("rows", live: active) {
            store.activity.filter { e in
                (filter == nil || e.verdict == filter) && matches(search, e.app.title, e.host, e.ip, e.reason)
            }
        }
        VStack(spacing: 0) {
        HStack {
            Picker("Show", selection: $filter) {
                Text("All").tag(Verdict?.none)
                Text("Allowed").tag(Verdict?.some(.allow))
                Text("Blocked").tag(Verdict?.some(.block))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("\(rows.count) shown").font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        Divider()
        Table(rows) {
            // Two lines per row, like the other tables: who and where on the left, the verdict and why on the right.
            TableColumn("Connection") { e in
                HStack(spacing: 10) {
                    Image(nsImage: e.app.icon).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(e.app.title).lineLimit(1)
                            if let n = e.repeats, n > 1 {
                                Text("×\(n)")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                    .help("\(n) connections like this in a row")
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: e.inbound ? "arrow.down.left" : "arrow.up.right")
                                .accessibilityLabel(e.inbound ? "Incoming" : "Outgoing")
                            Text((e.host ?? e.ip) + ":" + e.port).lineLimit(1).truncationMode(.middle)
                            if e.proto == "UDP" { Text("UDP") }
                            if let cc = GeoIP.country(for: e.ip) { Text("· " + GeoIP.name(for: cc)).lineLimit(1) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .help(e.host == nil ? e.ip : "\(e.host!) (\(e.ip))")
            }
            .width(min: 250, ideal: 260)
            TableColumn("Verdict") { e in
                VStack(alignment: .leading, spacing: 1) {
                    if e.reason == "Watching only" {
                        // Watch mode decides nothing, so it doesn't claim "Allowed".
                        Label("Seen", systemImage: "eye").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                    } else {
                        VerdictLabel(verdict: e.verdict, compact: true)
                        if let why = e.reason { Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .help(e.reason ?? "")
            }
            .width(min: 140, ideal: 150)
            TableColumn("Time") { e in
                Text(e.date, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
        }
        .overlay {
            if rows.isEmpty {
                if !search.isEmpty { ContentUnavailableView.search(text: search) }
                else {
                    GardenEmpty(title: filter == .block ? "Nothing blocked" : "No activity yet", symbol: Pane.activity.icon,
                                message: "New connections are listed here as they happen, newest first.")
                }
            }
        }
        }
    }
}

// MARK: Map

struct MapPane: View {
    @Environment(\.store) private var store
    @Environment(\.paneActive) private var active
    @State private var frozen = Frozen()
    @State private var selection: String?
    @AppStorage("timeScope") private var scope: TimeScope = .day
    @State private var order = [KeyPathComparator(\CountryTraffic.connections, order: .reverse)]

    var body: some View {
        var byCode: [String: CountryTraffic] = [:]
        let cutoff = Date().addingTimeInterval(-scope.seconds)
        for d in frozen.keep("destinations", live: active, { store.destinations }) where d.lastSeen >= cutoff {
            guard let cc = d.country else { continue }
            var r = byCode[cc] ?? CountryTraffic(code: cc, name: GeoIP.name(for: cc))
            r.connections += d.connections; r.blocked += d.blocked; r.destinations += 1
            r.bytesIn += d.bytesIn; r.bytesOut += d.bytesOut
            byCode[cc] = r
        }
        let rows = byCode.values.sorted(using: order)

        return VStack(spacing: 0) {
            ScopeBar()
            Divider()
            WorldMap(traffic: rows, selection: $selection)
                .frame(height: 300)
                .padding(.horizontal, 28).padding(.vertical, 18)
                .onAppear { if let f = store.mapFocus { selection = f; store.mapFocus = nil } }
                .onChange(of: store.mapFocus) { _, f in if let f { selection = f; store.mapFocus = nil } }
            Divider()
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Country", value: \.name) { r in
                    HStack(spacing: 6) {
                        Text(r.name)
                        Text(r.code).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 220)
                TableColumn("Connections", value: \.connections) { number($0.connections) }.width(min: 56, ideal: 92)
                TableColumn("Blocked", value: \.blocked) { r in number(r.blocked).foregroundStyle(r.blocked > 0 ? Color.shu : .secondary) }
                    .width(min: 48, ideal: 76)
                TableColumn("Destinations", value: \.destinations) { number($0.destinations) }.width(min: 70, ideal: 92)
                TableColumn("Data", value: \.total) { DataCell(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }.width(min: 118, ideal: 124)
            }
            .overlay {
                if !GeoIP.available {
                    GardenEmpty(title: "No country data in this build", symbol: "globe", message: "Run scripts/fetch-geoip.sh, then build again.")
                } else if rows.isEmpty {
                    GardenEmpty(title: "No countries yet", symbol: "globe", message: "Countries appear as your apps reach servers around the world.")
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("Outlines")
                Link("Natural Earth", destination: URL(string: "https://www.naturalearthdata.com")!)
                Text("·")
                Text("Countries")
                Link("DB-IP", destination: GeoIP.attributionURL)
                Text("CC BY 4.0")
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

// MARK: Rules

struct RulesDocument: FileDocument {
    static let readableContentTypes = [UTType.json]
    var rules: RuleSet

    init(rules: RuleSet) { self.rules = rules }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count < 5_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        rules = try JSONDecoder().decode(RuleSet.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(rules))
    }
}

struct RulesPane: View {
    @Environment(\.store) private var store
    @State private var showFilterSettings = false
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingImport: RuleSet?
    @State private var importError: String?

    var body: some View {
        Form {
            // With the filter: modes first. Without it: what works first (the system firewall and the lists),
            // and the filter-only settings folded away so they don't sit there disabled.
            if store.connected {
            Section {
                Picker("Mode", selection: Binding(get: { store.rules.mode }, set: { m in store.update { $0.mode = m } })) {
                    ForEach(FilterMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!store.connected)
            } header: {
                Text("Mode")
            } footer: {
                if !store.connected {
                    Text("Modes need the filter. Without it, your Block List can still be applied to this Mac below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if store.rules.mode == .blockAll || store.rules.mode == .requireApproval {
                Section {
                    Toggle("Allow Apple software", isOn: binding(\.allowApple))
                    Toggle("Allow DNS lookups", isOn: binding(\.allowDNS))
                    if store.rules.mode == .requireApproval {
                        Toggle("Block new apps while Kekkai is closed", isOn: binding(\.failClosedWithoutApp))
                    }
                } header: {
                    Text("Exceptions")
                } footer: {
                    Text(store.rules.mode == .blockAll
                         ? "Without these, macOS can't resolve names or check for updates, and most of the Mac goes offline. Your Allow List always applies."
                         : "Apple software and DNS are never held for approval while these are on. When Kekkai is closed nobody can answer, so by default only your Block List applies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!store.connected)
            }

            EntryListSection(title: "Block List", verdict: .block, entries: store.rules.domains,
                             enabled: binding(\.blockListEnabled),
                             footer: "Domains, wildcards like *.example.com, and IP addresses. A domain also covers its subdomains. The Block List always wins over the Allow List.") { new in
                store.update { r in
                    r.domains += new
                    r.allowDomains.removeAll(where: new.contains)
                }
            } remove: { e in
                store.update { $0.domains.removeAll { $0 == e } }
            }

            EntryListSection(title: "Allow List", verdict: .allow, entries: store.rules.allowDomains, enabled: nil,
                             footer: "Let through in Block All, and never held for approval.") { new in
                store.update { $0.allowDomains += new.filter { !$0.isEmpty } }
            } remove: { e in
                store.update { $0.allowDomains.removeAll { $0 == e } }
            }
            .disabled(!store.connected)

            Section {
                if store.rules.apps.isEmpty {
                    Text("No app rules yet. Set one from Apps, or answer an approval with Remember on.").foregroundStyle(.secondary)
                }
                ForEach(store.rules.apps.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 10) {
                        if let app = store.apps[key]?.app {
                            Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.apps[key]?.app.title ?? key.split(separator: "/").last.map(String.init) ?? key)
                            Text(key).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Rule", selection: Binding(get: { store.rules.apps[key] ?? true },
                                                          set: { v in store.update { $0.apps[key] = v } })) {
                            Text("Allow").tag(true)
                            Text("Block").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        Button("Remove rule", systemImage: "minus.circle") { store.update { $0.apps[key] = nil } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("App Decisions")
            } footer: {
                if !store.connected {
                    Text("Rules for one app need the filter: the system firewall can't tell apps apart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!store.connected)

            } else {
                SystemFirewallSection()
            EntryListSection(title: "Block List", verdict: .block, entries: store.rules.domains,
                             enabled: binding(\.blockListEnabled),
                             footer: "Domains, wildcards like *.example.com, and IP addresses. A domain also covers its subdomains. The Block List always wins over the Allow List.") { new in
                store.update { r in
                    r.domains += new
                    r.allowDomains.removeAll(where: new.contains)
                }
            } remove: { e in
                store.update { $0.domains.removeAll { $0 == e } }
            }

            EntryListSection(title: "Allow List", verdict: .allow, entries: store.rules.allowDomains, enabled: nil,
                             footer: "Let through in Block All, and never held for approval.") { new in
                store.update { $0.allowDomains += new.filter { !$0.isEmpty } }
            } remove: { e in
                store.update { $0.allowDomains.removeAll { $0 == e } }
            }
            .disabled(!store.connected)

                Section {
                    DisclosureGroup(isExpanded: $showFilterSettings) {
                        Text("Modes, exceptions and rules for one app take effect once Kekkai's network filter runs.")
                            .font(.callout).foregroundStyle(.secondary)
                    } label: {
                        Label("Filter Settings", systemImage: "slider.horizontal.3")
                    }
                }
                if showFilterSettings {
            Section {
                Picker("Mode", selection: Binding(get: { store.rules.mode }, set: { m in store.update { $0.mode = m } })) {
                    ForEach(FilterMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!store.connected)
            } header: {
                Text("Mode")
            } footer: {
                if !store.connected {
                    Text("Modes need the filter. Without it, your Block List can still be applied to this Mac below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if store.rules.mode == .blockAll || store.rules.mode == .requireApproval {
                Section {
                    Toggle("Allow Apple software", isOn: binding(\.allowApple))
                    Toggle("Allow DNS lookups", isOn: binding(\.allowDNS))
                    if store.rules.mode == .requireApproval {
                        Toggle("Block new apps while Kekkai is closed", isOn: binding(\.failClosedWithoutApp))
                    }
                } header: {
                    Text("Exceptions")
                } footer: {
                    Text(store.rules.mode == .blockAll
                         ? "Without these, macOS can't resolve names or check for updates, and most of the Mac goes offline. Your Allow List always applies."
                         : "Apple software and DNS are never held for approval while these are on. When Kekkai is closed nobody can answer, so by default only your Block List applies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!store.connected)
            }

            Section {
                if store.rules.apps.isEmpty {
                    Text("No app rules yet. Set one from Apps, or answer an approval with Remember on.").foregroundStyle(.secondary)
                }
                ForEach(store.rules.apps.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 10) {
                        if let app = store.apps[key]?.app {
                            Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.apps[key]?.app.title ?? key.split(separator: "/").last.map(String.init) ?? key)
                            Text(key).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Rule", selection: Binding(get: { store.rules.apps[key] ?? true },
                                                          set: { v in store.update { $0.apps[key] = v } })) {
                            Text("Allow").tag(true)
                            Text("Block").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        Button("Remove rule", systemImage: "minus.circle") { store.update { $0.apps[key] = nil } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("App Decisions")
            } footer: {
                if !store.connected {
                    Text("Rules for one app need the filter: the system firewall can't tell apps apart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!store.connected)

                }
            }
            Section {
                HStack {
                    Button("Import Rules…") { importing = true }
                    Button("Export Rules…") { exporting = true }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Every rule, list and exception in one JSON file, to keep or move to another Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exporting, document: RulesDocument(rules: store.rules),
                      contentType: .json, defaultFilename: "Kekkai Rules") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
                pendingImport = try JSONDecoder().decode(RuleSet.self, from: data)
            } catch {
                importError = "That file isn't a Kekkai rules file."
            }
        }
        .confirmationDialog("Replace your rules?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Replace Rules", role: .destructive) {
                if let new = pendingImport { store.replaceRules(new) }
                pendingImport = nil
            }
        } message: {
            if let r = pendingImport {
                Text("The file has \(r.domains.count) blocked and \(r.allowDomains.count) allowed entries and \(r.apps.count) app decisions, in \(r.mode.title) mode. Your current rules are replaced.")
            }
        }
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func binding(_ key: WritableKeyPath<RuleSet, Bool>) -> Binding<Bool> {
        Binding(get: { store.rules[keyPath: key] }, set: { v in store.update { $0[keyPath: key] = v } })
    }
}

/// A Block List or Allow List: paste many entries at once (commas, spaces or new lines), see what was rejected.
private struct EntryListSection: View {
    let title: String
    let verdict: Verdict
    let entries: [String]
    let enabled: Binding<Bool>?
    let footer: String
    let add: ([String]) -> Void
    let remove: (String) -> Void
    @State private var text = ""
    @State private var rejected: [String] = []

    var body: some View {
        Section {
            if let enabled {
                Toggle("Use the \(title)", isOn: enabled)
            }
            HStack(alignment: .firstTextBaseline) {
                TextField("Add", text: $text, prompt: Text("example.com, *.ads.example.net, 203.0.113.9"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .onSubmit(commit)
                Button(verdict == .block ? "Block" : "Allow", action: commit)
                    .disabled(RuleSet.entries(from: text).valid.isEmpty)
            }
            if !rejected.isEmpty {
                Label("Not added, not a domain or IP address: \(rejected.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.ask)
            }
            if entries.isEmpty {
                Text("Empty.").foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { e in
                HStack {
                    Image(systemName: verdict.symbol).foregroundStyle(verdict.color).accessibilityHidden(true)
                    Text(RuleSet.isIP(e) ? e : "*.\(e)").foregroundStyle(enabled?.wrappedValue == false ? .secondary : .primary)
                    Spacer()
                    Button("Remove \(e)", systemImage: "minus.circle") { remove(e) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .contextMenu { Button("Copy") { copy(e) } }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text("\(entries.count)").monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        let parsed = RuleSet.entries(from: text)
        guard !parsed.valid.isEmpty || !parsed.invalid.isEmpty else { return }
        add(parsed.valid.filter { !entries.contains($0) })
        rejected = parsed.invalid
        text = parsed.invalid.isEmpty ? "" : parsed.invalid.joined(separator: ", ")
    }
}

// MARK: Traffic chart

struct TrafficChart: View {
    let samples: [TrafficSample]
    /// Menu bar size: no title, no axes, just the two lines.
    var compact = false

    var body: some View {
        if compact { lines.chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden) } else { full }
    }

    private var lines: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("Time", s.second), y: .value("Bytes", Double(s.bytesIn) / TrafficSample.bucket), series: .value("Direction", "Received"))
                    .foregroundStyle(Color.received)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.second), y: .value("Bytes", Double(s.bytesOut) / TrafficSample.bucket), series: .value("Direction", "Sent"))
                    .foregroundStyle(Color.sent)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
        }
        .accessibilityLabel("Traffic over the last five minutes")
    }

    @ViewBuilder private var full: some View {
        // The last 10 seconds (two samples), per second.
        let recent = samples.suffix(2)
        let span = UInt64(TrafficSample.bucket) * UInt64(max(1, recent.count))
        let rateIn = recent.reduce(0) { $0 + $1.bytesIn } / span
        let rateOut = recent.reduce(0) { $0 + $1.bytesOut } / span

        VStack(alignment: .leading, spacing: 8) {
            // Three widths, widest first, so the header never forces the pane wider than it is
            // (a header that couldn't shrink put AppKit's layout in a loop when the window was narrow).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    Text("Last five minutes").font(.headline)
                    legend("Received", .received, rateIn)
                    legend("Sent", .sent, rateOut)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    legend("Received", .received, rateIn)
                    legend("Sent", .sent, rateOut)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    legend("In", .received, rateIn)
                    legend("Out", .sent, rateOut)
                    Spacer(minLength: 0)
                }
            }
            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("Time", s.second), y: .value("Received", Double(s.bytesIn) / TrafficSample.bucket))
                        .foregroundStyle(LinearGradient(colors: [Color.received.opacity(0.28), Color.received.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.second), y: .value("Bytes", Double(s.bytesIn) / TrafficSample.bucket), series: .value("Direction", "Received"))
                        .foregroundStyle(Color.received)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.second), y: .value("Bytes", Double(s.bytesOut) / TrafficSample.bucket), series: .value("Direction", "Sent"))
                        .foregroundStyle(Color.sent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let b = v.as(Double.self) { Text(bytes(UInt64(max(0, b))) + "/s").monospacedDigit() } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .overlay {
                if samples.isEmpty {
                    Text("Traffic appears here as soon as apps send or receive data.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Traffic over the last five minutes")
            .accessibilityValue("Receiving \(bytes(rateIn)) per second, sending \(bytes(rateOut)) per second")
        }
    }

    private func legend(_ title: String, _ color: Color, _ rate: UInt64) -> some View {
        HStack(spacing: 6) {
            // fixedSize: a narrow pane must not hyphenate "Received".
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title).foregroundStyle(.secondary)
            Text(bytes(rate) + "/s").monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: System firewall

/// Without the filter: the Block List applied to macOS itself (pf for addresses, /etc/hosts for names).
struct SystemFirewallSection: View {
    @Environment(\.store) private var store
    @State private var fw = SystemFirewall.shared

    var body: some View {
        let plan = SystemFirewallPlan(rules: store.rules, seenHosts: store.seenHosts)
        let current = fw.isCurrent(plan)
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol(current: current))
                    .foregroundStyle(statusTint(current: current))
                    .font(.title3)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(current: current, plan: plan)).font(.headline)
                    Text(statusDetail(current: current, plan: plan)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            HStack(spacing: 10) {
                Button {
                    Task { await fw.apply(plan) }
                } label: {
                    Label(fw.applied == nil ? "Apply to This Mac…" : "Update This Mac…", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.shu)
                .disabled(fw.busy || current || (plan.isEmpty && fw.applied == nil))
                Button("Remove Kekkai's Rules…", role: .destructive) { Task { await fw.removeAll() } }
                    .disabled(fw.busy || fw.applied == nil)
                if fw.busy { ProgressView().controlSize(.small) }
            }
            if let error = fw.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.ask)
            }
        } header: {
            Text("System Firewall")
        } footer: {
            Text("Addresses are blocked with macOS's own pf firewall, names through /etc/hosts, for every app on this Mac. Each change asks for your administrator password. It can't block one app on its own, apps that look names up over DNS over HTTPS can get around name blocks, and address blocks reset when the Mac restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(current: Bool) -> String {
        if fw.applied == nil { return "shield" }
        if fw.clearedByRestart { return "arrow.clockwise.circle" }
        return current ? "checkmark.shield.fill" : "shield.lefthalf.filled"
    }

    private func statusTint(current: Bool) -> Color {
        if fw.applied == nil { return .secondary }
        return current ? .allow : .ask
    }

    private func statusTitle(current: Bool, plan: SystemFirewallPlan) -> String {
        if fw.applied == nil { return plan.isEmpty ? "Nothing to apply" : "Not applied" }
        if fw.clearedByRestart { return "Cleared by a restart" }
        return current ? "Applied to this Mac" : "Changes not applied yet"
    }

    private func statusDetail(current: Bool, plan: SystemFirewallPlan) -> String {
        let counts = "\(plan.addresses.count) \(plan.addresses.count == 1 ? "address" : "addresses"), \(plan.hostnames.count) \(plan.hostnames.count == 1 ? "name" : "names")"
        if fw.applied == nil {
            return plan.isEmpty ? "Add domains or addresses to the Block List first." : "Ready to block \(counts)."
        }
        if fw.clearedByRestart { return "macOS dropped the address blocks when it restarted; the name blocks are still in place. Apply again to restore them." }
        if current, let at = fw.appliedAt { return "Blocking \(counts), since \(at.formatted(date: .abbreviated, time: .shortened))." }
        return "Your Block List now has \(counts). Apply to update this Mac."
    }
}
