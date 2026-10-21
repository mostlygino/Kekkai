import Darwin

/// Reads A and AAAA answers from a DNS response, so addresses can be shown as the names apps asked for.
/// Returns (address, name) pairs, where name is the question's name rather than the end of a CNAME chain:
/// that is the name the app used. Malformed or truncated input gives an empty result.
func parseDNSAnswers(_ b: [UInt8]) -> [(ip: String, name: String)] {
    guard b.count >= 12, b[2] & 0x80 != 0 else { return [] }           // QR bit: responses only
    let qd = Int(b[4]) << 8 | Int(b[5])
    let an = Int(b[6]) << 8 | Int(b[7])
    guard qd >= 1, an >= 1, an <= 64 else { return [] }

    var i = 12

    /// Reads a possibly compressed name starting at `at`. Advances `i` only when reading at the cursor.
    func name(at start: Int, moveCursor: Bool) -> String? {
        var p = start, labels: [String] = [], jumps = 0, end: Int?
        while p < b.count {
            let len = Int(b[p])
            if len == 0 { end = end ?? p + 1; break }
            if len & 0xC0 == 0xC0 {
                guard p + 1 < b.count, jumps < 16 else { return nil }
                end = end ?? p + 2
                p = (len & 0x3F) << 8 | Int(b[p + 1])
                jumps += 1
                continue
            }
            guard len <= 63, p + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(p + 1)..<(p + 1 + len)], as: UTF8.self))
            p += 1 + len
        }
        guard let end else { return nil }
        if moveCursor { i = end }
        return labels.joined(separator: ".").lowercased()
    }

    guard let question = name(at: i, moveCursor: true), !question.isEmpty else { return [] }
    i += 4                                                              // QTYPE, QCLASS
    for _ in 1..<qd {                                                   // rare, but skip any further questions
        guard name(at: i, moveCursor: true) != nil else { return [] }
        i += 4
    }

    var out: [(String, String)] = []
    for _ in 0..<an {
        guard name(at: i, moveCursor: true) != nil, i + 10 <= b.count else { break }
        let type = Int(b[i]) << 8 | Int(b[i + 1])
        let len = Int(b[i + 8]) << 8 | Int(b[i + 9])
        i += 10
        guard i + len <= b.count else { break }
        if type == 1, len == 4 {
            out.append((b[i..<i + 4].map(String.init).joined(separator: "."), question))
        } else if type == 28, len == 16 {
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { raw in for k in 0..<16 { raw[k] = b[i + k] } }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil {
                out.append((String(cString: text), question))
            }
        }
        i += len
    }
    return out
}
