import Foundation

/// Country lookups for the UI, backed by the bundled DB-IP Lite table (CC BY 4.0).
enum GeoIP {
    static let attribution = "IP to country data by DB-IP.com, CC BY 4.0"
    static let attributionURL = URL(string: "https://db-ip.com")!

    static let table: GeoTable? = Bundle.main.url(forResource: "geoip", withExtension: "bin").flatMap(GeoTable.init(contentsOf:))
    static var available: Bool { table != nil }

    static func country(for ip: String) -> String? { table?.country(for: ip) }

    static func name(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
