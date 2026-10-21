import Foundation
import os

let log = Logger(subsystem: IPC.extensionBundleID, category: "filter")

/// The extension owns the rules, so they apply even when the app is not running.
final class RuleStore {
    static let shared = RuleStore()

    private let lock = NSLock()
    private var current = RuleSet()
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kekkai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("rules.json")
        if let data = try? Data(contentsOf: url) {
            do { current = try IPC.decoder.decode(RuleSet.self, from: data) }
            catch { log.error("rules.json unreadable, starting from defaults: \(error.localizedDescription, privacy: .public)") }
        }
    }

    var rules: RuleSet { lock.withLock { current } }

    func update(_ change: (inout RuleSet) -> Void) {
        let snapshot: RuleSet = lock.withLock {
            change(&current)
            current.domains = Array(Set(current.domains.map(RuleSet.normalize(domain:)).filter { !$0.isEmpty })).sorted()
            return current
        }
        do { try IPC.encoder.encode(snapshot).write(to: url, options: .atomic) }
        catch { log.error("saving rules failed: \(error.localizedDescription, privacy: .public)") }
    }
}
