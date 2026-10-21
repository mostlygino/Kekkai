// Runnable check for the pure filter logic. Run: scripts/check.sh
import Foundation

func hex(_ s: String) -> [UInt8] {
    var out = [UInt8](); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return out
}

// Real ClientHello captured from curl connecting to sni-check.example.org.
let hello = hex("1603010146010001420303034329bbe5534670054d13153d7115f6c25585085a396c097cb14d10599b2683205c074a120bdb9ccc5884771714d3a03f90d9e5a45b0278d026b60a1ff3d5a6b40062130313021301cca9cca8ccaac030c02cc028c024c014c00a009f006b0039ff8500c400880081009d003d003500c00084c02fc02bc027c023c013c009009e0067003300be0045009c003c002f00ba0041c011c00700050004c012c0080016000a00ff01000097002b0009080304030303020301003300260024001d0020aabf6863f31c0c2e855902c4897bf6a06ac0656cb9439c37d17e6acd1c205c520000001a0018000015736e692d636865636b2e6578616d706c652e6f7267000b00020100000a000a0008001d001700180019000d00180016080606010603080505010503080404010403020102030010000e000c02683208687474702f312e31")
assert(parseSNI(hello) == .host("sni-check.example.org"))
assert(parseSNI(Array(hello.prefix(3))) == .needMore(5))
assert(parseSNI(Array(hello.prefix(100))) == .needMore(hello.count))
assert(parseSNI(Array("GET / HTTP/1.1\r\n".utf8)) == .none)
assert(parseSNI([]) == .needMore(5))
for n in 5..<hello.count { _ = parseSNI(Array(hello.prefix(n))) }   // no crash on any truncation
var junk = hello; for k in stride(from: 9, to: junk.count, by: 7) { junk[k] = 0xff }
_ = parseSNI(junk)                                                    // no crash on corruption

// SNI split across two deliveries, both delivery styles.
let half = hello.count / 2
let first = Array(hello.prefix(half))
assert(joinPeek([], offset: 0, first).map(parseSNI) == .needMore(hello.count))
assert(joinPeek(first, offset: half, Array(hello[half...])).map(parseSNI) == .host("sni-check.example.org"))  // only new bytes
assert(joinPeek(first, offset: 0, hello).map(parseSNI) == .host("sni-check.example.org"))                   // re-delivered from 0
assert(joinPeek(first, offset: half + 10, []) == nil)                                                         // gap

var r = RuleSet(domains: ["example.com"])
assert(r.blocks(host: "example.com") && r.blocks(host: "ads.EXAMPLE.com.") && !r.blocks(host: "notexample.com"))
assert(r.verdict(app: "a", isApple: false, host: "x.example.com", loopback: false) == .block)
assert(r.verdict(app: "a", isApple: false, host: "other.org", loopback: false) == .allow)
assert(r.verdict(app: "a", isApple: false, host: nil, loopback: false) == .allow)
r.apps["bad"] = false
assert(r.verdict(app: "bad", isApple: false, host: nil, loopback: false) == .block)
assert(r.verdict(app: "bad", isApple: false, host: nil, loopback: true) == .allow)
r.mode = .requireApproval
assert(r.verdict(app: "new", isApple: false, host: "other.org", loopback: false) == .ask)
assert(r.verdict(app: "new", isApple: true, host: "other.org", loopback: false) == .allow)
assert(r.verdict(app: "new", isApple: false, host: "example.com", loopback: false) == .block)
r.apps["ok"] = true
assert(r.verdict(app: "ok", isApple: false, host: nil, loopback: false) == .allow)
r.mode = .blockAll
assert(r.verdict(app: "other", isApple: false, host: nil, loopback: false) == .block)
assert(r.verdict(app: "other", isApple: false, host: nil, loopback: true) == .allow)
assert(r.verdict(app: "ok", isApple: false, host: "x.org", loopback: false) == .allow)              // app allow rule
assert(r.decide(app: "sys", isApple: true, host: nil, loopback: false) == (.allow, "Apple exception"))
assert(r.decide(app: "other", isApple: false, host: nil, loopback: false, dns: true) == (.allow, "DNS exception"))
r.allowApple = false; r.allowDNS = false
assert(r.verdict(app: "sys", isApple: true, host: nil, loopback: false) == .block)
assert(r.verdict(app: "other", isApple: false, host: nil, loopback: false, dns: true) == .block)
r.allowApple = true; r.allowDNS = true
r.allowDomains = ["github.com", "140.82.121.4"]
assert(r.decide(app: "other", isApple: false, host: "api.github.com", loopback: false) == (.allow, "Allow List: github.com"))
assert(r.verdict(app: "other", isApple: false, host: nil, ip: "140.82.121.4", loopback: false) == .allow)
assert(r.verdict(app: "other", isApple: false, host: "x.example.com", loopback: false) == .block)  // Block List beats Allow List
r.allowDomains = ["example.com"]
assert(r.decide(app: "other", isApple: false, host: "example.com", loopback: false).reason == "Block List: example.com")
assert(r.verdict(app: "bad", isApple: false, host: "example.com", loopback: false) == .block)
r.mode = .allowAll
assert(r.verdict(app: "bad", isApple: false, host: "example.com", loopback: false) == .allow)
assert(RuleSet.normalize(domain: " *.Ads.Example.com. ") == "ads.example.com")

// QUIC with an unknown host is dropped only when domain rules exist, and says why.
var q = RuleSet(domains: ["example.com"])
assert(q.decide(app: "a", isApple: false, host: nil, loopback: false, quic: true) == (.block, "QUIC with a hidden hostname"))
assert(q.verdict(app: "a", isApple: false, host: "x.org", loopback: false, quic: true) == .allow)
q.blockUnknownQUIC = false
assert(q.verdict(app: "a", isApple: false, host: nil, loopback: false, quic: true) == .allow)
assert(RuleSet().verdict(app: "a", isApple: false, host: nil, loopback: false, quic: true) == .allow)
assert(q.decide(app: "a", isApple: false, host: "ads.example.com", loopback: false).reason == "Block List: example.com")

// IP entries, Block List switch, bulk entry parsing.
var ipr = RuleSet(domains: ["203.0.113.9", "2001:db8::7"])
assert(ipr.verdict(app: "a", isApple: false, host: "x.org", ip: "203.0.113.9", loopback: false) == .block)
assert(ipr.verdict(app: "a", isApple: false, host: nil, ip: "2001:db8::7", loopback: false) == .block)
assert(ipr.verdict(app: "a", isApple: false, host: nil, ip: "203.0.113.90", loopback: false) == .allow)
assert(ipr.verdict(app: "a", isApple: false, host: "203.0.113.9.evil.com", loopback: false) == .allow)  // IP entries never suffix-match
ipr.blockListEnabled = false
assert(ipr.verdict(app: "a", isApple: false, host: nil, ip: "203.0.113.9", loopback: false) == .allow)
let bulk = RuleSet.entries(from: "*.Ads.example.com, tracker.io\n203.0.113.9  bad..domain [2001:db8::1] tracker.io")
assert(bulk.valid == ["ads.example.com", "tracker.io", "203.0.113.9", "2001:db8::1"] && bulk.invalid == ["bad..domain"])

// Require Approval when the app is closed: online by default, strict when chosen.
var ra = RuleSet(mode: .requireApproval, domains: ["example.com"])
assert(ra.decide(app: "n", isApple: false, host: "x.org", loopback: false, appOpen: false) == (.allow, "Kekkai was not open; Block List only"))
assert(ra.verdict(app: "n", isApple: false, host: "example.com", loopback: false, appOpen: false) == .block)
ra.failClosedWithoutApp = true
assert(ra.verdict(app: "n", isApple: false, host: "x.org", loopback: false, appOpen: false) == .block)
assert(ra.verdict(app: "n", isApple: false, host: "x.org", loopback: false, dns: true) == .allow)
ra.allowDomains = ["x.org"]
assert(ra.verdict(app: "n", isApple: false, host: "x.org", loopback: false) == .allow)                // Allow List skips the prompt

// DNS answers: question name, A and AAAA through a CNAME, compression pointers.
var dns: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 0]
dns += [3] + Array("www".utf8) + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0, 0, 1, 0, 1]
dns += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 7, 4] + Array("edge".utf8) + [0xC0, 0x10]             // CNAME edge.example.org
dns += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 215, 14]                                 // A
dns += [0xC0, 0x0C, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16, 0x26, 0x06, 0x28, 0] + [UInt8](repeating: 0, count: 11) + [1] // AAAA
let answers = parseDNSAnswers(dns)
assert(answers.map(\.ip) == ["93.184.215.14", "2606:2800::1"] && answers.allSatisfy { $0.name == "www.example.org" })
assert(parseDNSAnswers(Array(dns.prefix(40))).isEmpty || parseDNSAnswers(Array(dns.prefix(40))).count < 2)
for n in 0..<dns.count { _ = parseDNSAnswers(Array(dns.prefix(n))) }                                  // no crash on truncation
var loop = dns; loop[29] = 0xC0; loop[30] = 0x1D                                                      // pointer to itself
_ = parseDNSAnswers(loop)
var query = dns; query[2] = 0x01
assert(parseDNSAnswers(query).isEmpty)                                                                // queries are ignored

// Rules from an older version (missing keys) still load; export/import round-trips.
let old = try! JSONDecoder().decode(RuleSet.self, from: Data(#"{"mode":"blockAll","apps":{"k":false},"domains":["a.com"]}"#.utf8))
assert(old.mode == .blockAll && old.apps["k"] == false && old.blockUnknownQUIC && old.approvalTimeout == 60)
assert(old.allowDomains.isEmpty && old.blockListEnabled && old.allowApple && old.allowDNS && !old.failClosedWithoutApp)
let wild = try! JSONDecoder().decode(RuleSet.self, from: Data(#"{"approvalTimeout":99999}"#.utf8))
assert(wild.approvalTimeout == 300 && wild.mode == .blockList)
var full = RuleSet(mode: .requireApproval, apps: ["x": true], domains: ["b.org"], allowDomains: ["c.org"])
full.approvalTimeout = 30; full.blockUnknownQUIC = false; full.allowDNS = false; full.failClosedWithoutApp = true; full.blockListEnabled = false
assert(try! JSONDecoder().decode(RuleSet.self, from: JSONEncoder().encode(full)) == full)

let adhoc = AppIdentity(signingID: "com.google.Chrome", teamID: nil, isApple: false, path: "/tmp/evil")
let real = AppIdentity(signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV", isApple: false, path: "/Applications/Google Chrome.app")
assert(adhoc.key != real.key && real.displayName == "Google Chrome")
// GeoIP packed table: hand-built, then the real bundled file when present.
func record4(_ a: UInt32, _ b: UInt32, _ cc: String) -> [UInt8] {
    withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init) + Array(cc.utf8)
}
var blob = Array("KKGEO1".utf8) + withUnsafeBytes(of: UInt32(3).bigEndian, Array.init) + withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)
blob += record4(0x0100_0000, 0x0100_00FF, "AU") + record4(0x0808_0800, 0x0808_08FF, "US") + record4(0xC100_0000, 0xC1FF_FFFF, "NL")
blob += [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 12) + [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0xff, count: 12) + Array("JP".utf8)
let geo = GeoTable(data: Data(blob))!
assert(geo.country(for: "1.0.0.7") == "AU" && geo.country(for: "8.8.8.8") == "US" && geo.country(for: "193.0.14.129") == "NL")
assert(geo.country(for: "1.0.1.0") == nil && geo.country(for: "0.0.0.1") == nil && geo.country(for: "255.255.255.255") == nil)
assert(geo.country(for: "2001:db8::1%en0") == "JP" && geo.country(for: "2001:db9::1") == nil && geo.country(for: "nonsense") == nil)
assert(GeoTable(data: Data(blob.dropLast())) == nil)
if let real = GeoTable(contentsOf: URL(fileURLWithPath: "App/Resources/geoip.bin")) {
    assert(real.country(for: "193.0.14.129") == "NL")   // k.root-servers.net, RIPE NCC Amsterdam
    assert(real.country(for: "10.0.0.1") == nil)
    print("check: real GeoIP table ok")
}
// nettop stream: samples split on the header line, dotted process names, IPv4 and IPv6 endpoints, listeners skipped.
var np = NettopParser()
let stream = """
,bytes_in,bytes_out,
com.apple.WebKit.Networking.512,9000,700,
tcp4 192.168.1.11:53167<->17.188.185.136:5223,9000,700,
tcp4 127.0.0.1:8021<->*:*,,,
udp4 *:51416<->*:*,0,6012,
apsd.442,1,2,
tcp6 2a02:a46::1.50000<->2606:4700::6810:84e5.443,1,2,
tcp6 fe80::450:c811:4c9e:f2%utun5.1025<->fe80::80a4:1c54:cc1b:5499%utun5.1028,3,4,
,bytes_in,bytes_out,
"""
var samples: [[NettopConnection]] = []
for line in stream.split(separator: "\n") { if let s = np.feed(line) { samples.append(s) } }
assert(samples.count == 1 && samples[0].count == 2)
assert(samples[0][0] == NettopConnection(pid: 512, process: "com.apple.WebKit.Networking", proto: "TCP", local: "192.168.1.11:53167",
                                         remoteIP: "17.188.185.136", remotePort: "5223", bytesIn: 9000, bytesOut: 700))
assert(samples[0][1].remoteIP == "2606:4700::6810:84e5" && samples[0][1].remotePort == "443" && samples[0][1].pid == 442)
assert(NettopParser.endpoint("*:*", v6: false) == nil && NettopParser.endpoint("*.*", v6: true) == nil)
// Readable app names.
func named(_ p: String) -> String { AppIdentity(signingID: nil, teamID: nil, isApple: false, path: p).displayName }
assert(named("/Applications/Safari.app") == "Safari")
assert(named("/Applications/Dia.app/Contents/Frameworks/X.framework/Helpers/Browser Helper.app") == "Dia · Browser Helper")
assert(named("/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams WebView.app") == "Microsoft Teams · WebView")
assert(named("/Users/me/.local/share/claude/versions/2.1.302") == "claude")
assert(named("/usr/libexec/trustd") == "trustd")
// System firewall plan: IPs to pf, domains (and seen subdomains) to hosts, scripts safe for AppleScript.
var fw = RuleSet(domains: ["doubleclick.net", "203.0.113.9", "2001:db8::7", "ads.example.co.uk"])
let plan = SystemFirewallPlan(rules: fw, seenHosts: ["stats.doubleclick.net", "evil.com", "x.ads.example.co.uk", "bad name.doubleclick.net"])
assert(plan.addresses == ["2001:db8::7", "203.0.113.9"])
assert(plan.hostnames == ["ads.example.co.uk", "doubleclick.net", "stats.doubleclick.net", "www.doubleclick.net", "x.ads.example.co.uk"])
assert(plan.anchorText.contains("table <kekkai_block> persist { 2001:db8::7, 203.0.113.9 }"))
assert(plan.hostsBlock.hasPrefix(SystemFirewallPlan.hostsBegin) && plan.hostsBlock.contains("0.0.0.0 stats.doubleclick.net\n:: stats.doubleclick.net"))
for script in [plan.applyScript, SystemFirewallPlan.removeScript] {
    assert(SystemFirewallPlan.appleScript(for: script) != nil)   // no double quotes, no backslashes
}
let b64 = plan.applyScript.split(separator: "\n").first { $0.contains("> /etc/pf.anchors/") }!
let encoded = b64.split(separator: "'")[1]
assert(String(decoding: Data(base64Encoded: String(encoded))!, as: UTF8.self) == plan.anchorText)
fw.blockListEnabled = false
assert(SystemFirewallPlan(rules: fw).isEmpty)
assert(SystemFirewallPlan(rules: RuleSet(domains: ["a.com"])).applyScript.contains("-F all"))   // no IPs: flush, don't enable pf
// Private addresses are never auto-blocked; app address blocks survive a round trip.
assert(RuleSet.isPrivate("192.168.1.11") && RuleSet.isPrivate("100.66.17.254") && RuleSet.isPrivate("fe80::1") && RuleSet.isPrivate("fd7a::1"))
assert(!RuleSet.isPrivate("160.79.104.10") && !RuleSet.isPrivate("2606:4700::1") && !RuleSet.isPrivate("172.32.0.1"))
var ab = RuleSet(); ab.addressBlocks = ["k": ["1.2.3.4"]]
assert(try! JSONDecoder().decode(RuleSet.self, from: JSONEncoder().encode(ab)).addressBlocks == ["k": ["1.2.3.4"]])
print("check: ok")
