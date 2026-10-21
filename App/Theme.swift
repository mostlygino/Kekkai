import AppKit
import UniformTypeIdentifiers
import SwiftUI

// Sumi & shu: system neutrals, one vermilion accent for the barrier itself. See DESIGN.md.

extension Color {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    /// 朱 vermilion. Same as the asset catalog accent.
    static let shu = dynamic(0xD9412B, 0xF0563E)
    /// 和紙 washi, for the seal slip in About.
    static let paper = dynamic(0xF6F1E7, 0x2B2824)
    /// 松 pine.
    static let allow = dynamic(0x2F7D5B, 0x4FB386)
    /// 琥珀 amber.
    static let ask = dynamic(0xA9761A, 0xE3A93A)
    /// 玄武岩 basalt, for the stone.
    static let stone = dynamic(0x2E2B2F, 0xD9D3C8)
    /// 藍 indigo.
    static let received = dynamic(0x3A5BA0, 0x7C9BE0)
    static let sent = shu
}

extension Verdict {
    var color: Color {
        switch self {
        case .allow: .allow
        case .block: .shu
        case .ask: .ask
        }
    }

    var symbol: String {
        switch self {
        case .allow: "checkmark.circle"
        case .block: "xmark.octagon"
        case .ask: "hourglass"
        }
    }

    var word: String {
        switch self {
        case .allow: "Allowed"
        case .block: "Blocked"
        case .ask: "Waiting"
        }
    }
}

/// Symbol plus word, so the verdict never rests on colour alone.
struct VerdictLabel: View {
    let verdict: Verdict
    var compact = false

    var body: some View {
        Group {
            if verdict == .block {
                HStack(spacing: 5) {
                    SealBadge(size: compact ? 13 : 15)
                    Text(verdict.word)
                }
            } else {
                Label(verdict.word, systemImage: verdict.symbol).labelStyle(.titleAndIcon)
            }
        }
        .font(compact ? .caption : .callout)
        .foregroundStyle(verdict.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verdict.word)
    }
}

/// The menu bar mark: the app icon's tied stone as a template image, so the menu bar tints it.
/// Tied (solid stone, the cord cut out of it) while the barrier is up; the bare stone when it is down.
enum StoneGlyph {
    private static let tiedImage = make(tied: true), bareImage = make(tied: false)
    static func image(tied: Bool) -> NSImage { tied ? tiedImage : bareImage }

    private static func make(tied: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            var tilt = AffineTransform(translationByX: 9, byY: 9)
            tilt.rotate(byDegrees: 9)
            tilt.translate(x: -9, y: -9)
            let stone = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 3.6, width: 15, height: 10.8))
            stone.transform(using: tilt)
            NSColor.black.set()
            guard tied else {
                stone.lineWidth = 1.3
                stone.stroke()
                return true
            }
            stone.fill()
            let cord = NSBezierPath()
            cord.move(to: NSPoint(x: 1, y: 9)); cord.line(to: NSPoint(x: 17, y: 9))
            cord.move(to: NSPoint(x: 9, y: 2)); cord.line(to: NSPoint(x: 9, y: 16))
            cord.transform(using: tilt)
            cord.lineWidth = 1.5
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            cord.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 7.7, y: 7.7, width: 2.6, height: 2.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The sekimori-ishi (関守石): the garden stone tied with cord that means "no further". It is the app icon and
/// the status mark: the rendered icon at 22 pt and up, the menu bar glyph below that (a drawn cord read as a red
/// "X" at small sizes). Raised barrier: in colour, tied. Lowered: grey, bare. Raising it sends one ripple out
/// through the gravel (the app's one authored motion, skipped with Reduce Motion).
struct BarrierMark: View {
    let on: Bool
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.5
    /// 0 starts a ripple, 1 is finished (invisible).
    @State private var ripple: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if size >= 22 {
                // Large: the rendered stone from the app icon, greyed out while the barrier is down.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .saturation(on ? 1 : 0)
                    .opacity(on ? 1 : 0.55)
            } else {
                // Small: the menu bar glyph (tied stone, cord cut out), crisp at any size.
                Image(nsImage: StoneGlyph.image(tied: on))
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            // The one authored motion: raising the barrier sends a ripple through the gravel.
            Ellipse()
                .stroke(Color.shu, lineWidth: max(1, size * 0.06))
                .frame(width: size, height: size * 0.8)
                .scaleEffect(0.8 + ripple * 1.1)
                .opacity((1 - ripple) * 0.9)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.2), value: on)
        .onChange(of: on) { _, isOn in
            guard isOn, !reduceMotion else { return }
            ripple = 0
            withAnimation(.easeOut(duration: 0.8)) { ripple = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// A river stone: a slightly flattened, slightly tilted oval.
struct StoneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width * 0.92, h = rect.height * 0.66
        let oval = Path(ellipseIn: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2 + rect.height * 0.04, width: w, height: h))
        let tilt = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: -.pi / 20).translatedBy(x: -rect.midX, y: -rect.midY)
        return oval.applying(tilt)
    }
}

/// The cord: once around the stone each way, crossing at the knot on top.
struct CordShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let w = rect.width * 0.46, h = rect.height * 0.33
        var p = Path()
        p.move(to: CGPoint(x: c.x - w, y: c.y + h * 0.15))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y - h * 0.15), control: CGPoint(x: c.x, y: c.y - h * 0.35))
        p.move(to: CGPoint(x: c.x - w * 0.15, y: c.y + h))
        p.addQuadCurve(to: CGPoint(x: c.x + w * 0.15, y: c.y - h), control: CGPoint(x: c.x + w * 0.28, y: c.y))
        let tilt = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: -.pi / 20).translatedBy(x: -rect.midX, y: -rect.midY)
        return p.applying(tilt)
    }
}

/// A hanko: the small square seal pressed in vermilion. Blocked verdicts carry 止 ("stop"), with the word beside it.
struct SealBadge: View {
    var mark = "止"
    var size: CGFloat = 15

    var body: some View {
        Text(mark)
            .font(.system(size: size * 0.66, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.shu, in: RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).inset(by: 1.2).strokeBorder(.white.opacity(0.35), lineWidth: 0.6))
            .rotationEffect(.degrees(-3))
            .accessibilityHidden(true)
    }
}

/// "9,5 MB". Zero reads "0 B", not the formatter's "Zero kB".
func bytes(_ n: UInt64) -> String { n == 0 ? "0 B" : Int64(clamping: n).formatted(.byteCount(style: .file)) }


extension FlowEvent: Identifiable {
    var id: UUID { flowID }
}

// The app's two models, reachable from any view. Defaults are the shared instances, so a view hosted somewhere the
// scene's environment does not reach (toolbar, search field, menu bar, settings) still works instead of trapping.
extension EnvironmentValues {
    @Entry var store: Store = .shared
    @Entry var filter: FilterControl = .shared
}

/// A quiet initial on a tinted tile, so a missing app reads as intentional rather than broken.
enum Monogram {
    private static var cache: [String: NSImage] = [:]
    /// Ink-and-earth tones that sit next to shu without fighting it.
    private static let tints: [UInt32] = [0x5B6C8F, 0x6E8B74, 0x8C6D5A, 0x7A6A92, 0x5F8A8B, 0x8E7B4E, 0x6B7280]

    static func image(for name: String) -> NSImage {
        if let hit = cache[name] { return hit }
        let letter = name.first.map { String($0).uppercased() } ?? "?"
        let hex = tints[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % tints.count]
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14)
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1).setFill()
            tile.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 1))
            return true
        }
        cache[name] = image
        return image
    }
}

/// Karesansui: raked gravel. Concentric ripples around a stone, as on the app icon. Used sparingly
/// (onboarding, empty states) and too faint to read as a pattern.
struct RakedGround: View {
    var center: UnitPoint = .init(x: 0.5, y: 0.32)
    var rings = 18

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width * center.x, y: size.height * center.y)
            let step = max(size.width, size.height) / CGFloat(rings) * 0.75
            for i in 1...rings {
                let r = CGFloat(i) * step
                // Slightly squashed, as raked rings are never quite circles.
                let rect = CGRect(x: c.x - r, y: c.y - r * 0.82, width: r * 2, height: r * 1.64)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.045 - Double(i) * 0.0015)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One column for traffic: the total, with received and sent underneath.
struct DataCell: View {
    let bytesIn: UInt64
    let bytesOut: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bytes(bytesIn + bytesOut)).monospacedDigit()
            HStack(spacing: 6) {
                Text("↓ " + bytes(bytesIn))
                Text("↑ " + bytes(bytesOut))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .help("Received \(bytes(bytesIn)), sent \(bytes(bytesOut))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bytes(bytesIn + bytesOut)) in total, \(bytes(bytesIn)) received, \(bytes(bytesOut)) sent")
    }
}

/// "now", "12s", "4m", "3h", "Mon", "12 Oct". Short enough for a table column; the full date is in the tooltip.
func ago(_ date: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(date)
    if s < 5 { return "now" }
    if s < 60 { return "\(Int(s))s" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86_400 { return "\(Int(s / 3600))h" }
    if s < 7 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}

extension Font {
    /// The garden voice: New York (the system serif) for headings, used sparingly next to SF body text.
    static func garden(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
    }
}

/// An empty state on raked gravel, so "nothing here yet" still feels like part of the garden.
struct GardenEmpty: View {
    let title: String
    let symbol: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label { Text(title).font(.garden(.title2)) } icon: { Image(systemName: symbol) }
        } description: {
            if let message { Text(message) }
        }
        .background { RakedGround(center: .init(x: 0.5, y: 0.42), rings: 14) }
    }
}

extension EnvironmentValues {
    /// False for panes that are built but hidden (see ContentView). They show their last data and stop
    /// recomputing, so live traffic only costs the pane you're looking at.
    @Entry var paneActive: Bool = true
}

/// The last values a pane computed, kept while it's hidden. A class, so storing into it from `body` doesn't
/// trigger another update; reading the store only on the live path means hidden panes don't subscribe to it.
final class Frozen {
    private var values: [String: Any] = [:]

    func keep<T>(_ key: String, live: Bool, _ make: () -> T) -> T {
        if live || values[key] == nil {
            let v = make()
            values[key] = v
            return v
        }
        return values[key] as! T
    }
}
