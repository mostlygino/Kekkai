/// One connection as `nettop -n -x -J bytes_in,bytes_out` reports it.
struct NettopConnection: Equatable {
    var pid: Int32
    var process: String
    var proto: String        // "TCP" or "UDP"
    var local: String
    var remoteIP: String
    var remotePort: String
    var bytesIn: UInt64      // running totals for the connection
    var bytesOut: UInt64

    var key: String { "\(pid)|\(proto)|\(local)|\(remoteIP)|\(remotePort)" }
}

/// Reads nettop's CSV stream. Each sample starts with the header line ",bytes_in,bytes_out,"; under it come
/// process lines ("Safari.512,in,out,") each followed by its connections ("tcp4 a:1<->b:2,in,out,").
/// Feed it lines; it returns a finished sample whenever the next header arrives.
struct NettopParser {
    private var current: [NettopConnection] = []
    private var inSample = false
    private var process: (name: String, pid: Int32)?

    /// A complete sample when `line` starts the next one, otherwise nil.
    mutating func feed(_ line: Substring) -> [NettopConnection]? {
        if line.hasPrefix(",") {
            defer { current = []; process = nil; inSample = true }
            return inSample ? current : nil
        }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = fields.first, !first.isEmpty else { return nil }
        let bytesIn = fields.count > 1 ? UInt64(fields[1]) ?? 0 : 0
        let bytesOut = fields.count > 2 ? UInt64(fields[2]) ?? 0 : 0

        guard let space = first.firstIndex(of: " "), first.contains("<->") else {
            // Process line: the name may contain dots itself, the pid is after the last one.
            if let dot = first.lastIndex(of: "."), let pid = Int32(first[first.index(after: dot)...]) {
                process = (String(first[..<dot]), pid)
            }
            return nil
        }
        guard let process else { return nil }
        let kind = first[..<space]
        let ends = first[first.index(after: space)...].components(separatedBy: "<->")
        guard ends.count == 2, let remote = Self.endpoint(ends[1], v6: kind.hasSuffix("6")),
              !Self.isLocal(remote.ip) else { return nil }
        current.append(NettopConnection(pid: process.pid, process: process.name, proto: kind.hasPrefix("tcp") ? "TCP" : "UDP",
                                        local: ends[0], remoteIP: remote.ip, remotePort: remote.port,
                                        bytesIn: bytesIn, bytesOut: bytesOut))
        return nil
    }

    /// "1.2.3.4:443" (IPv4) or "2001:db8::1.443" / "fe80::1%en0.443" (IPv6). Nil for listeners ("*:*", "*.*").
    static func endpoint(_ text: String, v6: Bool) -> (ip: String, port: String)? {
        guard let sep = text.lastIndex(of: v6 ? "." : ":") else { return nil }
        var ip = String(text[..<sep])
        let port = String(text[text.index(after: sep)...])
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        guard ip != "*", !ip.isEmpty, port != "*" else { return nil }
        return (ip, port)
    }

    static func isLocal(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("fe80:") || ip == "0.0.0.0" || ip == "::"
    }
}
