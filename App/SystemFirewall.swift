import Foundation
import Observation

/// Applies the Block List to macOS itself (pf for addresses, /etc/hosts for names) when the Network Extension
/// isn't available. Every change asks for an administrator password; nothing runs as root in between.
/// See `SystemFirewallPlan` for what exactly is written.
@MainActor
@Observable
final class SystemFirewall {
    static let shared = SystemFirewall()

    enum Failure: LocalizedError {
        case cancelled, unsafe, failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled. Nothing was changed."
            case .unsafe: "Kekkai refused to run a script it couldn't quote safely. Nothing was changed."
            case .failed(let why): "macOS refused the change: \(why)"
            }
        }
    }

    /// What was last installed, as Kekkai remembers it (pf and /etc/hosts need root to read back).
    private(set) var applied: SystemFirewallPlan?
    private(set) var appliedAt: Date?
    private(set) var busy = false
    private(set) var lastError: String?
    /// pf rules live in the kernel until restart; the hosts block stays.
    private(set) var clearedByRestart = false

    private let defaults = UserDefaults.standard

    private init() {
        if let a = defaults.stringArray(forKey: "fw.addresses"), let h = defaults.stringArray(forKey: "fw.hostnames") {
            applied = SystemFirewallPlan(addresses: a, hostnames: h)
            appliedAt = defaults.object(forKey: "fw.appliedAt") as? Date
            let boot = defaults.double(forKey: "fw.boot")
            clearedByRestart = !a.isEmpty && boot != 0 && abs(boot - Self.bootTime) > 1
        }
    }

    func isCurrent(_ plan: SystemFirewallPlan) -> Bool { applied == plan && !clearedByRestart }

    func apply(_ plan: SystemFirewallPlan) async {
        guard await run(plan.applyScript) else { return }
        applied = plan
        appliedAt = Date()
        clearedByRestart = false
        defaults.set(plan.addresses, forKey: "fw.addresses")
        defaults.set(plan.hostnames, forKey: "fw.hostnames")
        defaults.set(appliedAt, forKey: "fw.appliedAt")
        defaults.set(Self.bootTime, forKey: "fw.boot")
    }

    /// Applies the Block List as it is now (plus subdomains Kekkai has seen).
    func applyCurrent() async {
        let store = Store.shared
        await apply(SystemFirewallPlan(rules: store.rules, seenHosts: store.seenHosts))
    }

    func removeAll() async {
        guard await run(SystemFirewallPlan.removeScript) else { return }
        applied = nil
        appliedAt = nil
        clearedByRestart = false
        for k in ["fw.addresses", "fw.hostnames", "fw.appliedAt", "fw.boot"] { defaults.removeObject(forKey: k) }
    }

    /// Runs `shell` as root through osascript; macOS shows its own password prompt.
    private func run(_ shell: String) async -> Bool {
        guard !busy else { return false }
        if Demo.isOn { lastError = "Demo mode: nothing was changed on this Mac."; return false }
        guard let script = SystemFirewallPlan.appleScript(for: shell) else { lastError = Failure.unsafe.localizedDescription; return false }
        busy = true
        lastError = nil
        defer { busy = false }
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        guard result.0 == 0 else {
            // osascript reports a cancelled password prompt as error -128.
            lastError = result.1.contains("-128") ? Failure.cancelled.localizedDescription
                : Failure.failed(result.1.trimmingCharacters(in: .whitespacesAndNewlines)).localizedDescription
            return false
        }
        return true
    }

    private static var bootTime: Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec)
    }
}

extension SystemFirewallPlan {
    init(addresses: [String], hostnames: [String]) {
        self.init(rules: RuleSet())
        self.addresses = addresses
        self.hostnames = hostnames
    }
}
