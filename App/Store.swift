import AppKit
import Foundation
import Observation

struct Destination: Identifiable, Codable {
    var id: String { name }
    var name: String            // host name, or the IP when no name is known
    var host: String?
    var ips: Set<String> = []
    var ports: Set<String> = []
    var country: String?
    var connections = 0
    var blocked = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var lastSeen = Date.distantPast
    var apps: Set<String> = []  // app keys, filled when destinations are merged across apps
    var total: UInt64 { bytesIn + bytesOut }
}

struct AppTraffic: Identifiable, Codable {
    var id: String { app.key }
    var app: AppIdentity
    var destinations: [String: Destination] = [:]
    var connections = 0
    var blocked = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var lastSeen = Date.distantPast
}

struct TrafficSample: Identifiable, Codable {
    /// Seconds per sample.
    static let bucket: TimeInterval = 5
    var id: Date { second }
    var second: Date
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
}

/// How far back the tables look.
enum TimeScope: String, CaseIterable, Identifiable {
    case fiveMinutes, hour, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fiveMinutes: "Last 5 Minutes"
        case .hour: "Last Hour"
        case .day: "Last Day"
        case .week: "Last Week"
        case .month: "Last 30 Days"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: 300
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }
}

/// Live view of the filter: traffic, the rules, and apps waiting for approval. Main thread only.
@Observable
final class Store {
    static let shared = Store()

    private(set) var rules = RuleSet()
    private(set) var connected = false
    /// Watch mode: traffic from nettop, nothing filtered. See `Watcher`.
    private(set) var watching = false
    private(set) var apps: [String: AppTraffic] = [:]
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var samples: [TrafficSample] = []
    /// Newest first. Opened and decided connections only.
    private(set) var activity: [FlowEvent] = []
    /// When the history on screen started, or nil for a fresh session.
    private(set) var resumedFrom: Date?

    @ObservationIgnored private var flows: [UUID: FlowEvent] = [:]
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private lazy var receiver = Receiver(store: self)
    @ObservationIgnored private var shouldConnect = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored let isDemo = Demo.isOn
    @ObservationIgnored var onApprovalsChanged: (([ApprovalRequest]) -> Void)?

    /// Navigation requests from anywhere (context menus, menu bar) for the main window to follow.
    var requestedPane: Pane?
    /// Set to show the first-run welcome again (Help menu, Settings).
    var welcomeRequested = false
    /// The app the inspector shows (set by the Apps pane's selection).
    var inspectedApp: String?
    var requestedSearch: String?
    var mapFocus: String?
    /// Bumped whenever a connection is blocked, for the menu bar pulse.
    private(set) var blockedTick = 0

    /// History older than this is dropped.
    static let retention: TimeInterval = 30 * 86_400

    init() {
        guard !isDemo else { return }
        loadLocalRules()
        loadHistory()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.saveHistory() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveHistory()
        }
    }

    // MARK: Derived

    /// Apps seen within `scope`, optionally only those with blocked connections.
    func apps(in scope: TimeScope, blockedOnly: Bool) -> [AppTraffic] {
        let cutoff = Date().addingTimeInterval(-scope.seconds)
        return apps.values.compactMap { a in
            var a = a
            a.destinations = a.destinations.filter { $0.value.lastSeen >= cutoff && (!blockedOnly || $0.value.blocked > 0) }
            return a.destinations.isEmpty ? nil : a
        }
    }

    /// The most recent blocked connections, one per app and destination.
    var recentlyBlocked: [FlowEvent] {
        var seen = Set<String>(), out: [FlowEvent] = []
        for e in activity where e.verdict == .block {
            let key = e.app.key + "|" + (e.host ?? e.ip)
            if seen.insert(key).inserted { out.append(e) }
            if out.count == 6 { break }
        }
        return out
    }

    func show(_ pane: Pane, country: String? = nil, search: String? = nil) {
        mapFocus = country
        requestedSearch = search
        requestedPane = pane
        AppDelegate.openMain?()
    }

    /// Forgets an app's traffic. Its rule, if any, stays.
    func removeFromHistory(_ key: String) {
        apps[key] = nil
        activity.removeAll { $0.app.key == key }
        revision &+= 1
    }

    /// Bumped on every traffic change; the derived lists below are cached against it.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var destinationsCache: (revision: Int, value: [Destination])?
    @ObservationIgnored private var seenHostsCache: (revision: Int, value: [String])?

    /// Destinations merged across apps. Cached: several views read it on every update.
    var destinations: [Destination] {
        _ = apps   // registers the dependency for SwiftUI even when the cache answers
        if let c = destinationsCache, c.revision == revision { return c.value }
        var merged: [String: Destination] = [:]
        for app in apps.values {
            for d in app.destinations.values {
                var m = merged[d.name] ?? Destination(name: d.name, host: d.host, country: d.country)
                m.ips.formUnion(d.ips); m.ports.formUnion(d.ports); m.apps.insert(app.id)
                m.connections += d.connections; m.blocked += d.blocked
                m.bytesIn += d.bytesIn; m.bytesOut += d.bytesOut
                m.lastSeen = max(m.lastSeen, d.lastSeen)
                m.country = m.country ?? d.country
                merged[d.name] = m
            }
        }
        let value = Array(merged.values)
        destinationsCache = (revision, value)
        return value
    }

    var totals: (connections: Int, blocked: Int, bytesIn: UInt64, bytesOut: UInt64) {
        apps.values.reduce((0, 0, 0, 0)) { ($0.0 + $1.connections, $0.1 + $1.blocked, $0.2 + $1.bytesIn, $0.3 + $1.bytesOut) }
    }

    // MARK: Rules

    func update(_ change: (inout RuleSet) -> Void) {
        change(&rules)
        rules.domains = Array(Set(rules.domains.map(RuleSet.normalize(domain:)).filter { !$0.isEmpty })).sorted()
        guard let data = try? IPC.encoder.encode(rules) else { return }
        // The extension owns the rules while it runs; without it they live here, for the system firewall.
        if connected { provider?.setRules(data) } else if !isDemo { saveLocalRules(data) }
    }

    /// Rules can be edited without the extension (applied through the system firewall instead).
    var canEditLists: Bool { connected || !isDemo || Demo.offline }

    private static var localRulesURL: URL {
        historyURL.deletingLastPathComponent().appendingPathComponent("rules.json")
    }

    private func loadLocalRules() {
        guard let data = try? Data(contentsOf: Self.localRulesURL) else { return }
        do { rules = try IPC.decoder.decode(RuleSet.self, from: data) }
        catch { NSLog("Kekkai: local rules unreadable, starting empty: \(error.localizedDescription)") }
    }

    private func saveLocalRules(_ data: Data) {
        do { try data.write(to: Self.localRulesURL, options: .atomic) }
        catch { NSLog("Kekkai: saving local rules failed: \(error.localizedDescription)") }
    }

    // MARK: Blocking one app without the filter

    /// Hosts and addresses this app reached that no other app did. Blocking these is the closest the system
    /// firewall gets to blocking one app, without cutting other apps off shared servers.
    func exclusiveEntries(for key: String) -> [String] {
        guard let mine = apps[key] else { return [] }
        var others = Set<String>()
        for (k, a) in apps where k != key {
            for d in a.destinations.values { others.formUnion(d.ips); if let h = d.host { others.insert(h) } }
        }
        var out: [String] = []
        for d in mine.destinations.values {
            if let h = d.host, !others.contains(h), let e = RuleSet.entry(h) { out.append(e) }
            for ip in d.ips where !others.contains(ip) && !RuleSet.isPrivate(ip) {
                if let e = RuleSet.entry(ip) { out.append(e) }
            }
        }
        return Array(Set(out)).sorted()
    }

    func isAddressBlocked(_ key: String) -> Bool { rules.addressBlocks[key] != nil }

    /// Adds the app's own addresses to the Block List and remembers them under the app; applying is separate.
    func blockByAddress(_ key: String) {
        let entries = exclusiveEntries(for: key)
        update { r in
            let added = entries.filter { !r.domains.contains($0) }
            r.addressBlocks[key] = added
            r.domains += added
            r.apps[key] = false          // so the filter blocks it outright once it runs
        }
    }

    func unblockByAddress(_ key: String) {
        let entries = rules.addressBlocks[key] ?? []
        update { r in
            r.domains.removeAll { entries.contains($0) }
            r.addressBlocks[key] = nil
            if r.apps[key] == false { r.apps[key] = nil }
        }
    }

    /// Watch mode: an address-blocked app that reaches somewhere new (and nobody else's) gets that added too.
    /// The "not applied yet" bar then offers to apply it.
    private func extendAddressBlock(_ e: FlowEvent) {
        guard !connected, let added = rules.addressBlocks[e.app.key], !RuleSet.isPrivate(e.ip),
              let entry = RuleSet.entry(e.ip), !rules.domains.contains(entry), !added.contains(entry) else { return }
        let usedByOthers = apps.contains { k, a in k != e.app.key && a.destinations.values.contains { $0.ips.contains(e.ip) } }
        guard !usedByOthers else { return }
        update { r in
            r.addressBlocks[e.app.key, default: []].append(entry)
            r.domains.append(entry)
        }
    }

    /// Hostnames seen in traffic, so a blocked domain's subdomains can go into the system firewall too.
    var seenHosts: [String] {
        _ = apps
        if let c = seenHostsCache, c.revision == revision { return c.value }
        let value = Array(Set(apps.values.flatMap { $0.destinations.values.compactMap(\.host) }))
        seenHostsCache = (revision, value)
        return value
    }

    func replaceRules(_ new: RuleSet) { update { $0 = new } }

    func decide(_ request: ApprovalRequest, allow: Bool, remember: Bool) {
        approvals.removeAll { $0.id == request.id }
        onApprovalsChanged?(approvals)
        if remember { rules.apps[request.app.key] = allow }
        if isDemo {
            ingest([FlowEvent(kind: .opened, flowID: UUID(), app: request.app, host: request.hosts.first,
                              ip: request.ips.first ?? "", port: request.ports.first ?? "443", proto: "TCP",
                              inbound: false, verdict: allow ? .allow : .block, reason: allow ? "Allowed by you" : "Blocked by you")])
        }
        provider?.decide(appKey: request.app.key, allow: allow, remember: remember)
    }

    // MARK: History

    func clearHistory() {
        apps = [:]; samples = []; activity = []; flows = [:]; resumedFrom = nil; revision &+= 1
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    private struct History: Codable { var apps: [String: AppTraffic]; var samples: [TrafficSample]; var since: Date }
    @ObservationIgnored private var since = Date()

    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kekkai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let h = try? JSONDecoder().decode(History.self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        apps = h.apps.compactMapValues { a in
            var a = a
            a.destinations = a.destinations.filter { $0.value.lastSeen >= cutoff }
            return a.destinations.isEmpty ? nil : a
        }
        // The chart covers the last five minutes; older samples would draw a stale line after a relaunch.
        samples = h.samples.filter { $0.second > Date().addingTimeInterval(-300) }
        since = h.since
        resumedFrom = h.apps.isEmpty ? nil : h.since
        revision &+= 1
    }

    func saveHistory() {
        guard !isDemo else { return }
        let h = History(apps: apps, samples: samples, since: since)
        do { try JSONEncoder().encode(h).write(to: Self.historyURL, options: .atomic) }
        catch { NSLog("Kekkai: saving history failed: \(error.localizedDescription)") }
    }

    // MARK: XPC

    private var provider: ProviderXPC? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? ProviderXPC
    }

    private static var machServiceName: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(IPC.extensionBundleID).systemextension")
        let ne = Bundle(url: url)?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        return ne?["NEMachServiceName"] as? String
    }

    func connect() {
        if isDemo { connected = true; return }
        shouldConnect = true
        guard connection == nil, let name = Self.machServiceName else { return }
        let c = NSXPCConnection(machServiceName: name, options: [])
        // Only talk to our own extension. With no team configured this never matches, which is the safe failure.
        c.setCodeSigningRequirement(IPC.requirement(identifier: IPC.extensionBundleID, team: IPC.teamID))
        c.remoteObjectInterface = NSXPCInterface(with: ProviderXPC.self)
        c.exportedInterface = NSXPCInterface(with: AppXPC.self)
        c.exportedObject = receiver
        let lost = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connection = nil
                self.connected = false
                guard self.shouldConnect else { return }
                if self.failures == 0 { NSLog("Kekkai: lost the filter extension, retrying") }
                self.failures += 1
                // Back off to 30 s while the extension is not there.
                DispatchQueue.main.asyncAfter(deadline: .now() + min(30, 3 * Double(self.failures))) { self.connect() }
            }
        }
        c.invalidationHandler = lost
        c.interruptionHandler = lost
        c.resume()
        connection = c
        provider?.register { [weak self] data in
            let rules = try? IPC.decoder.decode(RuleSet.self, from: data)
            DispatchQueue.main.async {
                guard let self else { return }
                if let rules { self.rules = rules }
                self.connected = true
                self.failures = 0
            }
        }
    }

    func disconnect() {
        guard !isDemo else { return }
        shouldConnect = false
        connection?.invalidate()
    }

    // MARK: Events (also fed by Demo)

    func ingest(_ events: [FlowEvent]) {
        for e in events {
            switch e.kind {
            case .opened:
                if let old = flows[e.flowID] { count(old, -1) } else { addToActivity(e); extendAddressBlock(e) }
                if e.verdict == .block { blockedTick &+= 1 }
                count(e, 1)
                if let i = activity.firstIndex(where: { $0.flowID == e.flowID }) { activity[i] = e }
                // Blocked flows are final; nothing more will arrive for them.
                if e.verdict == .block { flows[e.flowID] = nil } else { flows[e.flowID] = e }
            case .bytes, .closed:
                addBytes(e)
                if e.kind == .closed { flows[e.flowID] = nil }
            }
        }
        if activity.count > 600 { activity.removeLast(activity.count - 500) }
    }

    func setWatching(_ on: Bool) { watching = on }

    /// A new connection that matches a recent row (same app, destination, port and verdict, within a minute)
    /// folds into it as a repeat, so a chatty app reads as one line with a count, not a screenful.
    private func addToActivity(_ e: FlowEvent) {
        let same = { (a: FlowEvent) in
            a.app.key == e.app.key && (a.host ?? a.ip) == (e.host ?? e.ip) && a.port == e.port
                && a.verdict == e.verdict && a.reason == e.reason && e.date.timeIntervalSince(a.date) < 60
        }
        if let i = activity.prefix(16).firstIndex(where: same) {
            var merged = activity.remove(at: i)
            merged.repeats = (merged.repeats ?? 1) + 1
            merged.date = e.date
            activity.insert(merged, at: 0)
        } else {
            activity.insert(e, at: 0)
        }
    }

    func setApprovals(_ requests: [ApprovalRequest]) {
        approvals = requests.sorted { $0.since < $1.since }
        onApprovalsChanged?(approvals)
    }

    // Both mutate through the dictionaries' in-place accessors: copying an app out and back in would copy its
    // whole destination table on every event.

    private func count(_ e: FlowEvent, _ n: Int) {
        let key = e.host ?? e.ip
        let blocked = e.verdict == .block ? n : 0
        var drop = false
        update(app: e.app) { app in
            app.connections += n; app.blocked += blocked
            if n > 0 { app.lastSeen = e.date }
            app.destinations[key, default: Destination(name: key, host: e.host, country: GeoIP.country(for: e.ip))].modify { d in
                d.connections += n; d.blocked += blocked
                if n > 0 {
                    d.ips.insert(e.ip); d.ports.insert(e.port); d.lastSeen = e.date
                    if d.country == nil { d.country = GeoIP.country(for: e.ip) }
                }
                drop = d.connections <= 0 && d.bytesIn + d.bytesOut == 0
            }
            if drop { app.destinations[key] = nil }
        }
    }

    private func addBytes(_ e: FlowEvent) {
        guard e.bytesIn + e.bytesOut > 0 else { return }
        let key = e.host ?? e.ip
        update(app: e.app) { app in
            app.bytesIn += e.bytesIn; app.bytesOut += e.bytesOut; app.lastSeen = e.date
            app.destinations[key, default: Destination(name: key, host: e.host, ips: [e.ip], country: GeoIP.country(for: e.ip))].modify { d in
                d.bytesIn += e.bytesIn; d.bytesOut += e.bytesOut; d.lastSeen = e.date
            }
        }

        // One sample per 5 seconds: 60 points cover the chart's five minutes.
        let t = e.date.timeIntervalSince1970
        let bucket = Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: TrafficSample.bucket))
        if let i = samples.lastIndex(where: { $0.second == bucket }) {
            samples[i].bytesIn += e.bytesIn
            samples[i].bytesOut += e.bytesOut
        } else {
            samples.append(TrafficSample(second: bucket, bytesIn: e.bytesIn, bytesOut: e.bytesOut))
            if samples.count > 1, samples[samples.count - 2].second > bucket { samples.sort { $0.second < $1.second } }
            let cutoff = (samples.last?.second ?? bucket).addingTimeInterval(-300)
            if let first = samples.first, first.second < cutoff { samples.removeAll { $0.second < cutoff } }
        }
    }

    private func update(app identity: AppIdentity, _ change: (inout AppTraffic) -> Void) {
        change(&apps[identity.key, default: AppTraffic(app: identity)])
        revision &+= 1
    }
}

/// XPC entry point for the extension. Decodes off the main thread, then hands over to the store.
private final class Receiver: NSObject, AppXPC {
    weak var store: Store?
    init(store: Store) { self.store = store }

    func flowEvents(_ events: Data) {
        guard let list = try? IPC.decoder.decode([FlowEvent].self, from: events) else { return }
        DispatchQueue.main.async { self.store?.ingest(list) }
    }

    func approvals(_ requests: Data) {
        guard let list = try? IPC.decoder.decode([ApprovalRequest].self, from: requests) else { return }
        DispatchQueue.main.async { self.store?.setApprovals(list) }
    }
}

private extension Destination {
    /// Lets a dictionary's in-place `[key, default:]` accessor take a closure.
    mutating func modify(_ change: (inout Destination) -> Void) { change(&self) }
}
