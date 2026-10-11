import CoreGraphics
import Foundation

/// 「儀表」：太空船上的精密儀表（參考 Pinterest 的 HUD／電路走線）。
/// 移植自 docs/design/concepts/concept-hud.js：四角括號延伸出 45° 轉折的電路走線，依頻段能量逐段點亮；
/// 頻譜是一條清楚的折線＋淡淡的漸層填色＋點狀峰值；底部對數頻率刻度、右上低音環與 dB 讀數。
/// 沒有聲音時是一副固定、淡淡的線框。同一實例須序列使用。
public final class HUDRenderer: SpectrumRenderer {
    private struct Trace { var points: [CGPoint]; var cumulative: [CGFloat]; var length: CGFloat; var group: Int }
    private struct Layout { var w, h, m, a, x0, x1, width, yT, yB, height: CGFloat; var compact, small: Bool }

    private static let groups: [(Double, Double)] = [(0, 0.18), (0.18, 0.45), (0.45, 0.72), (0.72, 1)]
    private static let major: [(Double, String)] = [(60, "60"), (250, "250"), (1000, "1k"), (4000, "4k"), (16000, "16k")]
    private static let minor: [Double] = [31.5, 125, 500, 2000, 8000]
    private static let title = "P U L S E F L O A T"
    private static let floorLevel = 0.004

    private var key = ""
    private var traces: [Trace] = []
    private var xs: [CGFloat] = [], ys: [CGFloat] = []
    private var majorX: [(CGFloat, String)] = [], minorX: [CGFloat] = []
    private var signal = 0.0, level = 0.0
    private var traceEnergy: [Double] = [0, 0, 0, 0]
    private var textAge = 1.0
    private var dbText = "−∞", hzText = "---"
    private let textCache = ThemeKit.TextCache()

    public init() {}

    private static func lvl(_ v: Float) -> Double { let d = Double(v); return d > floorLevel ? (d < 1 ? d : 1) : 0 }
    private static func follow(_ cur: Double, _ target: Double, _ dt: Double, _ up: Double, _ down: Double) -> Double {
        if target > cur { return up > 0 ? cur + (target - cur) * (1 - exp(-dt / up)) : target }
        let v = cur + (target - cur) * (1 - exp(-dt / down)) - 0.25 * dt
        return v > target ? v : target
    }

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame,
                     look: VisualizerConfig.Look, options: RenderOptions) {
        let ctx = context
        ctx.clear(CGRect(origin: .zero, size: size))
        let w = size.width, h = size.height
        guard w > 8, h > 8 else { return }
        let n = min(frame.values.count, frame.peaks.count)
        let small = options.isThumbnail
        let dt = options.dt.isFinite ? min(0.1, max(0, options.dt)) : 0
        let compact = small || w < 300 || h < 110
        let m: CGFloat = small ? 4 : (compact ? 5 : 6)
        let a: CGFloat = compact ? max(6, min(12, h * 0.1)) : max(10, min(20, h * 0.09))
        let x0: CGFloat = compact ? max(10, w * 0.07) : 28
        let yT: CGFloat = compact ? h * 0.16 : 32, yB: CGFloat = compact ? h * 0.84 : h - 30
        let L = Layout(w: w, h: h, m: m, a: a, x0: x0, x1: w - x0, width: w - 2 * x0, yT: yT, yB: yB, height: yB - yT, compact: compact, small: small)
        let palette = Palette(look.palette)
        let layoutKey = "\(look.palette)|\(w)x\(h)|\(n)|\(small)"
        if key != layoutKey { rebuild(L, n, layoutKey) }
        let white = RGB(red: 255, green: 255, blue: 255), black = RGB(red: 0, green: 0, blue: 0)
        let hud = SculptureStyleColors.mix(palette.color(at: 0.3), white, 0.65)
        let halo = ThemeKit.color(black, 0.25)
        let bass = Self.lvl(frame.bass)

        // analysis
        var sum = 0.0, sq = 0.0, mx = 0.0, mi = -1
        var i = 0
        while i < n {
            let v = Self.lvl(frame.values[i])
            ys[i] = yB - CGFloat(v) * L.height
            sum += v; sq += v * v
            if v > mx { mx = v; mi = i }
            i += 1
        }
        let mean = n > 0 ? sum / Double(n) : 0, rms = n > 0 ? (sq / Double(n)).squareRoot() : 0
        signal = Self.follow(signal, ThemeKit.clamp01(mean * 4), dt, 0.04, 0.35)
        level = Self.follow(level, rms, dt, 0.03, 0.30)
        var k = 0
        while k < 4 {
            var e = 0.0
            if n > 0 {
                let g0 = min(n - 1, Int(Self.groups[k].0 * Double(n)))
                let g1 = min(n, max(g0 + 1, Int(Self.groups[k].1 * Double(n))))
                var gs = 0.0, gm = 0.0
                var j = g0
                while j < g1 { let v = Self.lvl(frame.values[j]); gs += v; if v > gm { gm = v }; j += 1 }
                e = ThemeKit.clamp01((0.5 * gs / Double(g1 - g0) + 0.5 * gm) * 1.3)
            }
            traceEnergy[k] = Self.follow(traceEnergy[k], e, dt, 0.02, 0.22)
            k += 1
        }

        ctx.setLineJoin(.miter); ctx.setLineCap(.butt)
        func haloStroke(_ lw: CGFloat, _ color: CGColor) {
            guard let path = ctx.path else { return }
            ctx.setLineWidth(lw + 2); ctx.setStrokeColor(halo); ctx.strokePath()
            ctx.addPath(path); ctx.setLineWidth(lw); ctx.setStrokeColor(color); ctx.strokePath()
        }

        if !compact {
            ctx.setLineDash(phase: 0, lengths: [1, 4])
            ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: yT + 0.5)); ctx.addLine(to: CGPoint(x: L.x1, y: yT + 0.5))
            ctx.setLineWidth(1); ctx.setStrokeColor(ThemeKit.color(hud, 0.2)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // circuit traces (dim base) + end vias
        let viaR: CGFloat = compact ? 1.5 : 2
        ctx.beginPath()
        for trace in traces {
            ctx.move(to: trace.points[0])
            var p = 1
            while p < trace.points.count { ctx.addLine(to: trace.points[p]); p += 1 }
            if let end = trace.points.last { ctx.addEllipse(in: CGRect(x: end.x - viaR, y: end.y - viaR, width: viaR * 2, height: viaR * 2)) }
        }
        haloStroke(1, ThemeKit.color(hud, 0.28))

        // live: traces light up segment by segment
        let segments = compact ? 4 : 6, gap: CGFloat = compact ? 1.5 : 2
        let wide: CGFloat = compact ? 2.5 : 3.5, thin: CGFloat = compact ? 1.1 : 1.3
        for trace in traces {
            let en = traceEnergy[trace.group]
            guard en > 0 else { continue }
            let seg = trace.length / CGFloat(segments), lit = en * Double(segments)
            let nFull = min(segments, Int(lit)), frac = nFull < segments ? lit - Double(nFull) : 0
            let c = palette.color(at: (Self.groups[trace.group].0 + Self.groups[trace.group].1) / 2)
            if nFull > 0 {
                ctx.beginPath()
                var s = 0
                while s < nFull { addSubPath(ctx, trace, CGFloat(s) * seg + (s > 0 ? gap / 2 : 0), CGFloat(s + 1) * seg - gap / 2); s += 1 }
                if let path = ctx.path {
                    ctx.setLineWidth(wide); ctx.setStrokeColor(ThemeKit.color(c, 0.22)); ctx.strokePath()
                    ctx.addPath(path); ctx.setLineWidth(thin); ctx.setStrokeColor(ThemeKit.color(c, 0.95)); ctx.strokePath()
                }
            }
            if frac > 0.02 {
                ctx.beginPath()
                addSubPath(ctx, trace, CGFloat(nFull) * seg + (nFull > 0 ? gap / 2 : 0), CGFloat(nFull + 1) * seg - gap / 2)
                if let path = ctx.path {
                    ctx.setLineWidth(wide); ctx.setStrokeColor(ThemeKit.color(c, 0.22 * frac)); ctx.strokePath()
                    ctx.addPath(path); ctx.setLineWidth(thin); ctx.setStrokeColor(ThemeKit.color(c, 0.95 * frac)); ctx.strokePath()
                }
            }
            let via = nFull >= segments ? 1 : (nFull == segments - 1 ? frac : 0)
            if via > 0.02, let end = trace.points.last {
                ctx.setFillColor(ThemeKit.color(c, 0.95 * via)); ThemeKit.dot(ctx, end.x, end.y, viaR + 0.6)
            }
        }

        // corner brackets (pinwheel)
        ctx.setLineCap(.square)
        ctx.beginPath()
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(m, m, 1, 1), (w - m, m, -1, 1), (w - m, h - m, -1, -1), (m, h - m, 1, -1)]
        for c in corners {
            ctx.move(to: CGPoint(x: c.0 + c.2 * a, y: c.1)); ctx.addLine(to: CGPoint(x: c.0, y: c.1)); ctx.addLine(to: CGPoint(x: c.0, y: c.1 + c.3 * a))
        }
        if !compact {
            ctx.move(to: CGPoint(x: w - m, y: m + a + 3)); ctx.addLine(to: CGPoint(x: w - m, y: m + a + 6))
            ctx.move(to: CGPoint(x: w - m - a - 3, y: h - m)); ctx.addLine(to: CGPoint(x: w - m - a - 6, y: h - m))
            ctx.move(to: CGPoint(x: m, y: h - m - a - 3)); ctx.addLine(to: CGPoint(x: m, y: h - m - a - 6))
        }
        haloStroke(compact ? 1 : 1.25, ThemeKit.color(hud, 0.78))

        // baseline, frequency ticks, level scale
        ctx.setLineCap(.butt)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x0 - 3, y: yB)); ctx.addLine(to: CGPoint(x: L.x1 + 3, y: yB))
        let tl: CGFloat = compact ? 2.5 : 4
        for tick in majorX { ctx.move(to: CGPoint(x: tick.0, y: yB)); ctx.addLine(to: CGPoint(x: tick.0, y: yB + tl)) }
        if !compact {
            for x in minorX { ctx.move(to: CGPoint(x: x, y: yB)); ctx.addLine(to: CGPoint(x: x, y: yB + 2)) }
            var q = 1
            while q <= 4 {
                let yy = yB - L.height * CGFloat(q) / 4, len: CGFloat = q == 4 ? 5 : (q == 2 ? 4 : 2.5)
                ctx.move(to: CGPoint(x: x0 - 3, y: yy)); ctx.addLine(to: CGPoint(x: x0 - 3 - len, y: yy))
                q += 1
            }
        }
        haloStroke(1, ThemeKit.color(hud, 0.45))

        // spectrum: faint fill, crisp polyline, dotted peaks
        if n > 0 {
            let stops = [0.0, 0.25, 0.5, 0.75, 1.0].map { palette.color(at: $0) }
            if mx > 0 {
                ctx.saveGState()
                ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: yB)); ctx.addLine(to: CGPoint(x: x0, y: ys[0]))
                i = 0
                while i < n { ctx.addLine(to: CGPoint(x: xs[i], y: ys[i])); i += 1 }
                ctx.addLine(to: CGPoint(x: L.x1, y: ys[n - 1])); ctx.addLine(to: CGPoint(x: L.x1, y: yB)); ctx.closePath()
                ctx.clip()
                if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: stops.map { ThemeKit.color($0, small ? 0.16 : 0.12) } as CFArray, locations: [0, 0.25, 0.5, 0.75, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: L.x1, y: 0), options: [])
                }
                ctx.restoreGState()
            }
            ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: ys[0]))
            i = 0
            while i < n { ctx.addLine(to: CGPoint(x: xs[i], y: ys[i])); i += 1 }
            ctx.addLine(to: CGPoint(x: L.x1, y: ys[n - 1]))
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            let lw: CGFloat = small ? 1.1 : 1.6
            if let line = ctx.path {
                let strokeColors = stops.map { ThemeKit.color($0, 1) }
                if !small && signal > 0.02 {
                    ctx.saveGState(); ctx.setAlpha(CGFloat(signal * (0.13 + 0.14 * bass)))
                    ThemeKit.strokeCurrentPath(ctx, width: lw + 4 + 4 * CGFloat(bass), colors: strokeColors, locations: [0, 0.25, 0.5, 0.75, 1], from: x0, to: L.x1)
                    ctx.restoreGState()
                    ctx.addPath(line)
                }
                ctx.setLineWidth(lw + 2); ctx.setStrokeColor(halo); ctx.strokePath()
                ctx.addPath(line)
                ctx.saveGState(); ctx.setAlpha(CGFloat(0.5 + 0.5 * signal))
                ThemeKit.strokeCurrentPath(ctx, width: lw, colors: strokeColors, locations: [0, 0.25, 0.5, 0.75, 1], from: x0, to: L.x1)
                ctx.restoreGState()
            }
            let pitch = L.width / CGFloat(n), dw = max(1.2, min(3.5, pitch * 0.55)), dh: CGFloat = small ? 1 : 1.5
            ctx.saveGState()
            ctx.beginPath()
            var dots = 0
            i = 0
            while i < n {
                let pv = Self.lvl(frame.peaks[i])
                if pv >= 0.015 { ctx.addRect(CGRect(x: xs[i] - dw / 2, y: yB - CGFloat(pv) * L.height - dh - 1.5, width: dw, height: dh)); dots += 1 }
                i += 1
            }
            if dots > 0 {
                ctx.clip()
                let dotColors = stops.map { ThemeKit.color(SculptureStyleColors.mix($0, white, 0.25), 0.95) }
                if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: dotColors as CFArray, locations: [0, 0.25, 0.5, 0.75, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: L.x1, y: 0), options: [])
                }
            }
            ctx.restoreGState()
        }
        guard !compact else { return }

        // bass ring (inside the top-right bracket)
        let rcx = w - m - 16, rcy = m + 16, rr: CGFloat = 6
        ctx.setLineCap(.butt); ctx.setLineJoin(.miter)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(x: rcx - rr, y: rcy - rr, width: rr * 2, height: rr * 2))
        var q = 0
        while q < 4 {
            let ca = cos(Double(q) * Double.pi / 2), sa = sin(Double(q) * Double.pi / 2)
            ctx.move(to: CGPoint(x: rcx + ca * (rr + 2), y: rcy + sa * (rr + 2))); ctx.addLine(to: CGPoint(x: rcx + ca * (rr + 4), y: rcy + sa * (rr + 4)))
            q += 1
        }
        haloStroke(1, ThemeKit.color(hud, 0.42))
        let bassCol = palette.color(at: 0.06)
        if bass > 0 {
            ctx.beginPath(); ctx.addArc(center: CGPoint(x: rcx, y: rcy), radius: rr, startAngle: -Double.pi / 2, endAngle: -Double.pi / 2 + bass * Double.pi * 2, clockwise: false)
            ctx.setLineCap(.round); ctx.setLineWidth(2); ctx.setStrokeColor(ThemeKit.color(bassCol, 0.95)); ctx.strokePath()
        }
        ctx.setFillColor(bass > 0 ? ThemeKit.color(bassCol, 0.4 + 0.6 * bass) : ThemeKit.color(hud, 0.35))
        ThemeKit.dot(ctx, rcx, rcy, 1 + 2.2 * bass)

        // text (readout refreshes at 10 Hz)
        textAge += dt
        if textAge >= 0.1 || key != layoutKey {
            textAge = 0
            let db = level > 0.002 ? 20 * log10(level) : -Double.infinity
            dbText = db.isFinite ? (db > -0.05 ? "0.0" : "−" + String(format: "%.1f", -db)) : "−∞"
            if mi >= 0 && mx >= 0.06 {
                let fc = 30 * pow(16000.0 / 30, (Double(mi) + 0.5) / Double(n))
                hzText = fc < 1000 ? "\(Int(fc.rounded()))Hz" : String(format: fc < 9950 ? "%.1fkHz" : "%.0fkHz", fc / 1000)
            } else { hzText = "---" }
        }
        let textHalo = ThemeKit.color(black, 0.3)
        let tx = m + a + 6
        let titleW = ThemeKit.text(ctx, Self.title, x: tx, y: m + 3.5, size: 9, color: ThemeKit.color(hud, 0.7), halo: textHalo, cache: textCache)
        let dx = tx + titleW + 7
        ctx.setLineWidth(1); ctx.setStrokeColor(ThemeKit.color(hud, 0.5))
        ctx.strokeEllipse(in: CGRect(x: dx - 2, y: m - 2, width: 4, height: 4))
        if signal > 0.02 { ctx.setFillColor(ThemeKit.color(palette.color(at: 0), signal)); ThemeKit.dot(ctx, dx, m, 2) }
        let readout = (w >= 420 ? "PK " + String(repeating: " ", count: max(0, 6 - hzText.count)) + hzText + "   " : "")
            + "LVL " + String(repeating: " ", count: max(0, 5 - dbText.count)) + dbText + " dB"
        ThemeKit.text(ctx, readout, x: rcx - rr - 7, y: rcy + 3, size: 9, color: ThemeKit.color(hud, 0.68), align: .right, halo: textHalo, cache: textCache)
        for tick in majorX {
            ThemeKit.text(ctx, tick.1, x: tick.0, y: yB + 13, size: 9, color: ThemeKit.color(hud, 0.58), align: .center, halo: textHalo, cache: textCache)
        }
    }

    private func addSubPath(_ ctx: CGContext, _ trace: Trace, _ s0: CGFloat, _ s1: CGFloat) {
        var started = false
        var k = 0
        while k < trace.points.count - 1 {
            let a0 = trace.cumulative[k], a1 = trace.cumulative[k + 1], len = a1 - a0
            k += 1
            if a1 <= s0 || !(len > 0) { continue }
            if a0 >= s1 { break }
            let u0 = s0 > a0 ? (s0 - a0) / len : 0, u1 = s1 < a1 ? (s1 - a0) / len : 1
            let p = trace.points[k - 1], q = trace.points[k]
            let dx = q.x - p.x, dy = q.y - p.y
            if !started { ctx.move(to: CGPoint(x: p.x + dx * u0, y: p.y + dy * u0)); started = true }
            ctx.addLine(to: CGPoint(x: p.x + dx * u1, y: p.y + dy * u1))
        }
    }

    private func rebuild(_ L: Layout, _ n: Int, _ newKey: String) {
        key = newKey
        let fMin = 30.0, fMax = 16000.0, lf = log(fMax / fMin)
        func xOf(_ f: Double) -> CGFloat { L.x0 + CGFloat(log(f / fMin) / lf) * L.width }
        xs = Array(repeating: 0, count: n); ys = xs
        var i = 0
        while i < n { xs[i] = L.x0 + (CGFloat(i) + 0.5) / CGFloat(n) * L.width; i += 1 }
        majorX = Self.major.filter { $0.0 >= fMin * 0.98 && $0.0 <= fMax * 1.02 }.map { (min(L.x1, max(L.x0, xOf($0.0))), $0.1) }
        minorX = Self.minor.filter { $0 > fMin && $0 < fMax }.map { xOf($0) }
        let titleEnd = L.compact ? 0 : L.m + L.a + 6 + ThemeKit.textWidth(Self.title, size: 9) + 10
        traces = buildTraces(L, titleEnd: titleEnd)
    }

    private func buildTraces(_ L: Layout, titleEnd: CGFloat) -> [Trace] {
        let w = L.w, h = L.h, m = L.m, a = L.a, j: CGFloat = L.compact ? 4 : 6
        func trace(_ pts: [CGPoint], _ g: Int) -> Trace {
            var cum: [CGFloat] = [0], total: CGFloat = 0
            var i = 1
            while i < pts.count { total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y); cum.append(total); i += 1 }
            return Trace(points: pts, cumulative: cum, length: total, group: g)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        if L.compact {
            return [
                trace([p(m, m + a), p(m, h * 0.42), p(m + j, h * 0.42 + j), p(m + j, h * 0.68)], 0),
                trace([p(w - m, h - m - a), p(w - m, h * 0.58), p(w - m - j, h * 0.58 - j), p(w - m - j, h * 0.32)], 3),
            ]
        }
        let topJog = w * 0.62, topEnd = min(topJog - j - 12, max(w * 0.42, titleEnd + 16))
        return [
            trace([p(m, m + a), p(m, h * 0.40), p(m + j, h * 0.40 + j), p(m + j, h * 0.66)], 0),
            trace([p(m + a, h - m), p(w * 0.25, h - m), p(w * 0.25 + j, h - m - j), p(w * 0.44, h - m - j)], 1),
            trace([p(w - m - a, m), p(topJog, m), p(topJog - j, m + j), p(topEnd, m + j)], 2),
            trace([p(w - m, h - m - a), p(w - m, h * 0.60), p(w - m - j, h * 0.60 - j), p(w - m - j, h * 0.34)], 3),
        ]
    }
}
