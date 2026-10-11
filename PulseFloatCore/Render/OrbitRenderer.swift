import CoreGraphics
import Foundation

/// 「軌道」：頻譜從發光的行星地平線升起（參考 Pinterest 的地球邊緣光暈）。
/// 移植自 docs/design/concepts/concept-orbit.js：大氣隨低音變厚、行星經緯網格只在有聲音時轉動、
/// 衛星只在有聲音時繞行並從行星背後經過。沒有聲音時只剩靜止的地平線、刻度與網格。同一實例須序列使用。
public final class OrbitRenderer: SpectrumRenderer {
    private struct Geometry {
        var key = ""
        var yA = 0.0, R = 0.0, cx = 0.0, cy = 0.0, aF = 0.0, aL = 0.0, maxLen = 0.0, below = 0.0
        var xa = 0.0, xb = 0.0, core = 0.0, glow = 0.0, rb = 0.0, rt = 0.0
        var ex = 0.0, ey = 0.0, erx = 0.0, ery = 0.0, er = 0.0, ce = 0.0, se = 0.0, h0 = -1.0, h1 = -1.0
        var ca: [Double] = [], sa: [Double] = []
    }
    private var g = Geometry()
    private var lengths: [Double] = []
    private var rot = 0.0
    private var satPhase = 3.6
    private var satAlpha = 0.0
    private let textCache = ThemeKit.TextCache()
    private static let ink = RGB(red: 205, green: 240, blue: 255)
    private static let veil = RGB(red: 5, green: 12, blue: 30)

    public init() {}

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame,
                     look: VisualizerConfig.Look, options: RenderOptions) {
        let ctx = context
        ctx.clear(CGRect(origin: .zero, size: size))
        let w = Double(size.width), h = Double(size.height)
        guard w > 8, h > 8 else { return }
        let n = min(frame.values.count, frame.peaks.count)
        let small = options.isThumbnail
        let dt = options.dt.isFinite ? min(0.1, max(0, options.dt)) : 0
        let key = "\(w)x\(h)\(small)/\(n)"
        if g.key != key { build(key, w, h, small, n) }
        let palette = Palette(look.palette)
        func col(_ t: Double, _ k: Double = 0) -> RGB { k > 0 ? ThemeKit.lift(palette.color(at: t), k) : palette.color(at: t) }
        let bass = ThemeKit.clamp01(frame.bass)
        let half = Double.pi / 2
        let R = g.R, cx = g.cx, cy = g.cy, below = g.below
        let a0 = -half - g.aF, a1 = -half + g.aF

        var sum = 0.0
        var i = 0
        while i < n { let v = ThemeKit.clamp01(frame.values[i]); lengths[i] = v * g.maxLen; sum += v; i += 1 }
        let energy = n > 0 ? sum / Double(n) : 0
        let live = ThemeKit.clamp01(energy * 6)
        rot = (rot + dt * (0.25 * energy + 0.2 * bass)).truncatingRemainder(dividingBy: 1)
        satPhase = (satPhase + dt * live * (0.18 + 0.7 * bass)).truncatingRemainder(dividingBy: Double.pi * 2)
        satAlpha += (live - satAlpha) * (1 - exp(-dt / (live > satAlpha ? 0.3 : 0.6)))
        if satAlpha < 0.001 && live == 0 { satAlpha = 0 }

        // 1. night-side shadow under the limb
        ctx.saveGState()
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.addLine(to: CGPoint(x: w + 2, y: h + 2)); ctx.addLine(to: CGPoint(x: -2, y: h + 2)); ctx.closePath()
        ctx.clip()
        ctx.translateBy(x: cx, y: g.yA); ctx.scaleBy(x: 1, y: below / (w * 0.5))
        if let gr = CGGradient(colorsSpace: ThemeKit.sRGB, colors: [ThemeKit.color(Self.veil, 0.28), ThemeKit.color(Self.veil, 0.15), ThemeKit.color(Self.veil, 0)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(gr, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w * 0.5, options: [])
        }
        ctx.restoreGState()

        // 2. planet grid
        let gc = col(0.5, 0.35), gA = 0.24 + 0.12 * bass
        ctx.setLineWidth(small ? 0.5 : 0.7)
        let lat: [Double] = small ? [0.16, 0.42, 0.8] : [0.09, 0.22, 0.4, 0.63, 0.92]
        var j = 0
        while j < lat.count {
            let r = R - below * lat[j], la = gA * (1 - 0.85 * lat[j]), inner = g.aF * 0.55
            ctx.setStrokeColor(ThemeKit.color(gc, la))
            ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: -half - inner, endAngle: -half + inner, clockwise: false); ctx.strokePath()
            ctx.setStrokeColor(ThemeKit.color(gc, la * 0.4))
            ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: a0, endAngle: -half - inner, clockwise: false); ctx.strokePath()
            ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: -half + inner, endAngle: a1, clockwise: false); ctx.strokePath()
            j += 1
        }
        let dl = Double.pi / (small ? 9 : 14), kmax = Int((half / dl).rounded(.up)) + 1, rIn = R - below * 0.72
        var k = -kmax
        while k <= kmax {
            let lam = (Double(k) + rot) * dl
            k += 1
            if lam <= -half + 0.05 || lam >= half - 0.05 { continue }
            let pm = -half + g.aF * sin(lam), c = cos(pm), s = sin(pm)
            ctx.setStrokeColor(ThemeKit.color(gc, gA * 0.8 * cos(lam)))
            ctx.beginPath(); ctx.move(to: CGPoint(x: cx + c * (R - 1), y: cy + s * (R - 1))); ctx.addLine(to: CGPoint(x: cx + c * rIn, y: cy + s * rIn)); ctx.strokePath()
        }

        // 3. atmosphere lens (breathes with bass), rim light, limb line
        let th = h * (small ? 0.09 : 0.075) * (1 + 1.6 * bass)
        let X = R * sin(g.aL), yE = cy - R * cos(g.aL), top = g.yA - th
        let cy2 = (X * X + yE * yE - top * top) / (2 * (yE - top)), R2 = cy2 - top
        ctx.saveGState()
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: -half - g.aL, endAngle: -half + g.aL, clockwise: false)
        ctx.addArc(center: CGPoint(x: cx, y: cy2), radius: R2, startAngle: atan2(yE - cy2, X), endAngle: atan2(yE - cy2, -X), clockwise: true)
        ctx.closePath()
        ctx.clip()
        let ac = col(0.5, 0.15), aa = ThemeKit.clamp01(0.3 + 0.45 * bass)
        if let gr = CGGradient(colorsSpace: ThemeKit.sRGB, colors: [ThemeKit.color(ac, aa), ThemeKit.color(ac, aa * 0.55), ThemeKit.color(ac, aa * 0.16), ThemeKit.color(ac, 0)] as CFArray, locations: [0, 0.22, 0.6, 1]) {
            ctx.drawRadialGradient(gr, startCenter: CGPoint(x: cx, y: cy), startRadius: R, endCenter: CGPoint(x: cx, y: cy), endRadius: R + th, options: [])
        }
        ctx.restoreGState()
        let ti = h * (small ? 0.05 : 0.04) * (1 + bass)
        ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R - ti / 2, startAngle: a0, endAngle: a1, clockwise: false)
        ThemeKit.strokeCurrentPath(ctx, width: ti, colors: spanColors(col, ThemeKit.clamp01(0.12 + 0.22 * bass), 0),
                                   locations: spanLocations(w), from: 0, to: w)
        ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: a0, endAngle: a1, clockwise: false)
        let black = RGB(red: 0, green: 0, blue: 0)
        ThemeKit.strokeCurrentPath(ctx, width: small ? 2.6 : 3.4,
                                   colors: [ThemeKit.color(black, 0), ThemeKit.color(black, 0.22), ThemeKit.color(black, 0.22), ThemeKit.color(black, 0)],
                                   locations: [0, g.xa / w, g.xb / w, 1].map { CGFloat($0) }, from: 0, to: w)
        ctx.beginPath(); ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: a0, endAngle: a1, clockwise: false)
        ThemeKit.strokeCurrentPath(ctx, width: small ? 1 : 1.4, colors: spanColors(col, ThemeKit.clamp01(0.66 + 0.34 * bass), 0.2),
                                   locations: spanLocations(w), from: 0, to: w)

        // 4. tick scale along the horizon
        let major = max(4, Int((Double(n) / 8).rounded()))
        i = 0
        while i < n {
            ctx.setFillColor(ThemeKit.color(ThemeKit.lift(palette.color(at: n > 1 ? Double(i) / Double(n - 1) : 0), 0.3), 0.6))
            ThemeKit.dot(ctx, cx + g.ca[i] * g.rt, cy + g.sa[i] * g.rt, small ? 0.55 : (i % major == 0 ? 1.15 : 0.7))
            i += 1
        }

        // 5. light pillars: halo, tapered glow, core, reflection, heads
        let rb = g.rb, hc = g.core / 2, hgw = g.glow / 2
        ctx.beginPath()
        i = 0
        while i < n {
            let L = lengths[i]
            if L >= 0.75 { ThemeKit.addQuad(ctx, cx: cx, cy: cy, c: g.ca[i], s: g.sa[i], r0: rb - 0.5, h0: hc + 1.1, r1: rb + L + 1.1, h1: hc + 1.1) }
            i += 1
        }
        ctx.setFillColor(ThemeKit.color(black, 0.2)); ctx.fillPath()
        i = 0
        while i < n {
            let L = lengths[i]
            if L >= 0.75 {
                let c = palette.color(at: n > 1 ? Double(i) / Double(n - 1) : 0)
                ctx.setFillColor(ThemeKit.color(c, ThemeKit.clamp01(0.2 + 0.14 * bass)))
                ctx.beginPath(); ThemeKit.addQuad(ctx, cx: cx, cy: cy, c: g.ca[i], s: g.sa[i], r0: rb, h0: hgw, r1: rb + L + 1, h1: hc + 0.5); ctx.fillPath()
                ctx.setFillColor(ThemeKit.color(c, 0.95))
                ctx.beginPath(); ThemeKit.addQuad(ctx, cx: cx, cy: cy, c: g.ca[i], s: g.sa[i], r0: rb, h0: hc, r1: rb + L, h1: hc); ctx.fillPath()
                if !small {
                    let rl = min(L * 0.22, below * 0.45)
                    if rl >= 1.5 {
                        ctx.setFillColor(ThemeKit.color(c, 0.16))
                        ctx.beginPath(); ThemeKit.addQuad(ctx, cx: cx, cy: cy, c: g.ca[i], s: g.sa[i], r0: R - 2, h0: hc, r1: R - 2 - rl, h1: hc * 0.5); ctx.fillPath()
                    }
                    if L >= 6 {
                        ctx.setFillColor(ThemeKit.color(ThemeKit.lift(c, 0.5), 1))
                        ThemeKit.dot(ctx, cx + g.ca[i] * (rb + L), cy + g.sa[i] * (rb + L), max(1, g.core * 0.8))
                    }
                }
            }
            i += 1
        }

        // 6. peaks: floating dots with a hairline dark rim
        let gap = small ? 2.0 : 3.5, pr = small ? 0.9 : 1.45
        i = 0
        while i < n {
            let pv = ThemeKit.clamp01(frame.peaks[i])
            if pv >= 0.015 {
                let r = rb + pv * g.maxLen + gap, x = cx + g.ca[i] * r, y = cy + g.sa[i] * r
                ctx.setFillColor(ThemeKit.color(black, 0.2)); ThemeKit.dot(ctx, x, y, pr + 0.7)
                ctx.setFillColor(ThemeKit.color(ThemeKit.lift(palette.color(at: n > 1 ? Double(i) / Double(n - 1) : 0), 0.5), 1)); ThemeKit.dot(ctx, x, y, pr)
            }
            i += 1
        }

        // 7. satellite (only while there is sound; slips behind the planet)
        if !small && satAlpha > 0.01 { drawSatellite(ctx, col) }

        // 8. HUD text on the planet
        if !small && h >= 120 {
            let ty0 = h - 10, halfSpan = (g.xb - g.xa) * 0.31, tx0 = cx - halfSpan
            ThemeKit.text(ctx, "O R B I T", x: tx0 + 0.6, y: ty0 + 0.8, size: 9.5, color: ThemeKit.color(black, 0.25), cache: textCache)
            ThemeKit.text(ctx, "O R B I T", x: tx0, y: ty0, size: 9.5, color: ThemeKit.color(Self.ink, 0.46), cache: textCache)
            ctx.setFillColor(ThemeKit.color(col(0.5, 0.3), 0.28 + 0.62 * ThemeKit.clamp01(energy * 5)))
            ThemeKit.dot(ctx, tx0 - 8, ty0 - 3.4, 2)
            if w >= 360 {
                let formula = "r = a(1−e²) / (1 + e·cosθ)"
                ThemeKit.text(ctx, formula, x: cx + halfSpan + 0.6, y: ty0 + 0.8, size: 9, color: ThemeKit.color(black, 0.18), align: .right, cache: textCache)
                ThemeKit.text(ctx, formula, x: cx + halfSpan, y: ty0, size: 9, color: ThemeKit.color(Self.ink, 0.26), align: .right, cache: textCache)
            }
        }
    }

    private func spanColors(_ col: (Double, Double) -> RGB, _ alpha: Double, _ k: Double) -> [CGColor] {
        var colors = [ThemeKit.color(col(0, k), 0)]
        var j = 0
        while j <= 4 { colors.append(ThemeKit.color(col(Double(j) / 4, k), alpha)); j += 1 }
        colors.append(ThemeKit.color(col(1, k), 0))
        return colors
    }

    private func spanLocations(_ w: Double) -> [CGFloat] {
        let fa = g.xa / w, fb = g.xb / w
        var locations: [CGFloat] = [0]
        var j = 0
        while j <= 4 { locations.append(CGFloat(fa + (fb - fa) * Double(j) / 4)); j += 1 }
        locations.append(1)
        return locations
    }

    private func ellipsePoint(_ p: Double) -> (Double, Double) {
        let cp = cos(p), sp = sin(p)
        return (g.ex + g.erx * cp * g.ce - g.ery * sp * g.se, g.ey + g.erx * cp * g.se + g.ery * sp * g.ce)
    }

    private func addEllipseArc(_ ctx: CGContext, from a: Double, to b: Double) {
        ctx.saveGState()
        ctx.translateBy(x: g.ex, y: g.ey)
        ctx.rotate(by: g.er)
        ctx.scaleBy(x: g.erx, y: g.ery)
        ctx.addArc(center: .zero, radius: 1, startAngle: a, endAngle: b, clockwise: false)
        ctx.restoreGState()
    }

    private func drawSatellite(_ ctx: CGContext, _ col: (Double, Double) -> RGB) {
        let tau = Double.pi * 2
        let ph = (satPhase.truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau)
        let hasHide = g.h1 > g.h0
        ctx.setLineWidth(0.7)
        ctx.setStrokeColor(ThemeKit.color(Self.ink, 0.12 * satAlpha))
        ctx.beginPath()
        if hasHide { addEllipseArc(ctx, from: g.h1, to: g.h0 + tau) } else { addEllipseArc(ctx, from: 0, to: tau) }
        ctx.strokePath()
        guard !(hasHide && ph > g.h0 && ph < g.h1) else { return }
        var ta = ph - 0.36
        if hasHide && ph >= g.h1 && ta < g.h1 { ta = g.h1 }
        let tm = (ta + ph) / 2
        ctx.setLineCap(.round); ctx.setLineWidth(1.1)
        ctx.setStrokeColor(ThemeKit.color(Self.ink, 0.18 * satAlpha)); ctx.beginPath(); addEllipseArc(ctx, from: ta, to: tm); ctx.strokePath()
        ctx.setStrokeColor(ThemeKit.color(Self.ink, 0.5 * satAlpha)); ctx.beginPath(); addEllipseArc(ctx, from: tm, to: ph); ctx.strokePath()
        ctx.setLineCap(.butt)
        let p = ellipsePoint(ph)
        let vis = satAlpha * ThemeKit.clamp01((hypot(p.0 - g.cx, p.1 - g.cy) - g.R) / 8)
        guard vis > 0.01 else { return }
        let cp = cos(ph), sp = sin(ph)
        let tx = -g.erx * sp * g.ce - g.ery * cp * g.se, ty = -g.erx * sp * g.se + g.ery * cp * g.ce
        let tn = max(1e-9, hypot(tx, ty)), nx = -ty / tn, ny = tx / tn
        ctx.setFillColor(ThemeKit.color(RGB(red: 0, green: 0, blue: 0), 0.25 * vis)); ThemeKit.dot(ctx, p.0, p.1, 3)
        ctx.setLineWidth(1.3)
        ctx.setStrokeColor(ThemeKit.color(col(0.5, 0.4), 0.8 * vis))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: p.0 + nx * 2, y: p.1 + ny * 2)); ctx.addLine(to: CGPoint(x: p.0 + nx * 5, y: p.1 + ny * 5))
        ctx.move(to: CGPoint(x: p.0 - nx * 2, y: p.1 - ny * 2)); ctx.addLine(to: CGPoint(x: p.0 - nx * 5, y: p.1 - ny * 5))
        ctx.strokePath()
        ctx.setFillColor(ThemeKit.color(RGB(red: 234, green: 249, blue: 255), 0.95 * vis)); ThemeKit.dot(ctx, p.0, p.1, 1.5)
    }

    private func build(_ key: String, _ w: Double, _ h: Double, _ small: Bool, _ n: Int) {
        var geo = Geometry()
        geo.key = key
        geo.yA = h * (small ? 0.72 : 0.70)
        let d = w * 0.38, s = max(3, h * 0.16)
        geo.R = (d * d + s * s) / (2 * s)
        geo.cx = w / 2; geo.cy = geo.yA + geo.R
        let th = asin(min(1, d / geo.R))
        geo.aF = asin(min(1, (w / 2 + 6) / geo.R))
        geo.aL = asin(min(1, (d + w * 0.07) / geo.R))
        geo.maxLen = max(4, geo.yA - h * (small ? 0.08 : 0.07) - (small ? 3 : 7))
        geo.ca = Array(repeating: 0, count: n); geo.sa = geo.ca
        var i = 0
        while i < n {
            let p = -Double.pi / 2 + th * (2 * (Double(i) + 0.5) / Double(n) - 1)
            geo.ca[i] = cos(p); geo.sa[i] = sin(p)
            i += 1
        }
        let pitch = n > 0 ? (2 * th * geo.R) / Double(n) : 6
        geo.below = max(8, h - geo.yA)
        geo.xa = geo.cx - d; geo.xb = geo.cx + d
        geo.core = min(2, max(small ? 0.8 : 0.9, pitch * 0.26))
        geo.glow = min(8, max(2, pitch * 0.95))
        geo.rb = geo.R + (small ? 1.5 : 2.5)
        geo.rt = geo.R + (small ? 3 : 4.5)
        geo.ex = geo.cx; geo.ey = geo.yA - h * 0.1; geo.erx = w * 0.4; geo.ery = h * 0.24; geo.er = -0.07
        geo.ce = cos(geo.er); geo.se = sin(geo.er)
        g = geo
        // hidden stretch of the orbit behind the planet
        var inRun = false
        var k = 0
        while k <= 256 {
            let q = Double.pi * 2 * Double(k) / 256, pt = ellipsePoint(q)
            let hidden = hypot(pt.0 - g.cx, pt.1 - g.cy) < g.R + 1
            if hidden && !inRun { g.h0 = q; inRun = true }
            if !hidden && inRun { g.h1 = q; inRun = false }
            k += 1
        }
        if g.h1 < g.h0 { g.h0 = -1; g.h1 = -1 }
        lengths = Array(repeating: 0, count: n)
    }
}
