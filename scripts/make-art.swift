// Draws Kekkai's installer artwork with Core Graphics: no image assets, the same picture on every build.
//
//   swift scripts/make-art.swift dmg <folder>    DMG window background, 640 × 400 pt, @1x and @2x
//   swift scripts/make-art.swift pkg <folder>    Installer side panel, light and dark, @1x and @2x
//
// The scene is a karesansui, a dry garden, seen from above. Raked gravel runs in straight lines and turns into
// rings around each stone, as it does around real stones. On the DMG, Kekkai's own stone (the app icon) sits on
// the left in its rings; Applications sits on the right in a second set; a vermilion cord, the one that ties the
// sekimori-ishi, runs from one to the other with a knot halfway and points the way. Finder draws the icon labels
// itself (black or white with the system appearance), so the gravel is a mid tone both stay readable on.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, ["dmg", "pkg"].contains(args[1]) else {
    print("usage: make-art.swift dmg|pkg <folder>"); exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let shu = rgb(0xD9412B)

/// A garden: a gravel tone, rake lines that flow around stones, and grain.
struct Garden {
    var size: CGSize
    var stones: [(centre: CGPoint, radius: CGFloat)]   // y from the top, like Finder
    var base: UInt32, groove: CGFloat, ridge: CGFloat
    var spacing: CGFloat = 7

    func draw(_ ctx: CGContext, seed: UInt64) {
        var rng = Seeded(state: seed)
        let h = size.height
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }

        // Ground: the gravel tone with a soft fall-off of light from the top left.
        ctx.setFillColor(rgb(base))
        ctx.fill(CGRect(origin: .zero, size: size))
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(light, startCenter: CGPoint(x: size.width * 0.2, y: h * 0.95), startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.2, y: h * 0.95), endRadius: max(size.width, h) * 0.9, options: [])

        // A groove is a dark line with a light line just below it: raked gravel catches the light on one side.
        func groovePath(_ build: (CGMutablePath) -> Void) {
            let p = CGMutablePath(); build(p)
            ctx.setLineCap(.round)
            ctx.addPath(p); ctx.setStrokeColor(rgb(0x000000, groove)); ctx.setLineWidth(1.1); ctx.strokePath()
            ctx.saveGState(); ctx.translateBy(x: 0, y: -1.1)
            ctx.addPath(p); ctx.setStrokeColor(rgb(0xFFFFFF, ridge)); ctx.setLineWidth(0.9); ctx.strokePath()
            ctx.restoreGState()
        }

        // Rings around every stone.
        for stone in stones {
            var r = stone.radius
            while r < stone.radius + spacing * 8 {
                groovePath { p in
                    // Hand-raked rings wobble a little.
                    let steps = 180
                    for i in 0...steps {
                        let a = CGFloat(i) / CGFloat(steps) * .pi * 2
                        let wobble = 1 + 0.012 * sin(a * 3 + r * 0.05)
                        let pt = flip(CGPoint(x: stone.centre.x + cos(a) * r * wobble, y: stone.centre.y + sin(a) * r * 0.86 * wobble))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                r += spacing
            }
        }

        // Straight rake lines everywhere else, broken where they meet the outer ring of a stone.
        let outer = stones.map { ($0.centre, $0.radius + spacing * 8 + 2) }
        var y: CGFloat = spacing / 2
        while y < h {
            groovePath { p in
                var drawing = false
                var x: CGFloat = 0
                let wave = rng.range(0, .pi * 2)
                while x <= size.width {
                    let yy = y + sin(x * 0.012 + wave) * 0.6
                    let inside = outer.contains { c, r in
                        let dx = (x - c.x) / r, dy = (yy - c.y) / (r * 0.86)
                        return dx * dx + dy * dy < 1
                    }
                    let pt = flip(CGPoint(x: x, y: yy))
                    if inside { drawing = false }
                    else if drawing { p.addLine(to: pt) }
                    else { p.move(to: pt); drawing = true }
                    x += 3
                }
            }
            y += spacing
        }

        // Grain: single pebbles, light and dark.
        for _ in 0..<Int(size.width * h / 22) {
            let pt = CGPoint(x: rng.range(0, size.width), y: rng.range(0, h))
            let s = rng.range(0.4, 1.3)
            ctx.setFillColor(rng.next() < 0.5 ? rgb(0x000000, rng.range(0.03, 0.09)) : rgb(0xFFFFFF, rng.range(0.05, 0.14)))
            ctx.fillEllipse(in: CGRect(x: pt.x, y: pt.y, width: s, height: s))
        }
    }
}

/// The cord: a two-ply vermilion line with a knot, ending in an arrow.
func cord(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, height h: CGFloat) {
    func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 16)
    let path = CGMutablePath()
    path.move(to: flip(a))
    path.addQuadCurve(to: flip(b), control: flip(CGPoint(x: mid.x, y: mid.y + 18)))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: rgb(0x000000, 0.35))
    ctx.setLineCap(.round)
    ctx.addPath(path); ctx.setStrokeColor(shu); ctx.setLineWidth(3.4); ctx.strokePath()
    ctx.restoreGState()
    // The twist of the two plies, as short light dashes along the cord.
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFB4A0, 0.55)); ctx.setLineWidth(1.1)
    ctx.setLineDash(phase: 0, lengths: [2.2, 3.2]); ctx.strokePath()
    ctx.restoreGState()

    // The knot, halfway, with two small loops.
    let k = flip(CGPoint(x: mid.x, y: mid.y + 9))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: rgb(0x000000, 0.3))
    ctx.setStrokeColor(shu); ctx.setLineWidth(2.6)
    for side: CGFloat in [-1, 1] {
        ctx.strokeEllipse(in: CGRect(x: k.x + side * 9 - 6, y: k.y - 4 + 2, width: 12, height: 8))
    }
    ctx.setFillColor(shu)
    ctx.fillEllipse(in: CGRect(x: k.x - 4, y: k.y - 4, width: 8, height: 8))
    ctx.restoreGState()

    // Arrowhead at the Applications end, pointing along the cord.
    let end = flip(b), before = flip(CGPoint(x: b.x - 8, y: b.y - 3))
    let ang = atan2(end.y - before.y, end.x - before.x)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x + cos(ang) * 7, y: end.y + sin(ang) * 7))
    head.addLine(to: CGPoint(x: end.x + cos(ang + 2.5) * 9, y: end.y + sin(ang + 2.5) * 9))
    head.addLine(to: CGPoint(x: end.x + cos(ang - 2.5) * 9, y: end.y + sin(ang - 2.5) * 9))
    head.closeSubpath()
    ctx.addPath(head); ctx.setFillColor(shu); ctx.fillPath()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, serif: Bool, centre: CGPoint, height h: CGFloat, kern: CGFloat = 0) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if serif, let d = font.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: d, size: size) ?? font }
    let shadow = NSShadow(); shadow.shadowColor = NSColor.white.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -0.6)
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern, .shadow: shadow])
    let sz = str.size()
    str.draw(at: NSPoint(x: centre.x - sz.width / 2, y: h - centre.y - sz.height / 2))
}

func render(_ name: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    // rep.size is in points, so the context already maps points to pixels; no extra scale here.
    draw(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(name))
}

if args[1] == "dmg" {
    // Keep in step with scripts/dmg/settings.py: 640 × 400 window, Kekkai at (170, 210), Applications at (470, 210).
    let size = CGSize(width: 640, height: 400)
    let app = CGPoint(x: 170, y: 210), apps = CGPoint(x: 470, y: 210)
    for scale: CGFloat in [1, 2] {
        render(scale == 1 ? "background.png" : "background@2x.png", size: size, scale: scale) { ctx in
            Garden(size: size, stones: [(app, 70), (apps, 70)], base: 0xB9B3A8, groove: 0.16, ridge: 0.30).draw(ctx, seed: 0x6B6B)
            cord(ctx, from: CGPoint(x: 248, y: 196), to: CGPoint(x: 392, y: 196), height: size.height)
            text("Kekkai", size: 26, weight: .semibold, color: NSColor(white: 0.12, alpha: 0.9), serif: true, centre: CGPoint(x: 320, y: 44), height: size.height)
            text("結界 · DRAG TO APPLICATIONS TO INSTALL", size: 10, weight: .semibold, color: NSColor(srgbRed: 0.72, green: 0.22, blue: 0.14, alpha: 1),
                 serif: false, centre: CGPoint(x: 320, y: 72), height: size.height, kern: 1.6)
            text("Sees which apps connect where, and stops the ones you don't trust.", size: 11, weight: .regular,
                 color: NSColor(white: 0.15, alpha: 0.75), serif: false, centre: CGPoint(x: 320, y: 360), height: size.height)
        }
    }
} else {
    // Installer side panel: macOS draws it bottom-left under the step list, so the picture lives low and left.
    let size = CGSize(width: 260, height: 420)
    for (suffix, base, groove, ridge) in [("", UInt32(0xD6D1C7), CGFloat(0.13), CGFloat(0.35)),
                                                      ("-dark", UInt32(0x2C2A2E), CGFloat(0.35), CGFloat(0.08))] {
        for scale: CGFloat in [1, 2] {
            render("installer\(suffix)\(scale == 2 ? "@2x" : "").png", size: size, scale: scale) { ctx in
                let stone = CGPoint(x: 110, y: 330)
                Garden(size: size, stones: [(stone, 66)], base: base, groove: groove, ridge: ridge, spacing: 6).draw(ctx, seed: 0x6B6C)
                // The app icon itself, resting in its rings.
                let icon = NSImage(contentsOfFile: "App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
                    ?? NSImage(contentsOfFile: "App/Assets.xcassets/AppIcon.appiconset/icon_512x512.png")
                if let icon {
                    let side: CGFloat = 112
                    let r = CGRect(x: stone.x - side / 2, y: size.height - stone.y - side / 2, width: side, height: side)
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: rgb(0x000000, 0.4))
                    icon.draw(in: r)
                    ctx.restoreGState()
                }
            }
        }
    }
}
print("art: \(args[1]) -> \(outDir.path)")
