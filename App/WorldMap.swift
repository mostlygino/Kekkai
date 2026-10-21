import SwiftUI

/// Country outlines from Natural Earth 1:110m (public domain), drawn locally. No map tiles, nothing fetched.
enum World {
    struct Country {
        let code: String
        let label: CGPoint   // in map space
        let path: Path       // in map space
    }

    /// Equirectangular map space: x = lon + 180 (0...360), y = top - lat. Antarctica and the far south are left out.
    static let top = 84.0, bottom = -58.0
    static let size = CGSize(width: 360, height: top - bottom)

    static func point(lon: Double, lat: Double) -> CGPoint {
        CGPoint(x: lon + 180, y: top - min(top, max(bottom, lat)))
    }

    static let countries: [Country] = {
        struct Raw: Decodable { let cc: String; let l: [Double]; let p: [[Double]] }
        guard let url = Bundle.main.url(forResource: "world", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raw.map { c in
            var path = Path()
            for ring in c.p where ring.count >= 6 {
                path.move(to: point(lon: ring[0], lat: ring[1]))
                for i in stride(from: 2, to: ring.count - 1, by: 2) { path.addLine(to: point(lon: ring[i], lat: ring[i + 1])) }
                path.closeSubpath()
            }
            return Country(code: c.cc, label: point(lon: c.l[0], lat: c.l[1]), path: path)
        }
    }()

    static let byCode = Dictionary(countries.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
}

struct CountryTraffic: Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var connections = 0
    var blocked = 0
    var destinations = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var total: UInt64 { bytesIn + bytesOut }
}

/// Where your Mac's traffic goes: countries tinted by connections, arcs from your region, markers sized by data.
struct WorldMap: View {
    let traffic: [CountryTraffic]
    @Binding var selection: String?
    @State private var hover: (code: String, at: CGPoint)?
    @Environment(\.colorScheme) private var scheme

    private var home: String? { Locale.current.region?.identifier }

    var body: some View {
        GeometryReader { geo in
            let t = transform(for: geo.size)
            let byCode = Dictionary(traffic.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
            let maxConn = Double(traffic.map(\.connections).max() ?? 1)
            let maxBytes = Double(traffic.map(\.total).max() ?? 1)

            Canvas { ctx, _ in
                let land = Color.primary.opacity(scheme == .dark ? 0.10 : 0.07)
                let edge = Color(nsColor: .windowBackgroundColor)

                for c in World.countries {
                    let path = c.path.applying(t)
                    if let row = byCode[c.code], row.connections > 0 {
                        let level = log1p(Double(row.connections)) / log1p(maxConn)
                        ctx.fill(path, with: .color(Color.shu.opacity(0.14 + 0.46 * level)))
                    } else {
                        ctx.fill(path, with: .color(land))
                    }
                    ctx.stroke(path, with: .color(edge), lineWidth: 0.6)
                    if c.code == selection || c.code == hover?.code {
                        ctx.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 1.2)
                    }
                }

                // Arcs from your region to every destination country.
                let origin = home.flatMap { World.byCode[$0]?.label.applying(t) }
                if let origin {
                    for row in traffic where row.code != home {
                        guard let to = World.byCode[row.code]?.label.applying(t) else { continue }
                        let mid = CGPoint(x: (origin.x + to.x) / 2, y: (origin.y + to.y) / 2)
                        let lift = hypot(to.x - origin.x, to.y - origin.y) * 0.22
                        var arc = Path()
                        arc.move(to: origin)
                        arc.addQuadCurve(to: to, control: CGPoint(x: mid.x, y: mid.y - lift))
                        let w = 0.6 + 1.6 * Double(row.total) / maxBytes
                        ctx.stroke(arc, with: .color(Color.shu.opacity(row.code == selection ? 0.95 : 0.45)),
                                   style: StrokeStyle(lineWidth: w, lineCap: .round))
                    }
                }

                // Markers sized by data.
                for row in traffic {
                    guard let p = World.byCode[row.code]?.label.applying(t) else { continue }
                    let r = 2.5 + 7 * sqrt(Double(row.total) / maxBytes)
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(Color.shu))
                    ctx.stroke(dot, with: .color(edge), lineWidth: 1)
                }

                // Your region: the tied stone, with two faint raked rings around it.
                if let origin {
                    for (i, r) in [16.0, 24.0].enumerated() {
                        let ring = Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r * 0.8, width: r * 2, height: r * 1.6))
                        ctx.stroke(ring, with: .color(Color.shu.opacity(0.35 - Double(i) * 0.15)), lineWidth: 0.8)
                    }
                    let box = CGRect(x: origin.x - 8, y: origin.y - 8, width: 16, height: 16)
                    ctx.fill(StoneShape().path(in: box), with: .color(Color.stone))
                    ctx.stroke(CordShape().path(in: box), with: .color(Color.shu), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    let hit = World.countries.first { $0.path.applying(t).contains(at) }
                    hover = hit.map { ($0.code, at) }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture { selection = hover?.code == selection ? nil : hover?.code }
            .overlay(alignment: .topLeading) {
                if let hover {
                    MapTooltip(code: hover.code, row: byCode[hover.code], isHome: hover.code == home)
                        .offset(x: min(hover.at.x + 14, geo.size.width - 220), y: max(0, hover.at.y - 64))
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World map of destinations")
        .accessibilityValue(traffic.sorted { $0.connections > $1.connections }.prefix(5)
            .map { "\($0.name), \($0.connections) connections" }.joined(separator: "; "))
    }

    /// Aspect-fits map space into `size`, centred. Done here rather than with `.aspectRatio` on a GeometryReader:
    /// that pairing feeds height back into width and sent the window into an endless constraint pass.
    private func transform(for size: CGSize) -> CGAffineTransform {
        let scale = min(size.width / World.size.width, size.height / World.size.height)
        let dx = (size.width - World.size.width * scale) / 2
        let dy = (size.height - World.size.height * scale) / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }
}

private struct MapTooltip: View {
    let code: String
    let row: CountryTraffic?
    let isHome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(GeoIP.name(for: code)).font(.headline)
                if isHome { Text("Your region").font(.caption).foregroundStyle(.secondary) }
            }
            if let row {
                Text("\(row.connections) connections, \(row.destinations) destinations")
                    .font(.caption).monospacedDigit()
                Text("\(bytes(row.bytesOut)) sent, \(bytes(row.bytesIn)) received")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("No traffic").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
