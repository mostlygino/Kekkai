import Foundation

/// IP to country lookup over the packed file written by `scripts/fetch-geoip.sh`.
/// The data is memory-mapped and searched in place, so nothing is parsed at launch.
struct GeoTable {
    private let data: Data
    private let v4Count: Int
    private let v6Count: Int
    private static let header = 14, v4Size = 10, v6Size = 34

    init?(data: Data) {
        guard data.count >= Self.header, data.prefix(6) == Data("KKGEO1".utf8) else { return nil }
        v4Count = Int(data.be(6, 4))
        v6Count = Int(data.be(10, 4))
        guard data.count == Self.header + v4Count * Self.v4Size + v6Count * Self.v6Size else { return nil }
        self.data = data
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// ISO 3166 country code, or nil for private, unknown or unparsable addresses.
    func country(for ip: String) -> String? {
        let host = ip.split(separator: "%").first.map(String.init) ?? ip
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let key = withUnsafeBytes(of: &v4) { Data($0) }
            return search(key, count: v4Count, base: Self.header, size: Self.v4Size, width: 4)
        }
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let key = withUnsafeBytes(of: &v6) { Data($0) }
            return search(key, count: v6Count, base: Self.header + v4Count * Self.v4Size, size: Self.v6Size, width: 16)
        }
        return nil
    }

    /// Binary search over fixed-width big-endian records; byte-wise comparison equals numeric order.
    private func search(_ key: Data, count: Int, base: Int, size: Int, width: Int) -> String? {
        var lo = 0, hi = count - 1
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let k = [UInt8](key)
            while lo <= hi {
                let mid = (lo + hi) / 2
                let rec = base + mid * size
                if Self.less(k, raw, rec) { hi = mid - 1; continue }
                if Self.less(raw, rec + width, k) { lo = mid + 1; continue }
                let cc = rec + 2 * width
                return String(decoding: [raw[cc], raw[cc + 1]], as: UTF8.self)
            }
            return nil
        }
    }

    private static func less(_ k: [UInt8], _ raw: UnsafeRawBufferPointer, _ at: Int) -> Bool {
        for i in 0..<k.count where k[i] != raw[at + i] { return k[i] < raw[at + i] }
        return false
    }

    private static func less(_ raw: UnsafeRawBufferPointer, _ at: Int, _ k: [UInt8]) -> Bool {
        for i in 0..<k.count where raw[at + i] != k[i] { return raw[at + i] < k[i] }
        return false
    }
}

private extension Data {
    func be(_ offset: Int, _ n: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + n)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
