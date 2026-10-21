/// Result of reading the server name from the first bytes a client sends.
enum SNIResult: Equatable {
    case host(String)
    /// A TLS ClientHello that is not complete yet. Peek this many bytes in total and try again.
    case needMore(Int)
    /// Not a TLS ClientHello, or one without a server name.
    case none
}

/// Reads the SNI host name from a TLS ClientHello.
/// ponytail: single-record ClientHello only, and ECH hides the real name (we see the public outer name).
func parseSNI(_ b: [UInt8]) -> SNIResult {
    guard b.count >= 5 else { return b.isEmpty || b[0] == 0x16 ? .needMore(5) : .none }
    guard b[0] == 0x16, b[1] == 0x03 else { return .none }
    let total = 5 + (Int(b[3]) << 8 | Int(b[4]))
    guard total <= 5 + 16_384 + 2048 else { return .none }
    guard b.count >= total else { return .needMore(total) }

    var i = 5
    func u8() -> Int? { guard i + 1 <= total else { return nil }; defer { i += 1 }; return Int(b[i]) }
    func u16() -> Int? { guard i + 2 <= total else { return nil }; defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i + 1]) }
    func skip(_ n: Int) -> Bool { guard n >= 0, i + n <= total else { return false }; i += n; return true }

    guard u8() == 0x01,                       // handshake type: ClientHello
          skip(3),                            // handshake length
          skip(2 + 32),                       // client version, random
          let sid = u8(), skip(sid),          // session id
          let cs = u16(), skip(cs),           // cipher suites
          let cm = u8(), skip(cm),            // compression methods
          let extLen = u16()
    else { return .none }

    let extEnd = min(total, i + extLen)
    while i + 4 <= extEnd {
        guard let type = u16(), let len = u16() else { return .none }
        let next = i + len
        guard next <= extEnd else { return .none }
        if type == 0 {                        // server_name
            guard u16() != nil else { return .none }  // list length
            while i + 3 <= next {
                guard let kind = u8(), let n = u16(), i + n <= next else { return .none }
                if kind == 0, n > 0 {         // host_name
                    let name = String(decoding: b[i..<i + n], as: UTF8.self)
                    return name.isEmpty ? .none : .host(name.lowercased())
                }
                i += n
            }
            return .none
        }
        i = next
    }
    return .none
}

/// Joins peeked bytes that start at `offset` onto what was already seen for the flow.
/// Handles both a re-delivery from 0 and a delivery of only the new bytes. Nil when there is a gap.
func joinPeek(_ known: [UInt8], offset: Int, _ new: [UInt8]) -> [UInt8]? {
    guard offset >= 0, offset <= known.count else { return nil }
    return Array(known.prefix(offset)) + new
}
