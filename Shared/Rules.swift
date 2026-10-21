import Foundation

/// How the filter treats traffic that no rule decides.
enum FilterMode: String, Codable, CaseIterable, Identifiable {
    case blockList        // enforce block rules, allow the rest
    case requireApproval  // block rules, plus ask before a new app connects
    case allowAll         // let everything through (troubleshooting)
    case blockAll         // drop everything except loopback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blockList: "Block List"
        case .requireApproval: "Require Approval"
        case .allowAll: "Allow All"
        case .blockAll: "Block All"
        }
    }

    var summary: String {
        switch self {
        case .blockList: "Blocks the apps and domains on your list. Everything else connects."
        case .requireApproval: "New apps wait until you allow or block them. Your block list still applies."
        case .allowAll: "Every connection goes through. Rules are kept but not enforced."
        case .blockAll: "Every connection is dropped, except traffic to this Mac itself."
        }
    }
}

enum Verdict: String, Codable {
    case allow, block, ask
}

/// Everything the extension needs to decide a flow. Persisted by the extension, edited by the app.
struct RuleSet: Codable, Equatable {
    var mode: FilterMode = .blockList
    /// App key (see `AppIdentity.key`) to allowed (true) or blocked (false).
    var apps: [String: Bool] = [:]
    /// Block List destinations: domains ("example.com" also covers "ads.example.com") and IP addresses.
    var domains: [String] = []
    /// Allow List destinations. They let a connection through in Block All and skip the approval prompt.
    /// The Block List always wins over the Allow List.
    var allowDomains: [String] = []
    /// Turn the Block List off without losing it.
    var blockListEnabled = true
    /// Block All and Require Approval exceptions. On by default: without them DNS and macOS itself go dark.
    var allowApple = true
    var allowDNS = true
    /// What Require Approval does when the Kekkai app is not open to ask.
    /// false (default): behave like Block List, so the Mac stays online. true: block, the strictest choice.
    var failClosedWithoutApp = false
    /// Drop QUIC (UDP 443) when the hostname is unknown, so browsers fall back to TLS over TCP
    /// where the server name is readable and domain rules apply.
    var blockUnknownQUIC = true
    /// Seconds a held connection waits for an answer before it is blocked.
    var approvalTimeout = 60
    /// Without the filter, "block this app" means blocking the addresses only that app used (pf can't tell apps
    /// apart). App key -> the Block List entries added for it, so unblocking removes exactly those.
    var addressBlocks: [String: [String]] = [:]

    init(mode: FilterMode = .blockList, apps: [String: Bool] = [:], domains: [String] = [], allowDomains: [String] = []) {
        self.mode = mode
        self.apps = apps
        self.domains = domains
        self.allowDomains = allowDomains
    }

    /// Tolerates missing keys, so rules saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(FilterMode.self, forKey: .mode) ?? .blockList
        apps = try c.decodeIfPresent([String: Bool].self, forKey: .apps) ?? [:]
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        allowDomains = try c.decodeIfPresent([String].self, forKey: .allowDomains) ?? []
        blockListEnabled = try c.decodeIfPresent(Bool.self, forKey: .blockListEnabled) ?? true
        allowApple = try c.decodeIfPresent(Bool.self, forKey: .allowApple) ?? true
        allowDNS = try c.decodeIfPresent(Bool.self, forKey: .allowDNS) ?? true
        failClosedWithoutApp = try c.decodeIfPresent(Bool.self, forKey: .failClosedWithoutApp) ?? false
        blockUnknownQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockUnknownQUIC) ?? true
        approvalTimeout = min(300, max(10, try c.decodeIfPresent(Int.self, forKey: .approvalTimeout) ?? 60))
        addressBlocks = try c.decodeIfPresent([String: [String]].self, forKey: .addressBlocks) ?? [:]
    }

    // MARK: Entries

    static func normalize(domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while d.hasSuffix(".") { d.removeLast() }
        while d.hasPrefix("*.") || d.hasPrefix(".") { d.removeFirst(d.hasPrefix("*.") ? 2 : 1) }
        if d.hasPrefix("["), d.hasSuffix("]") { d = String(d.dropFirst().dropLast()) }
        return d
    }

    /// Loopback, private, link-local, carrier-grade NAT (Tailscale lives there) and unique-local addresses:
    /// never worth blocking, and blocking them can cut off the local network.
    static func isPrivate(_ ip: String) -> Bool {
        let v4 = ip.split(separator: ".").compactMap { Int($0) }
        if v4.count == 4 {
            switch (v4[0], v4[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127): return true
            default: return v4[0] >= 224
            }
        }
        let l = ip.lowercased()
        return l == "::1" || l == "::" || l.hasPrefix("fe80:") || l.hasPrefix("fc") || l.hasPrefix("fd") || l.hasPrefix("ff")
    }

    static func isIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// One valid entry (domain, wildcard domain or IP address), normalised; nil when it is not one.
    static func entry(_ raw: String) -> String? {
        let d = normalize(domain: raw)
        if isIP(d) { return d }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !d.isEmpty, d.count <= 253, d.allSatisfy(allowed.contains), !d.contains(".."),
              !d.hasPrefix("-"), !d.hasSuffix("-") else { return nil }
        return d
    }

    /// Entries from pasted text, split on commas, spaces and new lines. Returns the valid ones and the rejects.
    static func entries(from text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = [], invalid: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) where !part.isEmpty {
            if let e = entry(String(part)) { if !valid.contains(e) { valid.append(e) } } else { invalid.append(String(part)) }
        }
        return (valid, invalid)
    }

    /// The first entry in `list` that covers this destination: an IP matches exactly, a domain by suffix.
    static func match(_ list: [String], host: String?, ip: String?) -> String? {
        let h = host.map(normalize(domain:))
        let a = ip.map(normalize(domain:))
        return list.first { e in
            if let a, a == e { return true }
            guard let h, !isIP(e) else { return false }
            return h == e || h.hasSuffix("." + e)
        }
    }

    /// The Block List entry that blocks this destination, if the Block List is on.
    func blockingRule(host: String?, ip: String? = nil) -> String? {
        blockListEnabled ? Self.match(domains, host: host, ip: ip) : nil
    }

    func allowingRule(host: String?, ip: String? = nil) -> String? { Self.match(allowDomains, host: host, ip: ip) }

    /// Kept for callers that only have a host.
    func blockingDomain(for host: String) -> String? { blockingRule(host: host) }
    func blocks(host: String) -> Bool { blockingRule(host: host) != nil }

    // MARK: Decision

    /// Decides a new connection and says why.
    /// - `isApple`: Apple-signed code. `dns`: outbound UDP to port 53. `quic`: UDP to port 443.
    /// - `appOpen`: whether the Kekkai app is there to answer an approval.
    func decide(app: String, isApple: Bool, host: String?, ip: String? = nil, loopback: Bool,
                quic: Bool = false, dns: Bool = false, appOpen: Bool = true) -> (verdict: Verdict, reason: String?) {
        if loopback { return (.allow, nil) }
        if mode == .allowAll { return (.allow, nil) }

        // Explicit blocks first: the narrowest "no" always wins.
        if apps[app] == false { return (.block, "App rule") }
        if let rule = blockingRule(host: host, ip: ip) { return (.block, "Block List: \(rule)") }

        // Explicit allows.
        if let rule = allowingRule(host: host, ip: ip) { return (.allow, "Allow List: \(rule)") }
        if apps[app] == true { return (.allow, "App rule") }

        switch mode {
        case .allowAll:
            return (.allow, nil)
        case .blockAll:
            if dns, allowDNS { return (.allow, "DNS exception") }
            if isApple, allowApple { return (.allow, "Apple exception") }
            return (.block, "Block All mode")
        case .blockList, .requireApproval:
            if quic, host == nil, blockUnknownQUIC, blockListEnabled, !domains.isEmpty {
                return (.block, "QUIC with a hidden hostname")
            }
            guard mode == .requireApproval else { return (.allow, nil) }
            if dns, allowDNS { return (.allow, "DNS exception") }
            if isApple, allowApple { return (.allow, "Apple exception") }
            if !appOpen {
                return failClosedWithoutApp ? (.block, "Kekkai was not open to ask") : (.allow, "Kekkai was not open; Block List only")
            }
            return (.ask, nil)
        }
    }

    func verdict(app: String, isApple: Bool, host: String?, ip: String? = nil, loopback: Bool,
                 quic: Bool = false, dns: Bool = false, appOpen: Bool = true) -> Verdict {
        decide(app: app, isApple: isApple, host: host, ip: ip, loopback: loopback, quic: quic, dns: dns, appOpen: appOpen).verdict
    }
}

/// Who made a connection, derived from its code signature.
struct AppIdentity: Codable, Hashable {
    var signingID: String?
    var teamID: String?
    var isApple: Bool
    var path: String

    /// Rule key. Includes the team so an ad-hoc binary cannot borrow a signed app's identifier and its allow rule.
    var key: String {
        if isApple, let signingID { return "apple:\(signingID)" }
        if let teamID, let signingID { return "\(teamID):\(signingID)" }
        return "path:\(path)"
    }

    /// "Dia", "Dia · Browser Helper" for a helper inside an app, "Microsoft Teams · WebView" (the app's own name
    /// is not repeated), "claude" for ~/.local/.../claude/versions/2.1.3.
    var displayName: String {
        let parts = path.split(separator: "/").map(String.init)
        let bundles = parts.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        if let outer = bundles.first {
            guard bundles.count > 1, let inner = bundles.last, inner != outer else { return outer }
            let part = inner.hasPrefix(outer + " ") ? String(inner.dropFirst(outer.count + 1)) : inner
            return "\(outer) · \(part)"
        }
        // A bare version number says nothing; use the folder it is versioned under.
        let isVersion = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." } }
        if let name = parts.last(where: { !isVersion($0) && $0 != "versions" && $0 != "bin" }) ?? parts.last, !name.isEmpty {
            return name
        }
        return signingID ?? "Unknown"
    }

    var signatureSummary: String {
        if isApple { return "Apple" }
        if teamID != nil { return "Developer ID" }
        if signingID != nil { return "Ad-hoc signature" }
        return "Unsigned"
    }
}
