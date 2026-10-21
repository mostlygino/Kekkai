import Darwin
import Foundation

/// Watch mode: real connections from macOS's own `nettop`, without the filter. Needs no extension, no
/// entitlements and no admin rights, so it works in any build. It can see, not block: every event is
/// marked "Watching only", and hostnames are unknown (that needs the filter's DNS and TLS reading).
@MainActor
final class Watcher {
    static let shared = Watcher()

    private var process: Process?
    private var known: [String: (flowID: UUID, bytesIn: UInt64, bytesOut: UInt64, event: FlowEvent)] = [:]
    private weak var store: Store?

    var isRunning: Bool { process?.isRunning == true }

    func start(_ store: Store) {
        guard !isRunning, !Demo.isOn else { return }
        self.store = store
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -L 0: log samples for ever, -s 2: every two seconds, -n: no name lookups, -x: raw byte counts.
        p.arguments = ["-L", "0", "-s", "2", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        var parser = NettopParser()
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            var samples: [[NettopConnection]] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = parser.feed(Substring(line)) { samples.append(s) }
            }
            guard !samples.isEmpty else { return }
            // Who each process is gets worked out here, off the main thread: reading a signature takes a while.
            let resolved = samples.map { sample in sample.map { ($0, Identities.shared.identity(pid: $0.pid, name: $0.process)) } }
            Task { @MainActor in for s in resolved { self?.apply(s) } }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.store?.setWatching(false)
            }
        }
        do {
            try p.run()
            process = p
            UserDefaults.standard.set(false, forKey: "blockedOnly")
            store.setWatching(true)
        } catch {
            NSLog("Kekkai: nettop failed to start: \(error.localizedDescription)")
            store.setWatching(false)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        // Close what we were tracking, so the tables don't show stale open connections.
        let closing = known.values.map { v -> FlowEvent in var e = v.event; e.kind = .closed; e.bytesIn = 0; e.bytesOut = 0; e.date = Date(); return e }
        known = [:]
        store?.ingest(closing)
        store?.setWatching(false)
    }

    /// Turns a sample into the same events the filter sends: opened, bytes since the last sample, closed.
    private func apply(_ sample: [(NettopConnection, AppIdentity)]) {
        guard let store else { return }
        var events: [FlowEvent] = []
        var seen = Set<String>()
        let now = Date()
        for (c, app) in sample {
            let key = c.key
            seen.insert(key)
            if let k = known[key] {
                // Totals only grow; a smaller number means nettop reused the row, so count from zero.
                let dIn = c.bytesIn >= k.bytesIn ? c.bytesIn - k.bytesIn : c.bytesIn
                let dOut = c.bytesOut >= k.bytesOut ? c.bytesOut - k.bytesOut : c.bytesOut
                known[key] = (k.flowID, c.bytesIn, c.bytesOut, k.event)
                if dIn + dOut > 0 {
                    var e = k.event; e.kind = .bytes; e.bytesIn = dIn; e.bytesOut = dOut; e.date = now
                    events.append(e)
                }
            } else {
                let pfBlocked = SystemFirewall.shared.applied?.addresses.contains(c.remoteIP) == true
                let opened = FlowEvent(kind: .opened, flowID: UUID(), app: app, host: nil, ip: c.remoteIP, port: c.remotePort,
                                       proto: c.proto, inbound: false, verdict: pfBlocked ? .block : .allow,
                                       reason: pfBlocked ? "System firewall" : "Watching only", date: now)
                known[key] = (opened.flowID, c.bytesIn, c.bytesOut, opened)
                events.append(opened)
                if c.bytesIn + c.bytesOut > 0 {
                    var e = opened; e.kind = .bytes; e.bytesIn = c.bytesIn; e.bytesOut = c.bytesOut
                    events.append(e)
                }
            }
        }
        for (key, k) in known where !seen.contains(key) {
            var e = k.event; e.kind = .closed; e.bytesIn = 0; e.bytesOut = 0; e.date = now
            events.append(e)
            known[key] = nil
        }
        store.ingest(events)
    }

}

/// Path and signature per process, cached, safe to call from any thread.
final class Identities: @unchecked Sendable {
    static let shared = Identities()
    private let lock = NSLock()
    /// pid and name -> identity, so a reused pid for another program isn't mistaken for the old one.
    private var byProcess: [String: AppIdentity] = [:]
    /// path -> signature, so the same program (many Chrome helpers, every curl) is only read once.
    private var byPath: [String: (String?, String?, Bool)] = [:]

    /// ponytail: pid lookup is racy for processes that exit between samples; their name falls back to nettop's.
    func identity(pid: Int32, name: String) -> AppIdentity {
        let key = "\(pid)|\(name)"
        if let hit = lock.withLock({ byProcess[key] }) { return hit }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            return AppIdentity(signingID: nil, teamID: nil, isApple: false, path: name)
        }
        var path = String(cString: buf)
        if let r = path.range(of: ".app/Contents/MacOS/") { path = String(path[..<r.lowerBound]) + ".app" }
        let sig = lock.withLock({ byPath[path] }) ?? {
            let s = SignatureInfo.quickIdentity(path: path)
            return (s.identifier, s.teamID, s.isApple)
        }()
        let id = AppIdentity(signingID: sig.0, teamID: sig.1, isApple: sig.2, path: path)
        lock.withLock {
            if byProcess.count > 4000 { byProcess.removeAll() }
            byProcess[key] = id
            byPath[path] = sig
        }
        return id
    }
}
