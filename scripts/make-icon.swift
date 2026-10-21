// Renders the Kekkai app icon (and the three options it beat) and writes the icon set.
//
//   swiftc -O scripts/make-icon.swift -o /tmp/kekkai-icon
//   /tmp/kekkai-icon <AppIcon.iconset|AppIcon.appiconset> [--variant <name>] [--brand <folder>]
//
// 結界 (kekkai), a barrier: the line round a protected place. Kekkai is an app
// firewall, so every option is a Japanese boundary object made tangible:
//
//   sekimori   関守石  the garden stone tied with cord that means "no further" (chosen)
//   shimenawa  注連縄  the straw rope with paper streamers at a sacred boundary
//   kikko      亀甲    a cloisonné medallion: barriers nested round a gold core
//   torii      鳥居    the gate itself, its plaque reading 結界
//
// The chosen icon is built to survive close inspection: river basalt with a
// quartz vein and a satin sheen that shows the window; shu cotton cord laid as
// a real two-ply twist, bound at the crossing, tied off with a handle loop and
// two cut tails frayed at the ends; hand-raked gravel whose rings wander, come
// in passes of five teeth and bunch where the raker closed the circle; grains
// of feldspar, quartz and biotite; shadows that soften with distance.
//
// Not drawn with gradients: the same small renderer as Kagami and Shīru. Every
// surface is a height field lit by one window high to the left; normals come
// from the heights, shadows are marched toward the window, and lacquer, enamel
// and metal reflect an analytic room (a shoji window, a dim wall, a paper lamp),
// so reflections bend with the surface by themselves. Run it optimised.
//
//   --variant  sekimori (default, the icon), shimenawa, kikko, torii
//   --brand    also write every option, a sheet per option and the options sheet
//
// No SF Symbols: their licence does not allow use in app icons. 結界 comes from
// Hiragino Mincho as an outline and is rasterised; no font is embedded or shipped.

import AppKit

// MARK: Tokens

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sumi = rgb(0x141214)         // ink, dark surface
let paper = rgb(0xF7F4EE)        // washi, light surface
let surface = rgb(0xF0EDE8)      // brand sheet ground
let shuCG = rgb(0xD9412B)        // 朱, vermilion: the product colour (DESIGN.md)

/// How much a size can carry: fine texture from 256 px, construction detail from 128 px.
enum Detail: Int, Comparable {
    case glyph = 0, mark, full
    init(pixels: CGFloat) { self = pixels <= 64 ? .glyph : pixels <= 160 ? .mark : .full }
    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Vectors

struct V3 {
    var x: Float, y: Float, z: Float
    static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: V3, s: Float) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func * (a: V3, b: V3) -> V3 { V3(x: a.x * b.x, y: a.y * b.y, z: a.z * b.z) }
    func dot(_ b: V3) -> Float { x * b.x + y * b.y + z * b.z }
    var normalised: V3 { self * (1 / dot(self).squareRoot()) }
}

func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a * (1 - t) + b * t }
func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
    let t = clamp01((v - a) / (b - a))
    return t * t * (3 - 2 * t)
}
func colour(_ hex: UInt32) -> V3 {
    V3(x: Float(hex >> 16 & 0xFF) / 255, y: Float(hex >> 8 & 0xFF) / 255, z: Float(hex & 0xFF) / 255)
}

let white = V3(x: 1, y: 0.97, z: 0.92)
let lacquerBase = colour(0x110D0B)

/// The window. Buffer space: x right, y down, z out of the screen.
let light = V3(x: -0.5, y: -0.62, z: 0.6).normalised
let halfway = (light + V3(x: 0, y: 0, z: 1)).normalised
/// Where shadows fall: away from the window, down and to the right.
let away: (x: Float, y: Float) = {
    let l = (light.x * light.x + light.y * light.y).squareRoot()
    return (-light.x / l, -light.y / l)
}()

// MARK: Fields

/// A square grid of floats, row 0 at the top (as CGBitmapContext stores it).
struct Field {
    let n: Int
    var v: [Float]
    init(_ n: Int, _ fill: Float = 0) { self.n = n; v = [Float](repeating: fill, count: n * n) }
    init(_ n: Int, _ v: [Float]) { self.n = n; self.v = v }
    subscript(x: Int, y: Int) -> Float { v[min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)] }
    func map(_ f: (Float) -> Float) -> Field { Field(n, v.map(f)) }
}

/// Rasterises a drawing in 1024-unit, y-up coordinates into an n×n coverage field.
func coverage(_ n: Int, _ draw: (CGContext) -> Void) -> Field {
    var bytes = [UInt8](repeating: 0, count: n * n)
    bytes.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.scaleBy(x: CGFloat(n) / 1024, y: CGFloat(n) / 1024)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        draw(ctx)
    }
    return Field(n, bytes.map { Float($0) / 255 })
}

/// Three box passes each way, close to a gaussian of the given radius in pixels.
func blur(_ f: Field, _ radius: Float) -> Field {
    let k = Int((radius / 1.7).rounded())
    guard k >= 1 else { return f }
    let n = f.n, norm = 1 / Float(2 * k + 1)
    var a = f.v, b = f.v
    for _ in 0..<3 {
        for stride in [1, n] {
            a.withUnsafeBufferPointer { s in
                b.withUnsafeMutableBufferPointer { d in
                    for line in 0..<n {
                        let base = stride == 1 ? line * n : line
                        func at(_ i: Int) -> Float { s[base + min(max(i, 0), n - 1) * stride] }
                        var sum: Float = 0
                        for i in -k...k { sum += at(i) }
                        for i in 0..<n {
                            d[base + i * stride] = sum * norm
                            sum += at(i + k + 1) - at(i - k)
                        }
                    }
                }
            }
            swap(&a, &b)
        }
    }
    return Field(n, a)
}

/// Moves a field by whole pixels (right and down positive), edges clamped.
func shifted(_ f: Field, _ dx: Float, _ dy: Float) -> Field {
    let n = f.n, ox = Int(dx.rounded()), oy = Int(dy.rounded())
    var out = Field(n)
    for y in 0..<n { for x in 0..<n { out.v[y * n + x] = f[x - ox, y - oy] } }
    return out
}

/// The shadow an object casts on the ground, and the tight contact shadow at its foot.
func shadows(_ cover: Field, _ u: Float, distance: Float = 24, softness: Float = 32) -> (cast: Field, contact: Field) {
    (blur(shifted(cover, away.x * distance * u, away.y * distance * u), softness * u),
     blur(shifted(cover, away.x * 4 * u, away.y * 4 * u), 5 * u))
}

// MARK: Noise, deterministic so every run draws the same icon

struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
    var h = UInt64(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFF) / 65535 * 2 - 1
}

/// Smooth value noise, -1...1, summed over octaves. `cell` is the coarsest feature in pixels.
func fbm(_ n: Int, cell: Float, octaves: Int, seed: Int) -> Field {
    var out = Field(n)
    var amp: Float = 1, size = max(cell, 1), total: Float = 0
    for o in 0..<octaves {
        let s = seed &+ o &* 101
        for y in 0..<n {
            let fy = Float(y) / size, iy = Int(fy.rounded(.down)), ty = smoothstep(0, 1, fy - Float(iy))
            for x in 0..<n {
                let fx = Float(x) / size, ix = Int(fx.rounded(.down)), tx = smoothstep(0, 1, fx - Float(ix))
                let top = hash(ix, iy, s) * (1 - tx) + hash(ix + 1, iy, s) * tx
                let bottom = hash(ix, iy + 1, s) * (1 - tx) + hash(ix + 1, iy + 1, s) * tx
                out.v[y * n + x] += amp * (top * (1 - ty) + bottom * ty)
            }
        }
        total += amp
        amp *= 0.5
        size = max(size / 2, 1)
    }
    return out.map { $0 / total }
}

// MARK: Shapes (1024 units, y up)

/// A character as an outline, centred on the origin, `height` tall.
func kanjiPath(_ character: String, height: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("HiraMinProN-W6" as CFString, height * 1.18, nil)
    var chars = Array(character.utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), let glyph = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("Hiragino Mincho ProN W6 with \(character) is needed to draw the icon") }
    let box = glyph.boundingBoxOfPath
    var move = CGAffineTransform(translationX: -box.midX, y: -box.midY)
    return glyph.copy(using: &move)!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func polar(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }

/// The tile, on the macOS grid: 824 in 1024, corner radius about 185.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)

// MARK: The room every surface reflects

/// Coordinates are canvas fractions, y down. A flat mirror shows the room where
/// it stands (a planar reflection); a tilted surface looks further across it.
struct Room {
    var window: (x0: Float, y0: Float, x1: Float, y1: Float)
    var detail: Detail
    var night = false
    var top = colour(0xDAD8D4), bottom = colour(0x24211F)

    var glow: V3 { night ? colour(0xFFC27A) * 1.9 : V3(x: 1.45, y: 1.41, z: 1.32) }

    func wall(_ ey: Float) -> V3 { mix(top, bottom, smoothstep(-0.15, 1.05, ey)) }

    /// The andon, a paper lamp low on the right: a warm point in the metal.
    func lamp(_ ex: Float, _ ey: Float) -> V3 {
        let dx = ex - 0.95, dy = ey - 0.9
        return colour(0xFFB467) * (1.1 * exp(-(dx * dx + dy * dy) / 0.0006))
    }

    /// What a polished surface sees.
    func sharp(_ ex: Float, _ ey: Float) -> V3 {
        let c = wall(ey) + lamp(ex, ey)
        let w = window, e: Float = 0.004
        let ix = smoothstep(w.x0 - e, w.x0 + e, ex) * smoothstep(w.x1 + e, w.x1 - e, ex)
        let iy = smoothstep(w.y0 - e, w.y0 + e, ey) * smoothstep(w.y1 + e, w.y1 - e, ey)
        let inside = ix * iy
        guard inside > 0 else { return c }
        return mix(c, pane((ex - w.x0) / (w.x1 - w.x0), (ey - w.y0) / (w.y1 - w.y0)), inside)
    }

    /// What a worn or rough surface sees: the window as a broad glow.
    func soft(_ ex: Float, _ ey: Float) -> V3 {
        let w = window
        let dx = (ex - (w.x0 + w.x1) / 2) / ((w.x1 - w.x0) * 0.85)
        let dy = (ey - (w.y0 + w.y1) / 2) / ((w.y1 - w.y0) * 0.85)
        let g = 0.7 * exp(-(dx * dx + dy * dy))
        let lx = ex - 0.95, ly = ey - 0.9
        let lampGlow = colour(0xFFB467) * (0.25 * exp(-(lx * lx + ly * ly) / 0.03))
        return wall(ey) + (night ? colour(0xFFCB85) : white) * g + lampGlow
    }

    /// The shoji: paper glowing in a frame, kumiko in a grid of three by four.
    func pane(_ u: Float, _ v: Float) -> V3 {
        let wood = colour(0x2B2019), f: Float = 0.045
        let fu = smoothstep(f - 0.01, f, u) * smoothstep(1 - f + 0.01, 1 - f, u)
        let fv = smoothstep(f - 0.01, f, v) * smoothstep(1 - f + 0.01, 1 - f, v)
        let cols: Float = detail == .glyph ? 2 : 3, rows: Float = detail == .glyph ? 2 : 4
        let gu = (u - f) / (1 - 2 * f) * cols, gv = (v - f) / (1 - 2 * f) * rows
        let du = abs(gu - gu.rounded()) / cols, dv = abs(gv - gv.rounded()) / rows
        let bar = max(smoothstep(0.016, 0.008, du), smoothstep(0.016, 0.008, dv))
        return mix(wood, mix(glow, wood, bar), fu * fv)
    }
}

/// Where a surface at (fx, fy) with this normal looks, for a viewer straight in front.
func reflected(_ n: V3, _ fx: Float, _ fy: Float, reach: Float) -> (Float, Float) {
    let rz = max(0.08, 2 * n.z * n.z - 1)
    return (fx + 2 * n.z * n.x / rz * reach, fy + 2 * n.z * n.y / rz * reach)
}

func normal(_ h: Field, _ x: Int, _ y: Int) -> V3 {
    let gx = (h[x + 1, y] - h[x - 1, y]) * 0.5, gy = (h[x, y + 1] - h[x, y - 1]) * 0.5
    return V3(x: -gx, y: -gy, z: 1).normalised
}

// MARK: Materials

/// Polished or worn metal: the room, tinted by the metal, plus a highlight from the window.
func metal(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, tint: V3, rough: Float, reach: Float) -> V3 {
    let (ex, ey) = reflected(nrm, fx, fy, reach: reach)
    var env = room.sharp(ex, ey)
    if rough > 0.01 { env = mix(env, room.soft(ex, ey), rough) }
    let nh = max(0, nrm.dot(halfway))
    let spec = (1 - rough) * 0.35 * pow(nh, 140) + rough * 0.22 * pow(nh, 18)
    let fill = tint * (0.05 + 0.1 * max(0, nrm.dot(light)))
    return tint * env + white * spec + fill
}

/// Urushi: near-black, deep, and it reflects the window faintly.
func lacquer(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, shade: Float, base: V3 = lacquerBase) -> V3 {
    let lit = clamp01(nrm.dot(light))
    let diffuse = base * (0.5 + 0.7 * lit) * (1 - 0.75 * shade)
    let (ex, ey) = reflected(nrm, fx, fy, reach: 0.5)
    let f = 0.06 + 0.94 * pow(1 - max(0, nrm.z), 5)
    let nh = max(0, nrm.dot(halfway))
    let env = room.soft(ex, ey) * 0.8 + room.sharp(ex, ey) * 0.2
    return diffuse + env * (f * (1 - 0.6 * shade)) + white * (0.3 * pow(nh, 300))
}

// MARK: Painting

/// Rolls bright values off softly instead of clipping them, so the window keeps its rows.
func tone(_ v: Float) -> Float { v <= 0.82 ? max(0, v) : 0.82 + 0.18 * (1 - exp(-(v - 0.82) / 0.18)) }

func image(_ n: Int, _ shade: (Int, Int) -> (V3, Float)) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
        for x in 0..<n {
            let (c, a) = shade(x, y), i = (y * n + x) * 4
            rgba[i + 0] = UInt8(tone(c.x) * a * 255)
            rgba[i + 1] = UInt8(tone(c.y) * a * 255)
            rgba[i + 2] = UInt8(tone(c.z) * a * 255)
            rgba[i + 3] = UInt8(clamp01(a) * 255)
        }
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// Pixel centre in canvas fractions, y down.
func frac(_ x: Int, _ y: Int, _ n: Int) -> (Float, Float) { ((Float(x) + 0.5) / Float(n), (Float(y) + 0.5) / Float(n)) }

// MARK: Shared renderer pieces

/// A raised line of half-round section: 1 on its crest, 0 at `half` units away.
func bead(_ d: Float, _ half: Float) -> Float {
    let q = d / half
    return q >= 1 ? 0 : (1 - q * q).squareRoot()
}

/// Smooth value noise at a point, -1...1.
func vnoise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
    let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
    let tx = smoothstep(0, 1, x - Float(ix)), ty = smoothstep(0, 1, y - Float(iy))
    let a = hash(ix, iy, seed) * (1 - tx) + hash(ix + 1, iy, seed) * tx
    let b = hash(ix, iy + 1, seed) * (1 - tx) + hash(ix + 1, iy + 1, seed) * tx
    return a * (1 - ty) + b * ty
}

/// Shadows from the window, by marching toward it across a height field in pixels.
func sunShadow(_ h: Field, steps: Int, stride: Float, soft: Float) -> Field {
    let n = h.n, l = (light.x * light.x + light.y * light.y).squareRoot()
    let dx = light.x / l, dy = light.y / l, rise = light.z / l
    var out = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let h0 = h.v[y * n + x]
            var s: Float = 0
            for k in 1...steps {
                let t = Float(k) * stride
                let over = h[Int(Float(x) + dx * t + 0.5), Int(Float(y) + dy * t + 0.5)] - h0 - t * rise
                if over > 0 { s = max(s, min(1, over / soft)) }
            }
            out.v[y * n + x] = s
        }
    }
    return out
}

// MARK: Shared pieces

/// Jittered cells: a domed grain per cell and a tone for it (gravel, flecks).
func pebble(_ X: Float, _ Y: Float, cell: Float, seed: Int) -> (bump: Float, tone: Float) {
    let gx = X / cell, gy = Y / cell
    let ix = Int(gx.rounded(.down)), iy = Int(gy.rounded(.down))
    var best: Float = 9, tone: Float = 0
    for oy in -1...1 {
        for ox in -1...1 {
            let cx = ix + ox, cy = iy + oy
            let px = Float(cx) + 0.5 + 0.38 * hash(cx, cy, seed), py = Float(cy) + 0.5 + 0.38 * hash(cx, cy, seed + 1)
            let d2 = (gx - px) * (gx - px) + (gy - py) * (gy - py)
            if d2 < best { best = d2; tone = hash(cx, cy, seed + 2) }
        }
    }
    let b = max(0, 1 - best.squareRoot() / 0.72)
    return ((b * (2 - b)).squareRoot(), tone)
}

func occlusion(_ h: Field, _ near: Field, _ wide: Field, _ i: Int, _ u: Float) -> Float {
    1 - 0.45 * clamp01((near.v[i] - h.v[i]) / (2 * u)) - 0.3 * clamp01((wide.v[i] - h.v[i]) / (6 * u))
}

// MARK: Sekimori-ishi: 関守石, the stone that keeps the gate

// In a Japanese garden, a round stone tied with cord and set on a path means
// "no further". Nothing is locked and everyone understands: a polite, absolute
// stop. The raked gravel rings round it are the traffic, turned aside.

/// Lays a cord of round section along a polyline (1024 units, y down), keeping
/// whichever surface is higher. It rides on the surface under its centreline;
/// the twist and the fibres are laid in the cord's own coordinates, so they
/// turn with it.
struct Cords {
    let n: Int, u: Float
    var height: Field, mask: Field, ply: Field, fibre: Field, pale: Field
    let ground: Field

    init(ground: Field, u: Float) {
        n = ground.n; self.u = u; self.ground = ground; height = ground
        mask = Field(n); ply = Field(n); fibre = Field(n); pale = Field(n)
    }

    mutating func lay(_ points: [(Float, Float)], half: Float, lift: (Float) -> Float = { _ in 0 },
                      plied: Bool = true, paleness: Float = 0, seed: Int = 0) {
        guard points.count > 1 else { return }
        var lengths: [Float] = [0]
        for j in 1..<points.count {
            let dx = points[j].0 - points[j - 1].0, dy = points[j].1 - points[j - 1].1
            lengths.append(lengths[j - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = max(lengths.last!, 1e-3), alpha: Float = 0.9
        for j in 1..<points.count {
            let ax = points[j - 1].0 * u, ay = points[j - 1].1 * u, bx = points[j].0 * u, by = points[j].1 * u
            let vx = bx - ax, vy = by - ay, len2 = max(vx * vx + vy * vy, 1e-6), segLen = lengths[j] - lengths[j - 1]
            let pad = half * u + 2
            let x0 = max(0, Int(min(ax, bx) - pad)), x1 = min(n - 1, Int(max(ax, bx) + pad))
            let y0 = max(0, Int(min(ay, by) - pad)), y1 = min(n - 1, Int(max(ay, by) + pad))
            guard x0 <= x1 && y0 <= y1 else { continue }
            for py in y0...y1 {
                for px in x0...x1 {
                    let fx = Float(px) + 0.5, fy = Float(py) + 0.5
                    let t = clamp01(((fx - ax) * vx + (fy - ay) * vy) / len2)
                    let cx = ax + vx * t, cy = ay + vy * t
                    let dist = ((cx - fx) * (cx - fx) + (cy - fy) * (cy - fy)).squareRoot() / u
                    guard dist < half else { continue }
                    let side: Float = (vx * (fy - ay) - vy * (fx - ax)) > 0 ? 1 : -1
                    let across = side * dist, tt = across / half, round = (1 - tt * tt).squareRoot()
                    let s = lengths[j - 1] + t * segLen
                    var bump: Float = 0, fib: Float = 0
                    if plied {
                        let phase = s / (half * 2.0) + tt * 0.42
                        bump = pow(sin(.pi * (phase - phase.rounded(.down))), 0.6)
                    }
                    let along = s * cos(alpha) + across * sin(alpha), cross = -s * sin(alpha) + across * cos(alpha)
                    fib = vnoise(cross / 0.7, along / 7, 101 + seed)
                    let base = ground[Int(cx), Int(cy)] / u
                    let z = base + lift(s / total) + half * 0.92 * round + (plied ? half * 0.2 * bump * round : 0)
                    let i = py * n + px
                    if z * u > height.v[i] {
                        height.v[i] = z * u
                        mask.v[i] = max(mask.v[i] * (paleness > 0 ? 1 : 0), clamp01((half - dist) * u + 0.5))
                        ply.v[i] = plied ? bump : 0.6
                        fibre.v[i] = fib
                        pale.v[i] = paleness
                    }
                }
            }
        }
    }
}

func bezier(_ p: [(Float, Float)], steps: Int) -> [(Float, Float)] {
    (0...steps).map { k in
        let t = Float(k) / Float(steps), m = 1 - t
        let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, e = t * t * t
        return (a * p[0].0 + b * p[1].0 + c * p[2].0 + e * p[3].0, a * p[0].1 + b * p[1].1 + c * p[2].1 + e * p[3].1)
    }
}

/// Shadows that harden near the caster and soften further away, as a window's do.
func softShadow(_ h: Field, steps: Int, stride: Float, soft: Float, spread: Float) -> Field {
    let n = h.n, l = (light.x * light.x + light.y * light.y).squareRoot()
    let dx = light.x / l, dy = light.y / l, rise = light.z / l
    var out = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let h0 = h.v[y * n + x]
            var s: Float = 0
            for k in 1...steps {
                let t = Float(k) * stride
                let over = h[Int(Float(x) + dx * t + 0.5), Int(Float(y) + dy * t + 0.5)] - h0 - t * rise
                if over > 0 { s = max(s, min(1, over / (soft + t * spread))) }
            }
            out.v[y * n + x] = s
        }
    }
    return out
}

func renderSekimori(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let cx: Float = 494, cy: Float = 486
    let A: Float = d == .glyph ? 276 : 246, B = A * 0.88, mean = A * 0.94
    let H: Float = d == .glyph ? 122 : 116
    let half: Float = d == .glyph ? 30 : d == .mark ? 19 : 12.5
    let lambda: Float = d == .full ? 21 : d == .mark ? 38 : 70
    let tilt: Float = -0.16

    // Pass 1: gravel and stone.
    let lumps = fbm(n, cell: 110 * u, octaves: 2, seed: 3)
    let mottle = fbm(n, cell: 140 * u, octaves: 3, seed: 5), mottle2 = fbm(n, cell: 30 * u, octaves: 3, seed: 6)
    let pits = d == .full ? fbm(n, cell: 2 * u, octaves: 2, seed: 8) : Field(n)
    var ground = Field(n), stone = Field(n), vein = Field(n), grain = Field(n), stoneQ = Field(n, 2)
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u - cx, Y = (Float(y) + 0.5) / u - cy
            let theta = atan2(Y, X)
            let wobble = 1 + 0.035 * sin(2 * theta + 0.7) + 0.025 * sin(3 * theta + 2.1) + 0.012 * sin(5 * theta + 0.3)
            let q = ((X / A) * (X / A) + (Y / B) * (Y / B)).squareRoot() / wobble
            stoneQ.v[i] = q

            // Hand-raked: the rings wander, come in passes of five teeth, and
            // the raker's start and finish do not quite meet.
            var rd = (q - 1) * mean
            let hand = d == .glyph ? 0 : 7 * vnoise(theta * 2.2 + 3, 0.5, 11) + 2.5 * vnoise(theta * 9 + 1, 1.5, 12)
            var around = theta - 2.3
            if around < 0 { around += 2 * .pi }
            // Where the rake closed the circle the rings bunch up, rather than break.
            let seam = 0.35 * lambda * (around / (2 * .pi) + 1 - smoothstep(0, 0.35, around))
            let ringD = rd + hand + (d == .glyph ? 0 : seam)
            var g: Float = 1.2
            if rd > 0 {
                let berm = 3 * exp(-((rd - 5) / 6) * ((rd - 5) / 6))
                let start = smoothstep(14, 24, rd)
                let pass = Int(((ringD - 18) / (lambda * 5)).rounded(.down))
                let depth = 0.85 + 0.3 * (hash(pass, 3, 13) + 1) / 2
                let rake = 0.5 + 0.5 * cos(2 * .pi * (ringD - 18) / lambda)
                g = (d == .glyph ? 6.5 : 5.4) * depth * pow(rake, 1.3) * start + 1.2 * (1 - start) + berm
            }
            if d >= .mark {
                let p = pebble(X + cx, Y + cy, cell: d == .full ? 3.0 : 6, seed: 7)
                g += p.bump * (d == .full ? 0.8 : 0.5)
                grain.v[i] = p.tone
                if d == .full {
                    let big = pebble(X + cx, Y + cy, cell: 11, seed: 23)
                    if big.tone > 0.93 { g += big.bump * 2.2; grain.v[i] = big.tone > 0.985 ? 0.9 : big.tone > 0.96 ? 0.6 : -0.2 }
                }
            }
            rd = 0
            let cover = clamp01((1 - q) * mean * u + 0.5)
            var surface: Float = 0
            if q < 1 {
                surface = H * pow(max(0, 1 - pow(q, 2.6)), 0.55) * (1 + 0.06 * X / A) + lumps.v[i] * 1.2 * (1 - q * q)
                // A quartz vein, and a thinner one, running through the stone.
                if d >= .mark {
                    let vx = X * cos(0.5) + Y * sin(0.5), vy = -X * sin(0.5) + Y * cos(0.5)
                    let w1 = 4.5 + 2 * vnoise(vx / 40, 1.3, 5), d1 = abs(vy - (40 + 22 * sin(vx * 0.011 + 0.8)))
                    let w2: Float = 1.8, d2 = abs(vy - (-96 + 10 * sin(vx * 0.02 + 2)))
                    let v = max(smoothstep(w1 + 1.5, w1 - 2.2, d1), d == .full ? smoothstep(w2 + 0.8, w2 - 1.2, d2) * 0.8 : 0)
                    vein.v[i] = v
                    surface += v * 0.6
                }
                surface += pits.v[i] * 0.025
            }
            stone.v[i] = cover
            ground.v[i] = (g * (1 - cover) + surface * cover) * u
        }
    }

    // Pass 2: the cord. Two turns crossed over the top, bound at the crossing,
    // tied off in a bow with two cut tails.
    var cords = Cords(ground: ground, u: u)
    let ca = cos(tilt), sa = sin(tilt)
    func rot(_ p: (Float, Float)) -> (Float, Float) { (cx + p.0 * ca - p.1 * sa, cy + p.0 * sa + p.1 * ca) }
    for (k, dir) in [(Float(1), Float(0)), (Float(0), Float(1))].enumerated() {
        var line: [(Float, Float)] = []
        var s: Float = -A * 1.1
        while s <= A * 1.1 {
            let p = rot((dir.0 * s, dir.1 * s))
            let gx = Int(p.0 * u), gy = Int(p.1 * u)
            if gx >= 0 && gy >= 0 && gx < n && gy < n && stone.v[gy * n + gx] > 0.5 && stoneQ.v[gy * n + gx] < 0.975 { line.append(p) }
            s += 3
        }
        cords.lay(line, half: half, lift: { _ in Float(k) * 0.8 }, seed: k)
    }
    if d >= .mark {
        // The knot: three tight turns binding the crossing, one tall handle
        // loop to lift the stone by, and two cut tails, frayed at the ends.
        let e: (Float, Float) = (0.7071, 0.7071), nrmE: (Float, Float) = (-0.7071, 0.7071)
        func at(_ along: Float, _ side: Float) -> (Float, Float) {
            rot((e.0 * along * half + nrmE.0 * side * half, e.1 * along * half + nrmE.1 * side * half))
        }
        let bind = d == .full ? 3 : 2
        for w in 0..<bind {
            let off = (Float(w) - Float(bind - 1) / 2) * 1.85
            cords.lay(bezier([at(off, -2.2), at(off + 0.1, -0.8), at(off + 0.1, 0.8), at(off, 2.2)], steps: 16),
                      half: half * 0.95, lift: { s in half * 0.85 + half * 0.4 * sin(.pi * s) }, seed: 10 + w)
        }
        let handle = bezier([at(1.6, -0.9), at(4.2, -2.6), at(9.0, -1.9), at(9.4, 0)], steps: 40)
            + bezier([at(9.4, 0), at(9.0, 1.9), at(4.2, 2.6), at(1.6, 0.9)], steps: 40).dropFirst()
        cords.lay(Array(handle), half: half * 0.88, lift: { s in half * 1.7 + half * 2.6 * sin(.pi * s) }, seed: 20)
        if d == .full {
            for (side, spread) in [(Float(-1), Float(-2.9)), (Float(1), Float(2.4))] {
                let tail = bezier([at(-1.4, side * 0.7), at(-3.6, side * 1.0), at(-6.4, spread * 0.8), at(-9.6, spread)], steps: 40)
                cords.lay(tail, half: half * 0.82, lift: { s in half * 1.4 * (1 - s) * (1 - s) + 0.4 }, seed: 30 + Int(side))
                let tip = tail[tail.count - 1], prev = tail[tail.count - 4]
                let dx = tip.0 - prev.0, dy = tip.1 - prev.1, l = (dx * dx + dy * dy).squareRoot()
                var rnd = Random(state: UInt64(70 + Int(side * 3)))
                for _ in 0..<18 {
                    let spreadA = Float(rnd.range(-0.75, 0.75)), len = Float(rnd.range(9, 22)) * half / 12.5
                    let ang = atan2(dy / l, dx / l) + spreadA
                    let o = Float(rnd.range(-0.6, 0.6)) * half * 0.7
                    let p0 = (tip.0 - dy / l * o, tip.1 + dx / l * o)
                    let p1 = (p0.0 + cos(ang) * len * 0.5, p0.1 + sin(ang) * len * 0.5 + Float(rnd.range(-2, 2)))
                    let p2 = (p0.0 + cos(ang + spreadA * 0.3) * len, p0.1 + sin(ang + spreadA * 0.3) * len)
                    cords.lay([p0, p1, p2], half: Float(rnd.range(0.9, 1.5)), lift: { s in 0.6 * (1 - s) }, plied: false, paleness: 1, seed: 40)
                }
            }
            // Stray fibres standing off the cord.
            var rnd = Random(state: 99)
            for _ in 0..<150 {
                let s = Float(rnd.range(CGFloat(-A * 0.95), CGFloat(A * 0.95))), which = rnd.next() < 0.5
                let side: Float = rnd.next() < 0.5 ? -1 : 1
                let base = which ? (s, side * half * 0.9) : (side * half * 0.9, s)
                let p0 = rot(base)
                let gx = Int(p0.0 * u), gy = Int(p0.1 * u)
                guard gx >= 0 && gy >= 0 && gx < n && gy < n && stone.v[gy * n + gx] > 0.9 else { continue }
                let ang = Float(rnd.range(0, 2 * .pi)), len = Float(rnd.range(2.5, 8))
                let p1 = (p0.0 + cos(ang) * len, p0.1 + sin(ang) * len)
                let mid = ((p0.0 + p1.0) / 2 + Float(rnd.range(-1.5, 1.5)), (p0.1 + p1.1) / 2 + Float(rnd.range(-1.5, 1.5)))
                cords.lay([p0, mid, p1], half: 0.38, lift: { s in half * 0.9 * (1 - s) + 0.3 }, plied: false, paleness: 0.75, seed: 50)
            }
        }
    } else {
        // Small sizes: one knot, no bow.
        let r = half * 2.2
        var ring: [(Float, Float)] = []
        for k in 0...24 { let a = Float(k) / 24 * 2 * .pi; ring.append((cx + cos(a) * r * 0.3, cy + sin(a) * r * 0.3)) }
        cords.lay(ring, half: r * 0.75, lift: { _ in half * 0.8 }, plied: false)
    }

    let h = cords.height
    let shadow = blur(softShadow(h, steps: 40, stride: 3.8 * u, soft: 1.4 * u, spread: 0.06), 1.2 * u)
    let near = blur(h, 4 * u), wide = blur(h, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let nh = max(0, nrm.dot(halfway))
        let falloff = 1.06 - 0.12 * (fx * 0.45 + fy * 0.55)
        // Shirakawa gravel: white feldspar, grey quartz, beige, the odd fleck of biotite.
        let t = grain.v[i]
        var gravel = colour(0xEFECE5)
        if t > 0.93 { gravel = colour(0x5A554F) } else if t > 0.55 { gravel = colour(0xDCD2C2) } else if t < -0.5 { gravel = colour(0xC6C2B9) }
        var out = gravel * ((0.58 + 0.5 * lit) * falloff * (1 - 0.7 * sh) * occl) + white * (0.05 * pow(nh, 20) * (1 - sh))
        if stone.v[i] > 0 {
            // River basalt: mottled, faintly pitted, worn to a satin sheen.
            var base = mix(colour(0x25262A), colour(0x4F5055), clamp01(0.5 + 1.0 * mottle.v[i]))
            base = mix(base, colour(0x5A5650), clamp01(mottle2.v[i] * 0.8) * 0.35) * (1 - 0.12 * clamp01(pits.v[i]))
            base = mix(base, colour(0xD3CEC4) * (1 - 0.1 * pits.v[i]), vein.v[i] * 0.82)
            let (ex, ey) = reflected(nrm, fx, fy, reach: 0.6)
            let fres = 0.035 + 0.965 * pow(1 - max(0, nrm.z), 5)
            let env = mix(room.sharp(ex, ey), room.soft(ex, ey), 0.6)
            let col = base * ((0.3 + 0.86 * lit) * (1 - 0.65 * sh) * occl)
                + env * ((0.04 + 0.55 * fres) * (1 - 0.45 * sh) * occl)
                + white * ((0.12 * pow(nh, 30) + 0.22 * pow(nh, 160)) * (1 - sh))
            out = mix(out, col, stone.v[i])
        }
        let m = cords.mask.v[i]
        if m > 0 {
            // Cotton cord dyed shu: deep in the lay, bright on each ply, pale where frayed.
            let tone = clamp01(0.3 + 0.45 * cords.ply.v[i] + 0.25 * cords.fibre.v[i])
            var dye = mix(colour(0x7E1C12), colour(0xD84B35), tone)
            dye = mix(dye, colour(0xE8957A), cords.pale.v[i] * 0.7)
            let col = dye * ((0.26 + 0.86 * lit) * (1 - 0.6 * sh) * occl) + white * (0.09 * pow(nh, 9) * (1 - sh))
            out = mix(out, col, m)
        }
        return (out, 1)
    }
}

// MARK: Shimenawa: 注連縄, the rope that marks a sacred boundary

/// A shimenawa hangs where the everyday world stops and the protected one
/// begins: a twisted rice-straw rope, thick in the middle, with zigzag paper
/// streamers (shide) below it. Here it hangs across a vermilion lacquered beam.
func renderShimenawa(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let lift: Float = 70
    func centre(_ X: Float) -> Float { let xn = X / 1024; return 352 + 60 * (1 - (2 * xn - 1) * (2 * xn - 1)) }
    func girth(_ X: Float) -> Float { (d == .glyph ? 132 : 112) * pow(0.5 + 0.5 * sin(.pi * X / 1024), 0.8) }
    let shideX: [Float] = [330, 694]
    let segments = d == .glyph ? 3 : 4
    let segH: Float = d == .glyph ? 124 : 104, segW: Float = d == .glyph ? 92 : 72
    let grain = d == .full ? fbm(n, cell: 30 * u, octaves: 2, seed: 61) : Field(n)
    let fibreTex = d == .full ? fbm(n, cell: 4 * u, octaves: 2, seed: 63) : Field(n)
    var h = Field(n), hs = Field(n), rope = Field(n), paperMask = Field(n), strand = Field(n), fibre = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            // The beam: lacquer over wood, the grain only just showing through.
            var height = grain.v[i] * 0.04
            let yc = centre(X), w = girth(X), v = (Y - yc) / w
            if abs(v) < 1 {
                // Three strands laid in a helix; each strand a bundle of straw.
                let a = asin(v), pitch = w * 2.3
                let ph = X / pitch * 3 + a / .pi * 2.7
                let s = ph - ph.rounded(.down)
                let bulge = pow(sin(.pi * s), 0.55), round = (1 - v * v).squareRoot()
                height = lift + w * 0.9 * round + w * 0.13 * bulge * round
                rope.v[i] = clamp01((1 - abs(v)) * w * u + 0.5)
                strand.v[i] = bulge
                if d == .full { fibre.v[i] = vnoise(ph * 16, (Y - X * 0.35) / 2.2, 81) }
            }
            // Shide: a strip cut and folded into a zigzag, each fold a facet.
            for sx in shideX {
                let top = centre(sx) + girth(sx) * 0.5
                for k in 0..<segments {
                    let y0 = top + Float(k) * segH, y1 = y0 + segH
                    guard Y >= y0 && Y < y1 else { continue }
                    let odd = k % 2 == 1
                    let left = sx - segW / 2 + (odd ? 1 : -1) * segW * 0.4 + (odd ? -1 : 1) * segW * 0.38 * (Y - y0) / segH
                    let right = left + segW
                    guard X > left && X < right else { continue }
                    let tiltK: Float = odd ? -0.24 : 0.24
                    let ph = lift * 0.5 + 8 + tiltK * (X - (left + right) / 2) - Float(k) * 2
                    if ph > height {
                        height = ph + fibreTex.v[i] * 0.4
                        let edge = min(min(X - left, right - X), min(Y - y0 + (k == 0 ? 99 : 0), y1 - Y + (k < segments - 1 ? 99 : 0)))
                        paperMask.v[i] = clamp01(edge * u + 0.5)
                        rope.v[i] = 0
                    }
                }
            }
            h.v[i] = height * u
            hs.v[i] = (paperMask.v[i] > 0 ? height - lift * 0.5 : rope.v[i] > 0 ? height - lift + 8 : height) * u
        }
    }
    let shadow = blur(sunShadow(h, steps: 30, stride: 3.4 * u, soft: 3 * u), 3 * u)
    let near = blur(hs, 4 * u), wide = blur(hs, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(hs, x, y)
        let onRope = rope.v[i] > 0 || paperMask.v[i] > 0
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = onRope ? occlusion(hs, near, wide, i, u) : 1
        let nh = max(0, nrm.dot(halfway))
        let beam = colour(0xB9321E) * (1 + 0.05 * grain.v[i])
        var out = lacquer(nrm, fx, fy, room, shade: sh, base: beam) * occl
        if rope.v[i] > 0 {
            let straw = mix(colour(0xB48D4C), colour(0xE6CD8E), clamp01(0.5 + 0.5 * fibre.v[i]))
            let col = straw * ((0.3 + 0.8 * lit) * (0.72 + 0.28 * strand.v[i]) * (1 - 0.6 * sh) * occl)
                + white * (0.08 * pow(nh, 10) * (1 - sh))
            out = mix(out, col, rope.v[i])
        }
        if paperMask.v[i] > 0 {
            let col = colour(0xFBF8F1) * ((0.66 + 0.5 * lit) * (1 - 0.45 * sh) * occl * (1 + 0.03 * fibreTex.v[i]))
            out = mix(out, col, paperMask.v[i])
        }
        return (out, 1)
    }
}

// MARK: Kikkō: 亀甲, a cloisonné medallion of nested barriers

/// Shippō, Japanese cloisonné: gold wire laid on a plate, the cells filled with
/// glass enamel and fired. The hexagon is Kekkai's motif. Barriers nest round a
/// sealed core: a lattice of tortoiseshell cells (kikkō, the old pattern of
/// protection), a band of translucent shu over an engraved sunburst, and a
/// faceted gold core.
func hexApothem(_ x: Float, _ y: Float) -> Float {
    let ax = abs(x), ay = abs(y)
    return max(ax, ax * 0.5 + ay * 0.8660254)
}

func renderKikko(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let cx: Float = 506, cy: Float = 504
    let A: Float = d == .glyph ? 344 : 326
    let T: Float = 14
    let cell: Float = 25
    let paperTex = fbm(n, cell: 140 * u, octaves: 4, seed: 71)
    var h = Field(n), plate = Field(n), kind = [UInt8](repeating: 0, count: n * n), shade = Field(n)
    // kind: 0 paper, 1 gold, 2 dark enamel, 3 shu enamel
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u - cx, Y = (Float(y) + 0.5) / u - cy
            let f = hexApothem(X, Y) / A
            let cover = clamp01((1 - f) * A * u + 0.5)
            var height: Float = d == .full ? vnoise(X / 1.2, Y / 9, 73) * 0.12 : 0
            plate.v[i] = cover
            guard cover > 0 else { h.v[i] = height * u; continue }
            var k: UInt8 = 2, e: Float = T + 6
            func wire(_ at: Float, _ halfW: Float) -> Float { bead(abs(f - at) * A, halfW) }
            if f > 0.88 {
                // The bezel: rounded, with a bead on its inner edge.
                let t = (f - 0.88) / 0.12
                e = T + 4 + 18 * pow(sin(.pi * min(1, t * 1.05)), 0.6)
                k = 1
            } else if d >= .mark && f > 0.64 {
                // Kikkō lattice: honeycomb cells, each with its own enamel.
                if d == .full {
                    let qa = (0.57735 * X - Y / 3) / cell, ra = (2.0 / 3.0 * Y) / cell
                    var rx = qa.rounded(), rz = ra.rounded()
                    let ry = (-qa - ra).rounded()
                    let dx = abs(rx - qa), dy = abs(ry + qa + ra), dz = abs(rz - ra)
                    if dx > dy && dx > dz { rx = -ry - rz } else if dy <= dz { rz = -rx - ry }
                    let ccx = cell * 1.7320508 * (rx + rz / 2), ccy = cell * 1.5 * rz
                    let edge = hexApothem(X - ccx, Y - ccy) / (cell * 0.8660254)
                    let w = bead((1 - edge) * cell * 0.866, 1.6)
                    let id = Int(rx) &* 7 &+ Int(rz) &* 13
                    shade.v[i] = (Int(rx - rz) % 3 + 3) % 3 == 0 ? 1 : 0.5 + 0.2 * hash(id, 1, 77)
                    e = T + 6 + 1.4 * (1 - edge * edge)
                    if w > 0 { e = max(e, T + 6.5 + 1.5 * w); if w > 0.3 { k = 1 } }
                } else {
                    shade.v[i] = 0.6
                }
                if k != 1 { k = 2 }
            } else if f > 0.36 || (d == .glyph && f > 0.34) {
                // Basse-taille: translucent shu over an engraved sunburst.
                k = 3
                let theta = atan2(Y, X)
                shade.v[i] = d == .glyph ? 0.4 : 0.55 * (0.5 + 0.5 * cos(theta * 84)) + 0.45 * (0.5 + 0.5 * cos(f * A / 4.2))
                e = T + 6 + 2.2 * sin(.pi * clamp01((f - 0.36) / 0.28))
            } else {
                // The core: faceted gold, rising to a small table.
                k = 1
                e = T + 8 + 34 * min(1, (0.34 - f) / 0.26)
            }
            for (at, w) in (d == .glyph ? [(0.88, 4.0), (0.34, 5.0)] : [(0.88, 3.6), (0.64, 4.6), (0.36, 4.6)]) as [(Float, Float)] {
                let b = wire(at, w)
                if b > 0 && T + 7.5 + 2 * b > e { e = T + 7.5 + 2 * b; if b > 0.25 { k = 1 } }
            }
            kind[i] = k
            h.v[i] = (cover * e + (1 - cover) * height) * u
        }
    }
    let shadow = blur(sunShadow(h, steps: 20, stride: 3 * u, soft: 1.6 * u), 1.4 * u)
    let near = blur(h, 4 * u), wide = blur(h, 16 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = occlusion(h, near, wide, i, u)
        let nh = max(0, nrm.dot(halfway))
        let falloff = 1.06 - 0.12 * (fx * 0.45 + fy * 0.55)
        let washi = colour(0xEFE9DD) * (1 + 0.04 * paperTex.v[i])
        var out = washi * (0.62 + 0.45 * lit) * falloff * (1 - 0.6 * sh) * occl
        guard plate.v[i] > 0 else { return (out, 1) }
        var col: V3
        let (ex, ey) = reflected(nrm, fx, fy, reach: 0.6)
        let fres = 0.045 + 0.955 * pow(1 - max(0, nrm.z), 5)
        switch kind[i] {
        case 1:
            col = metal(nrm, fx, fy, room, tint: colour(0xEBC468), rough: 0.14, reach: 0.6) * (1 - 0.4 * sh)
        case 3:
            let glass = mix(colour(0xF6744F), colour(0x8E1B0F), shade.v[i])
            col = glass * ((0.42 + 0.62 * lit) * (1 - 0.55 * sh)) + room.sharp(ex, ey) * fres + white * (0.5 * pow(nh, 220))
        default:
            let glass = mix(colour(0x15161D), colour(0x1F2D4C), shade.v[i] > 0.9 ? 1 : 0.15 * shade.v[i])
            col = glass * ((0.5 + 0.6 * lit) * (1 - 0.5 * sh)) + room.sharp(ex, ey) * fres + white * (0.5 * pow(nh, 220))
        }
        out = mix(out, col * occl, plate.v[i])
        return (out, 1)
    }
}

// MARK: Torii: 鳥居, the gate between outside and in

/// Walk through a torii and you have crossed a boundary. Vermilion lacquer,
/// a black kasagi curving up at its ends, and a plaque that names the place:
/// 結界. It stands in front of a plastered wall and throws its shadow on it.
func renderTorii(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: d)
    let base: Float = 64
    let letters = d >= .mark ? coverage(n) { ctx in
        for (ch, cy) in [("結", 1024 - 344.0), ("界", 1024 - 400.0)] as [(String, CGFloat)] {
            var place = CGAffineTransform(translationX: 512, y: cy)
            ctx.addPath(kanjiPath(ch, height: 42).copy(using: &place)!)
        }
        ctx.fillPath()
    } : Field(n)
    let plaster = fbm(n, cell: 60 * u, octaves: 4, seed: 91)
    let grit = d == .full ? fbm(n, cell: 1.8 * u, octaves: 2, seed: 93) : Field(n)
    let woodGrain = d == .full ? fbm(n, cell: 14 * u, octaves: 2, seed: 95) : Field(n)
    var h = Field(n), hs = Field(n), part = [UInt8](repeating: 0, count: n * n), cover = Field(n)
    // part: 0 wall, 1 vermilion, 2 black lacquer, 3 gold
    func profile(_ v: Float) -> Float { pow(max(0, 1 - pow(abs(2 * v - 1), 6)), 0.5) }
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            var height = plaster.v[i] * 1.2 + grit.v[i] * 0.3, p: UInt8 = 0, c: Float = 0
            func put(_ hh: Float, _ pp: UInt8, _ edge: Float) {
                // Over another part the edge stays solid; only against the wall is it blended.
                if hh > height { c = p != 0 ? 1 : clamp01(edge * u + 0.5); height = hh; p = pp }
            }
            let cc = (X - 512) / 410, curve = cc * cc
            // Pillars, leaning in a little, with black sleeves at the foot.
            for side: Float in [-1, 1] where Y > 250 {
                let px = 512 + side * (214 + (Y - 300) * 0.035), r = 37 + (Y - 300) * 0.012
                let dx = abs(X - px)
                if dx < r {
                    let sleeve = Y > 842
                    let ring = sleeve && Y < 856 ? 3 : 0
                    put(base + r * (1 - (dx / r) * (dx / r)).squareRoot() + Float(ring), sleeve ? 2 : 1, r - dx)
                }
            }
            // Nuki, the tie beam; the strut and the plaque above it.
            if Y > 452 && Y < 498 && abs(X - 512) < 318 {
                put(base + 22 * profile((Y - 452) / 46), 1, min(min(Y - 452, 498 - Y), 318 - abs(X - 512)))
            }
            if Y > 296 && Y < 452 && abs(X - 512) < 22 {
                put(base + 18 * profile((X - 490) / 44), 1, 22 - abs(X - 512))
            }
            if Y > 316 && Y < 432 && abs(X - 512) < 58 {
                let edge = min(min(Y - 316, 432 - Y), 58 - abs(X - 512))
                let frame = edge < 7 && d >= .mark
                let raised = letters.v[i] * 1.6
                put(base + 40 + min(4, edge * 0.8) + raised, frame || letters.v[i] > 0.5 || (d == .glyph && edge > 14) ? 3 : 2, edge)
            }
            // Shimaki under the kasagi, then the kasagi, curving up at its ends.
            let sTop = 262 - 26 * curve
            if Y > sTop && Y < sTop + 38 && abs(X - 512) < 372 {
                put(base + 30 * profile((Y - sTop) / 38), 1, min(min(Y - sTop, sTop + 38 - Y), 372 - abs(X - 512)))
            }
            let kTop = 194 - 50 * curve, kBottom = 262 - 26 * curve
            let reach = 412 - (Y - kTop) * 0.4
            if Y > kTop && Y < kBottom && abs(X - 512) < reach {
                let v = (Y - kTop) / (kBottom - kTop)
                put(base + 36 * pow(max(0, 1 - pow(abs(1.6 * v - 0.6), 4)), 0.5), 2, min(min(Y - kTop, kBottom - Y), reach - abs(X - 512)))
            }
            part[i] = p
            cover.v[i] = c
            h.v[i] = height * u
            // Shading sees each part's own profile, not its 64-unit stand-off from the wall.
            hs.v[i] = (p == 0 ? height : height - base + 6) * u
        }
    }
    let shadow = blur(sunShadow(h, steps: 34, stride: 4.6 * u, soft: 2 * u), 2.4 * u)
    let near = blur(hs, 4 * u), wide = blur(hs, 18 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(hs, x, y)
        // The torii stands well off the wall: shadow reaches it, contact darkness does not.
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i], occl = part[i] != 0 ? occlusion(hs, near, wide, i, u) : 1
        let falloff = 1.06 - 0.12 * (fx * 0.45 + fy * 0.55)
        let wall = colour(0xEFEBE3) * (1 + 0.025 * plaster.v[i] + 0.02 * grit.v[i])
        var out = wall * (0.64 + 0.42 * lit) * falloff * (1 - 0.55 * sh) * occl
        guard part[i] != 0 else { return (out, 1) }
        // Round lacquer turns its edges away; keep them from going black.
        let soft = V3(x: nrm.x * 0.6, y: nrm.y * 0.6, z: nrm.z).normalised
        let col: V3
        switch part[i] {
        case 1: col = lacquer(soft, fx, fy, room, shade: sh, base: colour(0xD9412B) * (1 + 0.04 * woodGrain.v[i]))
        case 3: col = metal(nrm, fx, fy, room, tint: colour(0xE6BE62), rough: 0.3, reach: 0.6) * (1 - 0.4 * sh)
        default: col = lacquer(soft, fx, fy, room, shade: sh)
        }
        out = mix(out, col * occl, cover.v[i])
        return (out, 1)
    }
}

// MARK: Variants

struct Variant {
    let id: String, name: String, kanji: String, line: String
    let render: (Detail, Int) -> CGImage
    var story = ""
    var swatches: [(String, UInt32)] = []
}

let variants = [
    Variant(id: "sekimori", name: "Sekimori-ishi", kanji: "関守石", line: "The stone that means no further", render: renderSekimori,
            story: """
            In a Japanese garden, a round stone tied with cord and set on a
            path means "no further". Nothing is locked and everyone understands.
            That is Kekkai: a polite, absolute stop. The raked gravel rings round
            the stone are the traffic, turned aside. The cord is shu, the one
            colour Kekkai keeps for the barrier.
            """,
            swatches: [("shu", 0xD9412B), ("basalt", 0x3A3B40), ("gravel", 0xE7E3D9), ("sumi", 0x141214)]),
    Variant(id: "shimenawa", name: "Shimenawa", kanji: "注連縄", line: "The rope at a sacred boundary", render: renderShimenawa,
            story: """
            A shimenawa hangs where the everyday world stops and the protected
            one begins: rice straw twisted into a rope, thick in the middle,
            with zigzag paper streamers (shide) below it. Here it hangs across a
            vermilion lacquered beam.
            """,
            swatches: [("shu", 0xD9412B), ("straw", 0xD9BC7A), ("shide", 0xF7F3EA), ("sumi", 0x141214)]),
    Variant(id: "kikko", name: "Kikkō", kanji: "亀甲", line: "Cloisonné barriers round a gold core", render: renderKikko,
            story: """
            Shippō, Japanese cloisonné: gold wire on a plate, the cells filled
            with glass enamel and fired. Kekkai's hexagon becomes nested
            barriers: a lattice of tortoiseshell cells, the old pattern of
            protection; a band of translucent shu over an engraved sunburst; and
            a faceted gold core, the Mac they keep.
            """,
            swatches: [("shu", 0xD9412B), ("gold", 0xEBC468), ("ai", 0x1F2D4C), ("washi", 0xEFE9DD)]),
    Variant(id: "torii", name: "Torii", kanji: "鳥居", line: "The gate, named 結界", render: renderTorii,
            story: """
            Walk through a torii and you have crossed a boundary. Vermilion
            lacquer, a black kasagi curving up at its ends, and a plaque that
            names the place: 結界. It stands in front of a plastered wall and
            throws its shadow on it.
            """,
            swatches: [("shu", 0xD9412B), ("urushi", 0x141214), ("gold", 0xE6BE62), ("shikkui", 0xEFEBE3)]),
]

/// Rendered at twice the slot size (at least 256) and scaled down, so small
/// sizes are smooth; the detail follows the slot, not the render.
func renderSize(_ size: CGFloat) -> Int { min(2048, max(256, Int(size) * 2)) }

/// The tile with the macOS drop shadow, filled edge to edge with the scene.
func drawIcon(_ ctx: CGContext, size: CGFloat, variant: Variant) {
    let image = variant.render(Detail(pixels: size), renderSize(size))
    let k = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(tile)
    ctx.setFillColor(sumi)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

// MARK: Bitmaps

func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: Brand sheets and lockups

func text(_ string: String, font: NSFont, color: CGColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
}

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
func mincho(_ size: CGFloat) -> NSFont { NSFont(name: "HiraMinProN-W6", size: size) ?? sans(size, .semibold) }

/// Each size drawn natively, as the icon set ships it, so the sheet shows what the Dock shows.
func drawSizes(_ ctx: CGContext, variant: Variant, sizes: [CGFloat], x: CGFloat, y: CGFloat, gap: CGFloat, label: CGColor?) {
    var x = x
    let tallest = sizes.max() ?? 0
    for size in sizes {
        let icon = bitmap(width: Int(size), height: Int(size)) { drawIcon($0, size: size, variant: variant) }
        ctx.draw(icon.cgImage!, in: CGRect(x: x, y: y + (tallest - size) / 2, width: size, height: size))
        if let label {
            let t = text("\(Int(size))", font: mono(16), color: label)
            t.draw(at: CGPoint(x: x + (size - t.size().width) / 2, y: y - 34))
        }
        x += size + gap
    }
}

func drawSheet(_ ctx: CGContext, width: CGFloat, height: CGFloat, hero: Variant) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let side: CGFloat = 1120
    ctx.saveGState()
    ctx.translateBy(x: 80, y: (height - side) / 2)
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    drawIcon(ctx, size: 1024, variant: hero)
    ctx.restoreGState()

    let left: CGFloat = 1300
    text("Kekkai", font: sans(132, .semibold), color: sumi, kern: -2).draw(at: CGPoint(x: left, y: 1150))
    text("結界  ·  けっかい  ·  barrier", font: mincho(46), color: shuCG, kern: 5).draw(at: CGPoint(x: left + 6, y: 1078))
    let story = hero.story
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 10
    NSAttributedString(string: story, attributes: [.font: sans(28), .foregroundColor: NSColor(cgColor: sumi.copy(alpha: 0.72)!)!,
                                                   .paragraphStyle: para])
        .draw(in: CGRect(x: left, y: 800, width: 1020, height: 262))

    let swatches = hero.swatches
    for (i, s) in swatches.enumerated() {
        let x = left + CGFloat(i) * 250, y: CGFloat = 728
        ctx.setFillColor(rgb(s.1))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        text(s.0, font: sans(20, .medium), color: sumi).draw(at: CGPoint(x: x + 58, y: y + 22))
        text(String(format: "#%06X", s.1), font: mono(17), color: sumi.copy(alpha: 0.55)!).draw(at: CGPoint(x: x + 58, y: y))
    }

    for row in 0..<2 {
        let y: CGFloat = row == 0 ? 430 : 100
        let strip = CGRect(x: left - 30, y: y - 50, width: 1020, height: 320)
        ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setFillColor(row == 0 ? paper : sumi)
        ctx.fillPath()
        drawSizes(ctx, variant: hero, sizes: [256, 128, 64, 32, 16], x: left, y: y, gap: 56,
                  label: (row == 0 ? sumi : paper).copy(alpha: 0.5)!)
    }
}

/// The showreel: all five side by side, each with its Dock sizes on light and dark.
func drawAlternates(_ ctx: CGContext, width: CGFloat, height: CGFloat) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    text("Kekkai  ·  結界", font: sans(56, .semibold), color: sumi, kern: -0.5).draw(at: CGPoint(x: 90, y: height - 130))
    text("The chosen icon, and the three directions it beat. Same renderer, same window.",
         font: sans(24), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: 92, y: height - 178))
    let column = (width - 180) / CGFloat(variants.count)
    for (i, v) in variants.enumerated() {
        let x0 = 90 + CGFloat(i) * column, iconSide = column - 60
        ctx.saveGState()
        ctx.translateBy(x: x0, y: height - 250 - iconSide)
        ctx.scaleBy(x: iconSide / 1024, y: iconSide / 1024)
        drawIcon(ctx, size: 1024, variant: v)
        ctx.restoreGState()
        let top = height - 270 - iconSide
        let title = text(v.name + (i == 0 ? "  ·  chosen" : ""), font: sans(30, .semibold), color: i == 0 ? shuCG : sumi)
        title.draw(at: CGPoint(x: x0 + 20, y: top - 40))
        text(v.kanji, font: mincho(24), color: sumi.copy(alpha: 0.7)!, kern: 3).draw(at: CGPoint(x: x0 + 20, y: top - 78))
        text(v.line, font: sans(19), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: x0 + 20, y: top - 110))
        for row in 0..<2 {
            let y = top - 300 + CGFloat(1 - row) * 0 - CGFloat(row) * 170
            let strip = CGRect(x: x0 + 10, y: y - 20, width: iconSide - 20, height: 150)
            ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(row == 0 ? paper : sumi)
            ctx.fillPath()
            drawSizes(ctx, variant: v, sizes: [110, 64, 32, 16], x: x0 + 30, y: y, gap: 22, label: nil)
        }
    }
}

func drawLockup(_ ctx: CGContext, width: CGFloat, height: CGFloat, dark: Bool, variant: Variant) {
    let fg = dark ? paper : sumi
    ctx.setFillColor(dark ? sumi : paper)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let side = height * 0.78
    ctx.saveGState()
    ctx.translateBy(x: height * 0.11, y: height * 0.11)
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    drawIcon(ctx, size: 1024, variant: variant)
    ctx.restoreGState()
    let x = height * 0.11 + side + height * 0.04
    text("Kekkai", font: sans(height * 0.3, .semibold), color: fg, kern: -height * 0.006)
        .draw(at: CGPoint(x: x, y: height * 0.42))
    text("結界  ·  barrier", font: mincho(height * 0.1), color: fg.copy(alpha: 0.55)!, kern: height * 0.008)
        .draw(at: CGPoint(x: x + height * 0.012, y: height * 0.27))
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
guard let outPath = args.first, !outPath.hasPrefix("--") else {
    print("usage: make-icon <AppIcon.iconset|AppIcon.appiconset> [--variant sekimori|shimenawa|kikko|torii] [--brand <folder>]")
    exit(1)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let chosenID = option("--variant") ?? "sekimori"
guard let chosen = variants.first(where: { $0.id == chosenID }) else {
    print("unknown variant \(chosenID); one of: \(variants.map(\.id).joined(separator: ", "))")
    exit(1)
}
let outDir = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Slot { let size: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }
var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    try write(bitmap(width: pixels, height: pixels) { drawIcon($0, size: CGFloat(pixels), variant: chosen) },
              to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.size)x\(slot.size)", "scale": "\(slot.scale)x", "filename": name])
}
// iconutil wants only the PNGs; an asset catalogue wants Contents.json too.
if outDir.pathExtension == "appiconset" {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: outDir.appendingPathComponent("Contents.json"))
}
print("Wrote \(slots.count) \(chosen.id) icon sizes to \(outDir.path)")

if let brandPath = option("--brand") {
    let brand = URL(fileURLWithPath: brandPath)
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    for v in variants {
        try write(bitmap(width: 1024, height: 1024) { drawIcon($0, size: 1024, variant: v) },
                  to: brand.appendingPathComponent("kekkai-icon-\(v.id).png"))
        try write(bitmap(width: 2400, height: 1400) { drawSheet($0, width: 2400, height: 1400, hero: v) },
                  to: brand.appendingPathComponent("kekkai-sheet-\(v.id).png"))
    }
    try write(bitmap(width: 2800, height: 1460) { drawAlternates($0, width: 2800, height: 1460) },
              to: brand.appendingPathComponent("kekkai-options.png"))
    print("Wrote brand assets to \(brand.path)")
}

