#!/usr/bin/env swift
//
//  make-icon.swift — PulseFloat app icon + social cover generator
//
//  Run from the repo root:
//
//      swift docs/design/icon/make-icon.swift
//
//  Regenerates:
//      docs/design/icon/icon-1024.png             master icon (macOS Big Sur+ grid)
//      docs/design/icon/contact-sheet.png         1024…16 px on light + dark, small sizes also ×N nearest
//      docs/design/cover.png                      1280×640 GitHub social preview
//      PulseFloat/Resources/Assets.xcassets/Contents.json
//      PulseFloat/Resources/Assets.xcassets/AppIcon.appiconset/{Contents.json, icon_*.png}
//
//  Only AppKit / CoreGraphics / CoreText. Everything is drawn at 1024 px and resampled down
//  by repeated 2× high-quality halving. Slots ≥ 64 px come from the master drawing; the 16 and
//  32 px pixels come from optical-size variants drawn on a 1024/px grid (see PixelSpec) so bars,
//  gaps and the card edge land on whole pixels — 7 bars at 32 px, 4 bars at 16 px (7 + gaps
//  cannot fit in the ~13 px body).
//
//  Visual language (docs/design/prototype.html): deep-navy stage (#141826 → #0b0d14) with soft
//  purple / teal / rust glows, a frosted-glass floating card, and the "aurora" visualizer palette
//  #21e6c1 → #3a9bff → #a35cff. The amber UI accent (#ffb547) is intentionally not used: in the
//  menu bar an orange dot reads as "microphone in use", which is the wrong message for this app.
//

import AppKit
import CoreText

// MARK: - Paths

let fm = FileManager.default
let repo: URL = {
    // #filePath is whatever was passed to `swift`, resolved against the current directory.
    let script = URL(fileURLWithPath: #filePath).standardizedFileURL
    let root = script.deletingLastPathComponent()      // icon
        .deletingLastPathComponent()                    // design
        .deletingLastPathComponent()                    // docs
        .deletingLastPathComponent()                    // repo
    if fm.fileExists(atPath: root.appendingPathComponent("docs/design/prototype.html").path) { return root }
    return URL(fileURLWithPath: fm.currentDirectoryPath)
}()
let iconDir = repo.appendingPathComponent("docs/design/icon")
let catalogDir = repo.appendingPathComponent("PulseFloat/Resources/Assets.xcassets")
let appIconDir = catalogDir.appendingPathComponent("AppIcon.appiconset")

// MARK: - Colour helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xff) / 255
        g = CGFloat((hex >> 8) & 0xff) / 255
        b = CGFloat(hex & 0xff) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func mixed(_ o: RGB, _ t: CGFloat) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }
}

let white = RGB(0xffffff)
let black = RGB(0x000000)

// Visualizer palette "aurora" (prototype PALETTES.aurora).
let aurora = [RGB(0x21e6c1), RGB(0x3a9bff), RGB(0xa35cff)]
/// Same piecewise-linear lookup as the prototype's palAt(t).
func auroraAt(_ t: CGFloat) -> RGB {
    let x = min(1, max(0, t)) * CGFloat(aurora.count - 1)
    let i = min(aurora.count - 2, Int(x.rounded(.down)))
    return aurora[i].mixed(aurora[i + 1], x - CGFloat(i))
}

// Stage tokens (prototype .stage background).
let navyTop = RGB(0x141826)
let navyBottom = RGB(0x0b0d14)
let glowPurple = RGB(0x3b2a52)
let glowTeal = RGB(0x12404a)
let glowRust = RGB(0x4a2a22)

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Colour → transparent with a smooth (ease-out) fall-off instead of a linear cone.
func softGradient(_ c: RGB, _ a: CGFloat, fadeAt: CGFloat = 1) -> CGGradient {
    let n = 8
    var stops: [(CGFloat, CGColor)] = []
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let s = 1 - t
        stops.append((t * fadeAt, c.cg(a * s * s * (3 - 2 * s))))   // smoothstep
    }
    return gradient(stops)
}

// MARK: - Bitmap helpers

/// 8-bit sRGB premultiplied RGBA context. `flipped` gives a top-left origin (y grows downward).
func makeContext(_ w: Int, _ h: Int, flipped: Bool = true) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    if flipped {
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
    }
    return ctx
}

/// Draw an image upright into a top-left-origin (flipped) context.
func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect, quality: CGInterpolationQuality = .high) {
    ctx.saveGState()
    ctx.interpolationQuality = quality
    ctx.translateBy(x: r.minX, y: r.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    ctx.restoreGState()
}

func scaled(_ img: CGImage, _ w: Int, _ h: Int, quality: CGInterpolationQuality = .high) -> CGImage {
    let ctx = makeContext(w, h, flipped: false)
    ctx.interpolationQuality = quality
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// High-quality downsample: halve repeatedly (each step is a clean 2×2 average), then one final step.
func resampled(_ img: CGImage, _ size: Int) -> CGImage {
    var cur = img
    while cur.width / 2 >= size { cur = scaled(cur, cur.width / 2, cur.height / 2) }
    if cur.width != size { cur = scaled(cur, size, size * img.height / img.width) }
    return cur
}

/// Nearest-neighbour enlargement (for judging small-size legibility).
func pixelated(_ img: CGImage, factor: Int) -> CGImage {
    scaled(img, img.width * factor, img.height * factor, quality: .none)
}

/// Separable box blur, `passes` × (H then V) ≈ Gaussian. Works on premultiplied RGBA.
func boxBlurred(_ img: CGImage, radius: Int, passes: Int = 3) -> CGImage {
    let w = img.width, h = img.height
    let ctx = makeContext(w, h, flipped: false)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let bpr = ctx.bytesPerRow
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: bpr * h)
    var a = [Float](repeating: 0, count: w * h * 4)
    var b = a
    for y in 0..<h { for x in 0..<w { for c in 0..<4 { a[(y * w + x) * 4 + c] = Float(px[y * bpr + x * 4 + c]) } } }
    let norm = 1 / Float(2 * radius + 1)
    a.withUnsafeMutableBufferPointer { A in
        b.withUnsafeMutableBufferPointer { B in
            for _ in 0..<passes {
                // horizontal A → B
                for y in 0..<h {
                    for c in 0..<4 {
                        var acc: Float = 0
                        for k in -radius...radius { acc += A[(y * w + min(w - 1, max(0, k))) * 4 + c] }
                        for x in 0..<w {
                            B[(y * w + x) * 4 + c] = acc * norm
                            let add = min(w - 1, x + radius + 1), sub = max(0, x - radius)
                            acc += A[(y * w + add) * 4 + c] - A[(y * w + sub) * 4 + c]
                        }
                    }
                }
                // vertical B → A
                for x in 0..<w {
                    for c in 0..<4 {
                        var acc: Float = 0
                        for k in -radius...radius { acc += B[(min(h - 1, max(0, k)) * w + x) * 4 + c] }
                        for y in 0..<h {
                            A[(y * w + x) * 4 + c] = acc * norm
                            let add = min(h - 1, y + radius + 1), sub = max(0, y - radius)
                            acc += B[(add * w + x) * 4 + c] - B[(sub * w + x) * 4 + c]
                        }
                    }
                }
            }
        }
    }
    for y in 0..<h { for x in 0..<w { for c in 0..<4 {
        px[y * bpr + x * 4 + c] = UInt8(max(0, min(255, a[(y * w + x) * 4 + c].rounded())))
    } } }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed: \(url.path)") }
    do { try data.write(to: url) } catch { fatalError("write failed: \(url.path): \(error)") }
    print("  wrote \(url.path.replacingOccurrences(of: repo.path + "/", with: ""))  (\(img.width)×\(img.height))")
}

func writeText(_ s: String, _ url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try s.write(to: url, atomically: true, encoding: .utf8) } catch { fatalError("write failed: \(url.path)") }
    print("  wrote \(url.path.replacingOccurrences(of: repo.path + "/", with: ""))")
}

// MARK: - Geometry

/// Apple-style continuous-curvature ("squircle") rounded rectangle.
/// Bezier approximation of UIBezierPath's continuous corners; each corner blends over 1.528·r.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.52866483
    let rad = min(radius, min(r.width, r.height) / 2 / k)
    // (corner, direction of the edge arriving at it, direction of the edge leaving it) — clockwise in y-down space
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let p = CGMutablePath()
    for (i, corner) in corners.enumerated() {
        let (c, din, dout) = corner
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x - a * rad * din.dx + b * rad * dout.dx,
                    y: c.y - a * rad * din.dy + b * rad * dout.dy)
        }
        if i == 0 { p.move(to: pt(k, 0)) } else { p.addLine(to: pt(k, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0.02799650))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905899), control2: pt(0.16905899, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, k), control1: pt(0.02799650, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func ellipseGlow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, color: RGB, alpha: CGFloat, fadeAt: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: rx, y: ry)
    ctx.drawRadialGradient(softGradient(color, alpha, fadeAt: fadeAt), startCenter: .zero, startRadius: 0,
                           endCenter: .zero, endRadius: 1, options: [])
    ctx.restoreGState()
}

/// The prototype's stage background, mapped onto `r`.
func drawStage(_ ctx: CGContext, _ r: CGRect, glowAlpha: CGFloat = 1, rust: CGFloat = 0.9) {
    // linear-gradient(160deg, #141826, #0b0d14)
    let ang: CGFloat = 160 * .pi / 180
    let dir = CGVector(dx: sin(ang), dy: -cos(ang))
    let half = (abs(dir.dx) * r.width + abs(dir.dy) * r.height) / 2
    let c = CGPoint(x: r.midX, y: r.midY)
    ctx.drawLinearGradient(gradient([(0, navyTop.cg()), (1, navyBottom.cg())]),
                           start: CGPoint(x: c.x - dir.dx * half, y: c.y - dir.dy * half),
                           end: CGPoint(x: c.x + dir.dx * half, y: c.y + dir.dy * half),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // radial-gradient(60% 70% at 18% 85%, #3b2a52, transparent 60%) … etc.
    func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height) }
    ellipseGlow(ctx, center: at(0.18, 0.85), rx: 0.60 * r.width * 0.75, ry: 0.70 * r.height * 0.75, color: glowPurple, alpha: glowAlpha)
    ellipseGlow(ctx, center: at(0.85, 0.30), rx: 0.55 * r.width * 0.80, ry: 0.60 * r.height * 0.80, color: glowTeal, alpha: glowAlpha)
    ellipseGlow(ctx, center: at(0.55, 0.70), rx: 0.40 * r.width * 0.85, ry: 0.40 * r.height * 0.85, color: glowRust, alpha: glowAlpha * rust)
}

func drawStars(_ ctx: CGContext, _ stars: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
    for (x, y, rad, a) in stars {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: rad * 3, color: RGB(0xbfe6ff).cg(a * 0.8))
        ctx.setFillColor(RGB(0xeaf6ff).cg(a))
        ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        ctx.restoreGState()
    }
}

/// A planet seen from orbit: dark disc, rim light inside the limb, haze outside, and a thin
/// luminous limb line running cyan → blue (left → right).
struct Planet {
    var center: CGPoint
    var radius: CGFloat
    var limbWidth: CGFloat
    var haze: CGFloat       // outer atmosphere thickness
    var rim: CGFloat        // inner rim-light thickness
    var span: (CGFloat, CGFloat)   // x range for the limb colour ramp
    var hud: Bool = false   // faint parallels on the disc (HUD atmosphere only)

    func offset(dy: CGFloat) -> Planet { var p = self; p.center.y += dy; return p }
}

func drawPlanet(_ ctx: CGContext, _ p: Planet, intensity: CGFloat = 1) {
    let disc = CGRect(x: p.center.x - p.radius, y: p.center.y - p.radius, width: p.radius * 2, height: p.radius * 2)
    let limbL = RGB(0x21e6c1).mixed(RGB(0x5fe8ff), 0.45)   // aurora teal nudged toward cyan
    let limbR = RGB(0x3a9bff)

    // Outer atmosphere haze (annulus outside the limb).
    ctx.saveGState()
    ctx.drawRadialGradient(gradient([(0, limbR.mixed(limbL, 0.35).cg(0.40 * intensity)),
                                     (0.22, limbR.cg(0.18 * intensity)),
                                     (0.6, limbR.cg(0.05 * intensity)),
                                     (1, limbR.cg(0))]),
                           startCenter: p.center, startRadius: p.radius,
                           endCenter: p.center, endRadius: p.radius + p.haze, options: [])
    ctx.restoreGState()

    // Planet body.
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, RGB(0x101a2c).cg()), (0.45, RGB(0x0a0f1a).cg()), (1, RGB(0x06080e).cg())]),
                           start: CGPoint(x: p.center.x, y: p.center.y - p.radius),
                           end: CGPoint(x: p.center.x, y: p.center.y - p.radius + 420), options: [.drawsAfterEndLocation])
    // Faint parallels (HUD / circuit feel from the reference, kept very quiet).
    if p.hud {
        for k in 1...4 {
            let rr = p.radius - CGFloat(k) * 46 - CGFloat(k * k) * 6
            ctx.addEllipse(in: CGRect(x: p.center.x - rr, y: p.center.y - rr, width: rr * 2, height: rr * 2))
            ctx.setLineWidth(1.6)
            ctx.setStrokeColor(limbR.mixed(limbL, 0.3).cg(0.10 * intensity / CGFloat(k).squareRoot()))
            ctx.strokePath()
        }
    }
    // Rim light just inside the limb (a light-blue scattering band).
    ctx.drawRadialGradient(gradient([(0, limbR.cg(0)), (0.55, limbR.cg(0.06 * intensity)),
                                     (0.88, limbL.mixed(limbR, 0.5).cg(0.22 * intensity)), (1, limbL.cg(0.48 * intensity))]),
                           startCenter: p.center, startRadius: p.radius - p.rim,
                           endCenter: p.center, endRadius: p.radius, options: [])
    ctx.restoreGState()

    // Limb line: glow pass, colour pass, bright core.
    func strokeLimb(width: CGFloat, alpha: CGFloat, whiten: CGFloat, blur: CGFloat) {
        ctx.saveGState()
        if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: limbL.mixed(limbR, 0.5).cg(0.9 * intensity)) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addEllipse(in: disc)
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, limbL.mixed(white, whiten).cg(alpha)), (1, limbR.mixed(white, whiten).cg(alpha))]),
                               start: CGPoint(x: p.span.0, y: 0), end: CGPoint(x: p.span.1, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    strokeLimb(width: p.limbWidth, alpha: intensity, whiten: 0.0, blur: p.limbWidth * 4)
    strokeLimb(width: max(1, p.limbWidth * 0.35), alpha: 0.85 * intensity, whiten: 0.7, blur: 0)
}

// MARK: - Icon

let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)   // macOS Big Sur+ grid
let bodyRadius: CGFloat = 185
let bodyPath = continuousRect(bodyRect, radius: bodyRadius)

/// The master composition (used for every slot ≥ 64 px).
struct IconSpec {
    var card: CGRect
    var cardRadius: CGFloat
    var barInset: (x: CGFloat, top: CGFloat, bottom: CGFloat)
    var barFill: CGFloat            // bar width / pitch
    var heights: [CGFloat]
    var peaks: [CGFloat]
    var planet: Planet

    static let master = IconSpec(
        card: CGRect(x: 188, y: 262, width: 648, height: 450),
        cardRadius: 74,
        barInset: (62, 64, 72),
        barFill: 0.66,
        heights: [0.42, 0.70, 0.95, 0.62, 0.82, 0.54, 0.34],
        peaks:   [0.56, 0.80, 1.00, 0.80, 0.90, 0.70, 0.48],
        planet: Planet(center: CGPoint(x: 640, y: 1900), radius: 1230, limbWidth: 8, haze: 200, rim: 180,
                       span: (140, 900), hud: true))
}

func drawBodyShadow(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: black.cg(0.38))   // offset is in device space (y up)
    ctx.addPath(bodyPath)
    ctx.setFillColor(navyBottom.cg())
    ctx.fillPath()
    ctx.restoreGState()
}

func drawBodyBase(_ ctx: CGContext) {
    drawStage(ctx, bodyRect, glowAlpha: 1)
    // A slightly brighter crown so the body separates from dark Dock / desktop backgrounds.
    ellipseGlow(ctx, center: CGPoint(x: 512, y: 60), rx: 620, ry: 420, color: RGB(0x26304c), alpha: 0.55)
}

/// Inner hairline, top-lit — keeps the dark tile readable on dark backgrounds. Call with the body clip active.
func drawBodyRim(_ ctx: CGContext, width: CGFloat, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, white.cg(0.26 * alpha)), (0.4, white.cg(0.08 * alpha)), (1, white.cg(0.05 * alpha))]),
                           start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY), options: [])
    ctx.restoreGState()
}

func drawIconBackdrop(_ ctx: CGContext, _ spec: IconSpec) {
    drawBodyBase(ctx)
    drawStars(ctx, [
        (232, 196, 2.6, 0.60), (318, 150, 1.6, 0.40), (420, 214, 1.8, 0.35), (566, 168, 1.5, 0.35),
        (668, 202, 2.2, 0.50), (762, 150, 1.6, 0.40), (842, 218, 2.8, 0.60), (884, 330, 1.5, 0.30),
        (150, 340, 1.8, 0.40), (152, 560, 1.4, 0.30), (880, 520, 1.6, 0.30), (500, 128, 1.3, 0.30),
    ])
    drawPlanet(ctx, spec.planet)
}

func drawIcon(_ spec: IconSpec) -> CGImage {
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    // 1) Backdrop (clipped to the body) — also blurred for the frosted card.
    let bg = makeContext(Int(canvas), Int(canvas))
    bg.addPath(bodyPath)
    bg.clip()
    drawIconBackdrop(bg, spec)
    let backdrop = bg.makeImage()!
    let frosted = boxBlurred(resampled(backdrop, 256), radius: 7, passes: 3)

    let ctx = makeContext(Int(canvas), Int(canvas))

    // 2) Body with the soft macOS drop shadow in the transparent margin.
    drawBodyShadow(ctx)
    drawImage(ctx, backdrop, full)

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 3) Frosted-glass card.
    let card = spec.card
    let cardPath = continuousRect(card, radius: spec.cardRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 54, color: black.cg(0.55))
    ctx.addPath(cardPath)
    ctx.setFillColor(navyBottom.cg())
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    drawImage(ctx, frosted, full)
    ctx.setFillColor(RGB(0x0e1018).cg(0.28))     // the prototype's rgba(14,16,24,.42) card tint, lighter so the glass reads
    ctx.fill(card)
    let frost = RGB(0xd6e6ff)                    // cool frost instead of neutral grey
    ctx.drawLinearGradient(gradient([(0, frost.cg(0.12)), (0.45, frost.cg(0.055)), (1, frost.cg(0.035))]),
                           start: CGPoint(x: card.minX, y: card.minY), end: CGPoint(x: card.minX + 120, y: card.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Hairline edge, brighter on top like light catching glass.
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, white.cg(0.36)), (0.35, white.cg(0.15)), (1, white.cg(0.10))]),
                           start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.maxY), options: [])
    ctx.restoreGState()

    // 4) Spectrum bars + peak caps.
    let n = spec.heights.count
    let region = CGRect(x: card.minX + spec.barInset.x, y: card.minY + spec.barInset.top,
                        width: card.width - 2 * spec.barInset.x,
                        height: card.height - spec.barInset.top - spec.barInset.bottom)
    let pitch = region.width / CGFloat(n)
    let bw = pitch * spec.barFill
    let capH: CGFloat = 14
    let capGap: CGFloat = 12
    let base = region.maxY
    let maxH = region.height - capH - capGap
    let barRadius = bw * 0.24

    func barRect(_ i: Int) -> CGRect {
        let h = max(capH, spec.heights[i] * maxH)
        return CGRect(x: region.minX + CGFloat(i) * pitch + (pitch - bw) / 2, y: base - h, width: bw, height: h)
    }
    func barPath(_ i: Int) -> CGPath {
        CGPath(roundedRect: barRect(i), cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)
    }
    func colorAt(_ i: Int) -> RGB { auroraAt(CGFloat(i) / CGFloat(n - 1)) }

    // Bloom.
    for i in 0..<n {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46, color: colorAt(i).cg(0.55))
        ctx.addPath(barPath(i))
        ctx.setFillColor(colorAt(i).cg())
        ctx.fillPath()
        ctx.restoreGState()
    }
    // Bar body: continuous aurora ramp across the row, darkened toward the floor, lit at the top.
    let ramp = gradient((0...8).map { k in let t = CGFloat(k) / 8; return (t, auroraAt(t).cg()) })
    for i in 0..<n {
        let r = barRect(i)
        ctx.saveGState()
        ctx.addPath(barPath(i))
        ctx.clip()
        ctx.drawLinearGradient(ramp, start: CGPoint(x: region.minX + pitch * 0.5, y: 0),
                               end: CGPoint(x: region.maxX - pitch * 0.5, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.drawLinearGradient(gradient([(0, white.cg(0.22)), (0.18, white.cg(0.0)), (0.55, black.cg(0.0)), (1, black.cg(0.22))]),
                               start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: base), options: [])
        ctx.restoreGState()
    }
    // Peak caps.
    for i in 0..<n {
        let r = barRect(i)
        let y = base - spec.peaks[i] * maxH - capH - capGap
        let cap = CGRect(x: r.minX, y: min(y, r.minY - capGap - capH), width: bw, height: capH)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: colorAt(i).cg(0.8))
        ctx.addPath(CGPath(roundedRect: cap, cornerWidth: capH / 2, cornerHeight: capH / 2, transform: nil))
        ctx.setFillColor(colorAt(i).mixed(white, 0.35).cg())
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 5) Body rim highlight.
    drawBodyRim(ctx, width: 5)
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Small sizes (optical variants on the pixel grid)

/// 16 and 32 px can't resolve the master's 7 bars + gaps, so those slots get their own drawing:
/// the same tile, palette and horizon, with bars, gaps, caps and the card edge snapped to whole
/// target pixels (drawn at 1024 on a 1024/px grid, then halved down — every edge lands on a pixel).
struct PixelSpec {
    var px: Int
    var card: (x0: Int, y0: Int, x1: Int, y1: Int)?    // pixel rect, end-exclusive
    var cardEdge: Bool                                  // 1 px hairline inside the card rect
    var barX: Int                                       // first bar column
    var barW: Int
    var gap: Int
    var base: Int                                       // bars fill rows base-h ..< base
    var heights: [Int]
    var peaks: [Int]?                                   // cap sits in row base-peak-1
    var planetDY: CGFloat                               // shift of the master planet, in 1024 units
    var limbPx: CGFloat                                 // limb line width in target pixels
    var limbIntensity: CGFloat
}

func drawPixelIcon(_ s: PixelSpec) -> CGImage {
    let u = canvas / CGFloat(s.px)
    func R(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGRect {
        CGRect(x: CGFloat(x0) * u, y: CGFloat(y0) * u, width: CGFloat(x1 - x0) * u, height: CGFloat(y1 - y0) * u)
    }
    let ctx = makeContext(Int(canvas), Int(canvas))
    drawBodyShadow(ctx)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    drawBodyBase(ctx)
    var planet = IconSpec.master.planet.offset(dy: s.planetDY)
    planet.limbWidth = s.limbPx * u
    planet.hud = false
    drawPlanet(ctx, planet, intensity: s.limbIntensity)

    if let c = s.card {
        let r = R(c.x0, c.y0, c.x1, c.y1)
        let path = continuousRect(r, radius: 2.2 * u)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.6), blur: u * 1.2, color: black.cg(0.55))
        ctx.addPath(path)
        ctx.setFillColor(RGB(0x1c2334).cg())
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, RGB(0xd6e6ff).cg(0.10)), (1, RGB(0xd6e6ff).cg(0.03))]),
                               start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        if s.cardEdge {
            ctx.addPath(continuousRect(r.insetBy(dx: u / 2, dy: u / 2), radius: 1.7 * u))
            ctx.setLineWidth(u)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(gradient([(0, white.cg(0.40)), (1, white.cg(0.14))]),
                                   start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        }
        ctx.restoreGState()
    }

    let n = s.heights.count
    for i in 0..<n {
        let c = auroraAt(n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0)
        let x = s.barX + i * (s.barW + s.gap)
        let h = s.heights[i]
        ctx.setFillColor(c.cg())
        ctx.fill(R(x, s.base - h, x + s.barW, s.base))
        ctx.setFillColor(white.cg(0.18))       // lit top pixel row
        ctx.fill(R(x, s.base - h, x + s.barW, s.base - h + 1))
        if let p = s.peaks?[i], p > h {
            ctx.setFillColor(c.mixed(white, 0.4).cg())
            ctx.fill(R(x, s.base - p - 1, x + s.barW, s.base - p))
        }
    }
    drawBodyRim(ctx, width: u * 0.9, alpha: 0.8)
    ctx.restoreGState()
    return resampled(ctx.makeImage()!, s.px)
}

// 32 px (also the 16@2x slot): 7 bars × 2 px with 1 px gaps inside a framed glass card. Peak caps
// are dropped here — at actual size they read as a dotted line and thin the bars out.
let pixel32 = PixelSpec(px: 32, card: (4, 7, 28, 24), cardEdge: true, barX: 6, barW: 2, gap: 1, base: 22,
                        heights: [6, 9, 13, 8, 11, 7, 5], peaks: nil,
                        planetDY: 80, limbPx: 1.0, limbIntensity: 1.15)
// 16 px: the body is only ~13 px wide, so 7 bars + gaps cannot physically fit. Four 2 px bars with
// 1 px gaps (same rise-and-fall profile, same teal → purple ramp) standing on a quiet horizon.
let pixel16 = PixelSpec(px: 16, card: nil, cardEdge: false, barX: 3, barW: 2, gap: 1, base: 12,
                        heights: [4, 8, 6, 3], peaks: nil,
                        planetDY: 112, limbPx: 0.7, limbIntensity: 0.8)

// MARK: - Text

func systemFont(_ size: CGFloat, _ weight: NSFont.Weight, cjk: String = "PingFangTC-Regular") -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    let cascade = [CTFontDescriptorCreateWithNameAndSize(cjk as CFString, size)] as CFArray
    let attrs = [kCTFontCascadeListAttribute: cascade] as CFDictionary
    let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attrs)
    return CTFontCreateWithFontDescriptor(desc, size, nil)
}

func textLine(_ s: String, _ font: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
    let a = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ])
    return CTLineCreateWithAttributedString(a)
}

func width(of line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

/// Draw a line with its baseline at `y` in a flipped (top-left origin) context.
func draw(_ line: CTLine, _ ctx: CGContext, x: CGFloat, baseline y: CGFloat) {
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Contact sheet

func drawContactSheet(master: CGImage, sizes: [Int: CGImage]) -> CGImage {
    let shown = [1024, 256, 128, 64, 32, 16]
    let zoomed: [(Int, Int)] = [(64, 2), (32, 4), (16, 8)]
    let pad: CGFloat = 64, gap: CGFloat = 52, rowH: CGFloat = 1024 + 2 * pad + 40, header: CGFloat = 96
    let totalW = pad + shown.map { CGFloat($0) }.reduce(0, +) + gap * CGFloat(shown.count - 1) + 96
        + CGFloat(zoomed.count) * 128 + gap * CGFloat(zoomed.count - 1) + pad
    let W = Int(totalW), H = Int(header + 2 * rowH)
    let ctx = makeContext(W, H)

    let themes: [(String, RGB, RGB, RGB)] = [
        ("Light", RGB(0xf5f5f7), RGB(0x1d1d1f), RGB(0x6e6e73)),
        ("Dark", RGB(0x1d1d1f), RGB(0xf5f5f7), RGB(0x98989d)),
    ]
    ctx.setFillColor(RGB(0x2c2c2e).cg())
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    draw(textLine("PulseFloat — App Icon", systemFont(34, .bold), RGB(0xf5f5f7).cg()), ctx, x: pad, baseline: 60)
    draw(textLine("actual pixels, then ×N nearest-neighbour · 16 / 32 px are pixel-snapped optical variants",
                  systemFont(22, .regular), RGB(0x98989d).cg()), ctx, x: pad + 400, baseline: 58)

    for (row, theme) in themes.enumerated() {
        let (name, bgc, fg, muted) = theme
        let top = header + CGFloat(row) * rowH
        ctx.setFillColor(bgc.cg())
        ctx.fill(CGRect(x: 0, y: top, width: CGFloat(W), height: rowH))
        let mid = top + pad + 512
        var x = pad
        let labelY = top + pad + 1024 + 34
        let font = systemFont(20, .medium), small = systemFont(17, .regular)
        for s in shown {
            let img = s == 1024 ? master : sizes[s]!
            let side = CGFloat(s)
            drawImage(ctx, img, CGRect(x: x, y: mid - side / 2, width: side, height: side), quality: .none)
            let l = textLine(s == 1024 ? "\(name) · 1024 px" : "\(s)", font, (s == 1024 ? fg : muted).cg())
            draw(l, ctx, x: x + (side - width(of: l)) / 2, baseline: s == 1024 ? labelY : mid + side / 2 + 30)
            x += side + gap
        }
        x += 96 - gap
        // divider
        ctx.setFillColor(muted.cg(0.35))
        ctx.fill(CGRect(x: x - 48, y: mid - 150, width: 1, height: 300))
        for (s, f) in zoomed {
            let img = pixelated(sizes[s]!, factor: f)
            drawImage(ctx, img, CGRect(x: x, y: mid - 64, width: 128, height: 128), quality: .none)
            let l = textLine("\(s) px ×\(f)", small, muted.cg())
            draw(l, ctx, x: x + (128 - width(of: l)) / 2, baseline: mid + 64 + 30)
            x += 128 + gap
        }
    }
    return ctx.makeImage()!
}

// MARK: - Cover (1280 × 640)

func drawCover(icon: CGImage) -> CGImage {
    let W = 1280, H = 640
    let full = CGRect(x: 0, y: 0, width: W, height: H)
    let ctx = makeContext(W, H)
    drawStage(ctx, full, glowAlpha: 1, rust: 0.55)
    ellipseGlow(ctx, center: CGPoint(x: 640, y: -40), rx: 900, ry: 360, color: RGB(0x222a44), alpha: 0.6)
    drawStars(ctx, [
        (520, 92, 1.6, 0.45), (640, 64, 1.2, 0.30), (790, 120, 2.0, 0.50), (930, 84, 1.4, 0.35),
        (1060, 140, 1.8, 0.45), (1180, 96, 1.3, 0.30), (1222, 236, 1.5, 0.35), (60, 60, 1.4, 0.35),
        (300, 46, 1.2, 0.30), (1130, 300, 1.2, 0.25), (440, 600, 1.1, 0.2), (36, 300, 1.2, 0.25),
    ])
    // Wide planet limb rising toward the right, like the icon's horizon.
    drawPlanet(ctx, Planet(center: CGPoint(x: 940, y: 2770), radius: 2260, limbWidth: 3.2, haze: 120, rim: 90, span: (120, 1280)), intensity: 0.9)

    // Faint HUD ticks along the top-right — atmosphere only.
    ctx.saveGState()
    ctx.setStrokeColor(RGB(0x8fd3ff).cg(0.10))
    ctx.setLineWidth(1)
    for i in 0..<24 {
        let x = 820 + CGFloat(i) * 15
        ctx.move(to: CGPoint(x: x, y: 80))
        ctx.addLine(to: CGPoint(x: x, y: i % 4 == 0 ? 92 : 86))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Icon on the left: body 360 px, left edge on the 80 px safe margin.
    let bodySide: CGFloat = 360
    let iconSide = bodySide * canvas / bodyRect.width
    let iconScaled = resampled(icon, Int(iconSide.rounded()))
    let iconX = 80 - bodyRect.minX * iconSide / canvas
    let iconY = CGFloat(H) / 2 - iconSide / 2 - 4
    drawImage(ctx, iconScaled, CGRect(x: iconX, y: iconY, width: CGFloat(iconScaled.width), height: CGFloat(iconScaled.height)))

    // Wordmark + subtitle.
    let textX: CGFloat = 80 + bodySide + 64
    let maxW = CGFloat(W) - 80 - textX
    var wordSize: CGFloat = 112
    var word = textLine("PulseFloat", systemFont(wordSize, .bold), RGB(0xf2f4f8).cg(), kern: -1.5)
    while width(of: word) > maxW { wordSize -= 2; word = textLine("PulseFloat", systemFont(wordSize, .bold), RGB(0xf2f4f8).cg(), kern: -1.5) }
    var subSize: CGFloat = 28
    let subText = "macOS 選單列音訊視覺化 · Menu-bar audio visualizer"
    var sub = textLine(subText, systemFont(subSize, .regular), RGB(0xaab2c5).cg())
    while width(of: sub) > maxW { subSize -= 1; sub = textLine(subText, systemFont(subSize, .regular), RGB(0xaab2c5).cg()) }

    let wordBaseline: CGFloat = 276      // optical centre of wordmark + subtitle + strip ≈ icon centre
    draw(word, ctx, x: textX - 4, baseline: wordBaseline)
    draw(sub, ctx, x: textX, baseline: wordBaseline + 56)

    // Wide spectrum strip under the text: aurora ramp, NCS-style peak caps, a faint floor line.
    let strip = CGRect(x: textX, y: wordBaseline + 94, width: maxW, height: 66)
    let count = 48
    let sp = strip.width / CGFloat(count)
    let sbw = (sp * 0.6).rounded()
    let capH: CGFloat = 3, capGap: CGFloat = 4
    let stripLayer = makeContext(W, H)
    func bump(_ t: CGFloat, _ c: CGFloat, _ w: CGFloat) -> CGFloat { exp(-pow((t - c) / w, 2)) }
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(count - 1)
        // A frozen frame of music: kick/bass hump, vocal mids, hi-hat sparkle, gentle roll-off.
        let env = 0.16 + 0.78 * bump(t, 0.09, 0.10) + 0.52 * bump(t, 0.42, 0.16) + 0.30 * bump(t, 0.80, 0.09)
        let v = min(1, env * (0.82 + 0.18 * sin(CGFloat(i) * 2.1 + 0.4)))
        let h = max(4, (v * (strip.height - capH - capGap - 4)).rounded())
        let x = (strip.minX + CGFloat(i) * sp).rounded()
        let r = CGRect(x: x, y: strip.maxY - h, width: sbw, height: h)
        let c = auroraAt(t)
        stripLayer.saveGState()
        stripLayer.setShadow(offset: .zero, blur: 12, color: c.cg(0.45))
        stripLayer.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
        stripLayer.setFillColor(c.cg())
        stripLayer.fillPath()
        stripLayer.restoreGState()
        // Caps hug the bar; every so often one is still hanging after a drop (peak hold).
        let hang: CGFloat = [0, 0, 7, 0, 0, 3, 0, 0, 11, 0, 0, 0][i % 12]
        let capY = max(strip.minY, r.minY - capGap - capH - hang)
        stripLayer.setFillColor(c.mixed(white, 0.4).cg())
        stripLayer.fill(CGRect(x: x, y: capY, width: sbw, height: capH))
    }
    stripLayer.setFillColor(RGB(0x8fd3ff).cg(0.18))
    stripLayer.fill(CGRect(x: strip.minX, y: strip.maxY + 6, width: strip.width - (sp - sbw), height: 1))
    let stripImg = stripLayer.makeImage()!
    // Ease the strip in from the text column and let it soften (not vanish) toward the right edge.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawImage(ctx, stripImg, full)
    ctx.setBlendMode(.destinationIn)
    ctx.drawLinearGradient(gradient([(0, white.cg(0.92)), (0.7, white.cg(0.78)), (1, white.cg(0.42))]),
                           start: CGPoint(x: strip.minX, y: 0), end: CGPoint(x: strip.maxX, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Asset catalog

let appIconSlots: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func appIconFilename(_ size: Int, _ scale: Int) -> String {
    scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@\(scale)x.png"
}

func appIconContentsJSON() -> String {
    let images = appIconSlots.map { s in
        """
            {
              "filename" : "\(appIconFilename(s.size, s.scale))",
              "idiom" : "mac",
              "scale" : "\(s.scale)x",
              "size" : "\(s.size)x\(s.size)"
            }
        """
    }.joined(separator: ",\n")
    return """
    {
      "images" : [
    \(images)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

let catalogContentsJSON = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

// MARK: - Main

print("PulseFloat icon generator → \(repo.path)")
let master = drawIcon(.master)

// Pixel sizes needed. 16 and 32 px come from the optical-size variants.
var bySize: [Int: CGImage] = [:]
for px in [64, 128, 256, 512, 1024] { bySize[px] = resampled(master, px) }
bySize[32] = drawPixelIcon(pixel32)
bySize[16] = drawPixelIcon(pixel16)

writePNG(master, iconDir.appendingPathComponent("icon-1024.png"))
writeText(catalogContentsJSON, catalogDir.appendingPathComponent("Contents.json"))
for s in appIconSlots {
    writePNG(bySize[s.size * s.scale]!, appIconDir.appendingPathComponent(appIconFilename(s.size, s.scale)))
}
writeText(appIconContentsJSON(), appIconDir.appendingPathComponent("Contents.json"))
writePNG(drawContactSheet(master: master, sizes: bySize), iconDir.appendingPathComponent("contact-sheet.png"))
writePNG(drawCover(icon: master), repo.appendingPathComponent("docs/design/cover.png"))
print("done.")
