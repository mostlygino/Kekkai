import Foundation

/// Blocking without the Network Extension: the Block List applied to macOS itself, as root, through
/// `osascript … with administrator privileges` (one password prompt per change).
///
/// - IP addresses go into a pf table in the anchor `com.apple/kekkai`. Apple's /etc/pf.conf already evaluates
///   `anchor "com.apple/*"`, so nothing in pf.conf is edited. pf has no idea which app made a connection,
///   so this blocks the address for every app.
/// - Domains go into a marked block in /etc/hosts (`0.0.0.0` and `::`), with every subdomain Kekkai has seen.
///   Exact names, no collateral damage on shared CDN addresses; apps that resolve with DNS over HTTPS skip it.
///
/// Everything here is pure, so `scripts/check.sh` tests it. Entries come from `RuleSet.entry`, which only lets
/// through letters, digits, `.`, `-`, `_` and IP addresses; content reaches the root script base64-encoded,
/// never as shell text.
struct SystemFirewallPlan: Equatable {
    static let anchor = "com.apple/kekkai"
    static let anchorFile = "/etc/pf.anchors/com.mostlygino.kekkai"
    static let tokenFile = "/var/db/com.mostlygino.kekkai.pftoken"
    static let hostsBegin = "# BEGIN Kekkai (managed by Kekkai; remove from the app, not by hand)"
    static let hostsEnd = "# END Kekkai"

    var addresses: [String]
    var hostnames: [String]

    /// `seenHosts`: hostnames Kekkai has seen, so subdomains of a blocked domain are covered too.
    init(rules: RuleSet, seenHosts: [String] = []) {
        let entries = rules.blockListEnabled ? rules.domains.compactMap(RuleSet.entry) : []
        addresses = entries.filter(RuleSet.isIP).sorted()
        let domains = entries.filter { !RuleSet.isIP($0) }
        var names = Set<String>()
        for d in domains {
            names.insert(d)
            if d.split(separator: ".").count == 2 { names.insert("www." + d) }
            for h in seenHosts {
                let n = RuleSet.normalize(domain: h)
                if n.hasSuffix("." + d), RuleSet.entry(n) == n { names.insert(n) }
            }
        }
        hostnames = names.sorted()
    }

    var isEmpty: Bool { addresses.isEmpty && hostnames.isEmpty }

    /// pf anchor: one table, blocked both ways. Empty when there are no addresses.
    var anchorText: String {
        guard !addresses.isEmpty else { return "" }
        return """
        table <kekkai_block> persist { \(addresses.joined(separator: ", ")) }
        block drop out quick to <kekkai_block>
        block drop in quick from <kekkai_block>

        """
    }

    /// The managed /etc/hosts block, or "" when there are no domains.
    var hostsBlock: String {
        guard !hostnames.isEmpty else { return "" }
        var lines = [Self.hostsBegin]
        for h in hostnames { lines.append("0.0.0.0 \(h)"); lines.append(":: \(h)") }
        lines.append(Self.hostsEnd)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Strips the managed block from /etc/hosts into a temporary file next to it, then moves it into place.
    private static let stripHosts = """
    /usr/bin/awk -v b='# BEGIN Kekkai' -v e='# END Kekkai' 'index($0,b)==1{s=1} !s{print} index($0,e)==1{s=0}' /etc/hosts > /etc/hosts.kekkai-new
    """

    private static let flushDNS = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; true"

    /// Root shell script that installs this plan. Contains no double quotes or backslashes, so it can be
    /// placed in an AppleScript string as is.
    var applyScript: String {
        let anchor64 = Data(anchorText.utf8).base64EncodedString()
        let hosts64 = Data(hostsBlock.utf8).base64EncodedString()
        return [
            "set -e",
            "umask 022",
            "/bin/mkdir -p /etc/pf.anchors",
            "echo '\(anchor64)' | /usr/bin/base64 -D > \(Self.anchorFile)",
            addresses.isEmpty
                ? "/sbin/pfctl -a \(Self.anchor) -F all >/dev/null 2>&1 || true"
                : "/sbin/pfctl -a \(Self.anchor) -f \(Self.anchorFile) >/dev/null 2>&1",
            // Enable pf with a reference (-E) and keep the token, so removing releases only Kekkai's reference.
            addresses.isEmpty ? "true"
                : "[ -s \(Self.tokenFile) ] || /sbin/pfctl -E 2>&1 | /usr/bin/awk '/Token/{print $NF}' > \(Self.tokenFile)",
            "[ -f /etc/hosts.kekkai-backup ] || /bin/cp /etc/hosts /etc/hosts.kekkai-backup",
            Self.stripHosts,
            "echo '\(hosts64)' | /usr/bin/base64 -D >> /etc/hosts.kekkai-new",
            "/bin/chmod 644 /etc/hosts.kekkai-new",
            "/bin/mv /etc/hosts.kekkai-new /etc/hosts",
            Self.flushDNS,
        ].joined(separator: "\n")
    }

    /// Root shell script that removes everything Kekkai put in place.
    static var removeScript: String {
        [
            "/sbin/pfctl -a \(anchor) -F all >/dev/null 2>&1 || true",
            "[ -s \(tokenFile) ] && /sbin/pfctl -X $(/bin/cat \(tokenFile)) >/dev/null 2>&1 || true",
            "/bin/rm -f \(tokenFile) \(anchorFile)",
            stripHosts,
            "/bin/chmod 644 /etc/hosts.kekkai-new",
            "/bin/mv /etc/hosts.kekkai-new /etc/hosts",
            flushDNS,
        ].joined(separator: "\n")
    }

    /// `do shell script "…" with administrator privileges`, for `osascript -e`.
    static func appleScript(for shell: String) -> String? {
        guard !shell.contains("\""), !shell.contains("\\") else { return nil }
        return "do shell script \"\(shell)\" with administrator privileges"
    }
}
