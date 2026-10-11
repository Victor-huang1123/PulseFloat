import CoreGraphics
import Foundation

/// 「星圖」：每個頻段是一顆星，沿著一條由左下升到右上的黃道分布（參考 Pinterest 的星空、公式與行星邊緣）。
/// 移植自 docs/design/concepts/concept-constellation.js：響亮的局部峰值連成星座、隨音樂重組；
/// 重低音從最亮的星 α 擴散出光環；α／β／γ 標記與頻率讀數；背景極淡的公式只在有聲音時漂移。
/// 沒有聲音時是一張靜止的淡淡星圖。同一實例須序列使用。
public final class ConstellationRenderer: SpectrumRenderer {
    private struct Layout {
        var key = ""
        var n = 0
        var padX = 0.0, use = 0.0
        var bx: [Double] = [], by: [Double] = [], ox: [Double] = [], oy: [Double] = []
        var spine: [CGPoint] = []
    }
    private struct Ring { var x: Double; var y: Double; var color: RGB; var age: Double; var strength: Double }

    private static let fragments: [(String, Double, Double, ThemeKit.Align)] = [
        ("Σ|X[k]|²", 0.045, 0.14, .left), ("20·log₁₀|X|", 0.34, 0.11, .left), ("f = k·fs/N", 0.47, 0.89, .left), ("∫|H(ω)|²dω", 0.955, 0.90, .right),
    ]
    private static let cyan = RGB(red: 127, green: 227, blue: 255)
    private static let white = RGB(red: 255, green: 255, blue: 255)
    private static let black = RGB(red: 0, green: 0, blue: 0)

    private var layout = Layout()
    private var x: [Double] = [], y: [Double] = [], v: [Double] = [], r: [Double] = [], prominence: [Double] = []
    private var target = -1, beta = -1, gamma = -1
    private var reticleX: Double?, reticleY = 0.0, reticleAlpha = 0.0
    private var phase = 0.0
    private var rings: [Ring] = []
    private var armed = true, low = 0.0, high = 0.0, cool = 0.0
    private var gradientKey = ""
    private var glowGradients: [CGGradient] = []
    private let textCache = ThemeKit.TextCache()

    public init() {}

    private static func lvl(_ value: Float) -> Double { let d = Double(value); return d > 0.02 ? (d < 1 ? (d - 0.02) / 0.98 : 1) : 0 }
    private static func smooth01(_ value: Double) -> Double { let t = ThemeKit.clamp01(value); return t * t * (3 - 2 * t) }
    private static func hash(_ i: Int, _ salt: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: i + 1) &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: salt + 7) &* 0x85EB_CA77
        h = (h ^ (h >> 15)) &* 0x2C1B_3C6D
        h = (h ^ (h >> 12)) &* 0x297A_2D39
        h ^= h >> 15
        return Double(h) / 4_294_967_296
    }
    private static func spineY(_ u: Double, _ h: Double) -> Double { h * (0.5 + 0.17 * sin(5.0265 * u + 0.7) + 0.05 * sin(14.451 * u + 2.1)) }
    private static func spineDY(_ u: Double, _ h: Double) -> Double { h * (0.17 * 5.0265 * cos(5.0265 * u + 0.7) + 0.05 * 14.451 * cos(14.451 * u + 2.1)) }

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame,
                     look: VisualizerConfig.Look, options: RenderOptions) {
        let ctx = context
        ctx.clear(CGRect(origin: .zero, size: size))
        let w = Double(size.width), h = Double(size.height)
        let n = min(frame.values.count, frame.peaks.count)
        guard w >= 8, h >= 8, n >= 2 else { return }
        let small = options.isThumbnail
        let dt = options.dt.isFinite ? min(0.1, max(0, options.dt)) : 0
        let bass = Self.lvl(frame.bass)
        let key = "\(n)|\(w)|\(h)|\(small)"
        if layout.key != key { build(key, n, w, h, small) }
        let palette = Palette(look.palette)
        if gradientKey != "\(key)|\(look.palette)" { buildGradients(palette, n, "\(key)|\(look.palette)") }
        func color(_ i: Int) -> RGB { palette.color(at: Double(i) / Double(n - 1)) }

        // per-star state
        let lift = h * (small ? 0.04 : 0.05)
        var sum = 0.0, hiSum = 0.0, hiCount = 0, alpha = 0, alphaV = -1.0
        let hi0 = Int(Double(n) * 0.75)
        var i = 0
        while i < n {
            let value = Self.lvl(frame.values[i])
            v[i] = value; sum += value
            if i >= hi0 { hiSum += value; hiCount += 1 }
            if value > alphaV { alphaV = value; alpha = i }
            i += 1
        }
        let window = n >= 48 ? 2 : 1, eIn = 1 - exp(-dt / 0.04), eOut = 1 - exp(-dt / 0.22)
        i = 0
        while i < n {
            let value = v[i]
            var isPeak = value > 0.25
            var j = max(0, i - window)
            while isPeak && j <= min(n - 1, i + window) { if j != i && v[j] > value { isPeak = false }; j += 1 }
            var pe = prominence[i] + ((isPeak ? 1 : 0) - prominence[i]) * (isPeak ? eIn : eOut)
            if pe < 0.004 { pe = 0 }
            prominence[i] = pe
            x[i] = layout.bx[i] + layout.ox[i] * value * lift
            y[i] = min(h - 4, max(4, layout.by[i] + layout.oy[i] * value * lift))
            r[i] = small ? 0.85 + 1.1 * value * value + 1.5 * pe * value : 1.2 + 1.5 * value * value + 2.3 * pe * value + 0.9 * pe * value * bass
            i += 1
        }
        let energy = sum / Double(n), hiE = hiCount > 0 ? hiSum / Double(hiCount) : 0
        if target >= 0 && target < n && v[target] > 0.1 && v[target] >= alphaV * 0.8 { alpha = target }
        target = alpha; alphaV = v[alpha]
        beta = -1; gamma = -1
        if !small { beta = pickOther(n, alpha, -1, beta); gamma = beta >= 0 ? pickOther(n, alpha, beta, gamma) : -1 }
        phase = (phase + dt * (0.35 * energy + 0.8 * bass)).truncatingRemainder(dividingBy: 16 * Double.pi)

        // bass onset → ring at α (hysteresis)
        cool = cool > dt ? cool - dt : 0
        if armed {
            if bass < low { low = bass }
            if bass > 0.22 && bass - low > 0.12 && cool == 0 {
                if rings.count >= 5 { rings.removeFirst() }
                rings.append(Ring(x: x[alpha], y: y[alpha], color: color(alpha), age: 0, strength: min(1, 0.35 + (bass - low) * 2)))
                armed = false; high = bass; cool = 0.15
            }
        } else {
            if bass > high { high = bass }
            if bass < high - 0.08 || bass < 0.04 { armed = true; low = bass }
        }
        var k = 0
        while k < rings.count { rings[k].age += dt; k += 1 }
        rings.removeAll { $0.age >= 1.05 }

        // constellation links: each candidate → nearest candidate (+ a second for loud pairs)
        var candidates: [Int] = []
        i = 0
        while i < n { if prominence[i] > 0.04 && v[i] > 0.2 { candidates.append(i) }; i += 1 }
        var links: [(Int, Int, Double)] = []
        let maxD = h * 0.42
        func addLink(_ a: Int, _ b: Int) {
            let lo = min(a, b), hi = max(a, b)
            if links.contains(where: { $0.0 == lo && $0.1 == hi }) { return }
            links.append((lo, hi, 0.95 * min(prominence[lo], prominence[hi]) * Self.smooth01((min(v[lo], v[hi]) - 0.2) / 0.35)))
        }
        var p = 0
        while p < candidates.count {
            let a = candidates[p]
            var j1 = -1, d1 = 1e9, j2 = -1, d2 = 1e9
            var q = 0
            while q < candidates.count {
                if q != p {
                    let b = candidates[q]
                    var dd = hypot(x[b] - x[a], y[b] - y[a])
                    if dd <= maxD {
                        dd /= (0.35 + 0.65 * prominence[b])
                        if dd < d1 { j2 = j1; d2 = d1; j1 = b; d1 = dd } else if dd < d2 { j2 = b; d2 = dd }
                    }
                }
                q += 1
            }
            if j1 >= 0 { addLink(a, j1) }
            if j2 >= 0 && v[a] > 0.5 && v[j2] > 0.5 && d2 < maxD * 0.8 { addLink(a, j2) }
            p += 1
        }

        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let rampColors = [0.0, 0.25, 0.5, 0.75, 1.0].map { ThemeKit.color(palette.color(at: $0), 1) }
        let rampLocations: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let x0 = CGFloat(layout.padX), x1 = CGFloat(layout.padX + layout.use)

        // 1. formula fragments (static in silence)
        if !small {
            let tcol = palette.color(at: 0.45), ta = 0.17 + 0.25 * bass
            var f = 0
            while f < Self.fragments.count {
                let frag = Self.fragments[f]
                let fx = frag.1 * w + sin(phase * 0.5 + Double(f) * 2.1) * 9
                let fy = frag.2 * h + sin(phase * 0.375 + Double(f) * 1.3) * 2.5 + 3.5
                ThemeKit.text(ctx, frag.0, x: CGFloat(fx + 0.7), y: CGFloat(fy + 0.7), size: 10, color: ThemeKit.color(Self.black, 0.12), align: frag.3, cache: textCache)
                ThemeKit.text(ctx, frag.0, x: CGFloat(fx), y: CGFloat(fy), size: 10, color: ThemeKit.color(tcol, ta), align: frag.3, cache: textCache)
                f += 1
            }
        }

        // 2. planet limb (bottom-right)
        let limbK = (small ? 0.3 : 0.28) + 0.42 * (0.55 * hiE + 0.45 * bass)
        let limbCenter = CGPoint(x: w + h * 0.05, y: h * 1.9), limbR = h * 1.35
        let limbStart = -Double.pi / 2 - 0.04, limbEnd = -Double.pi / 2 - 0.86
        let lc = palette.color(at: 0.3)
        let lx0 = CGFloat(w), ly0 = CGFloat(h * 1.9 - limbR)
        let lx1 = limbCenter.x + CGFloat(limbR * cos(limbEnd)), ly1 = limbCenter.y + CGFloat(limbR * sin(limbEnd))
        func strokeLimb(_ width: CGFloat, _ colors: [CGColor]) {
            ctx.saveGState()
            ctx.beginPath(); ctx.addArc(center: limbCenter, radius: limbR, startAngle: limbStart, endAngle: limbEnd, clockwise: true)
            ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
            if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: colors as CFArray, locations: [0, 0.2, 0.62, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: lx0, y: ly0), end: CGPoint(x: lx1, y: ly1), options: [])
            }
            ctx.restoreGState()
        }
        strokeLimb(small ? 2.2 : 2.8, [0, 0.18, 0.13, 0].map { ThemeKit.color(Self.black, $0) })
        if !small {
            strokeLimb(9, [0, 1, 0.7, 0].map { ThemeKit.color(lc, $0 * limbK * 0.14) })
            strokeLimb(4, [0, 1, 0.7, 0].map { ThemeKit.color(lc, $0 * limbK * 0.24) })
        }
        strokeLimb(small ? 1 : 1.2, [0, 1, 0.7, 0].map { ThemeKit.color(lc, $0 * limbK) })

        // 3. ecliptic (dotted) + decade ticks
        ctx.beginPath(); ctx.addLines(between: layout.spine)
        ctx.setLineDash(phase: 0, lengths: small ? [1, 3] : [1.5, 4.5])
        if let path = ctx.path {
            ctx.setStrokeColor(ThemeKit.color(Self.black, 0.13)); ctx.setLineWidth(small ? 2 : 2.4); ctx.strokePath()
            ctx.addPath(path)
            ctx.saveGState(); ctx.setAlpha(CGFloat(0.36 + 0.2 * bass))
            ctx.setLineWidth(1); ctx.replacePathWithStrokedPath(); ctx.clip()
            if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: rampColors as CFArray, locations: rampLocations) {
                ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
            }
            ctx.restoreGState()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 4. dark halos under every star
        ctx.beginPath()
        i = 0
        while i < n { let rh = r[i] + 1.4; ctx.addEllipse(in: CGRect(x: x[i] - rh, y: y[i] - rh, width: rh * 2, height: rh * 2)); i += 1 }
        ctx.setFillColor(ThemeKit.color(Self.black, 0.2)); ctx.fillPath()

        // 5. constellation lines
        let lineW: CGFloat = small ? 0.7 : 1
        for link in links where link.2 >= 0.01 {
            let a = link.0, b = link.1
            ctx.setStrokeColor(ThemeKit.color(Self.black, link.2 * 0.3)); ctx.setLineWidth(lineW + 1.8)
            ctx.beginPath(); ctx.move(to: CGPoint(x: x[a], y: y[a])); ctx.addLine(to: CGPoint(x: x[b], y: y[b])); ctx.strokePath()
            let mid = palette.color(at: ((x[a] + x[b]) / 2 - layout.padX) / layout.use)
            ctx.setStrokeColor(ThemeKit.color(mid, link.2)); ctx.setLineWidth(lineW)
            ctx.beginPath(); ctx.move(to: CGPoint(x: x[a], y: y[a])); ctx.addLine(to: CGPoint(x: x[b], y: y[b])); ctx.strokePath()
        }

        // 6. asterism α–β–γ (dashed)
        if !small && beta >= 0 && gamma >= 0 {
            let am = Self.smooth01((min(alphaV, v[beta], v[gamma]) - 0.4) / 0.3) * 0.32
            if am > 0.01 {
                let three = [alpha, beta, gamma].sorted { x[$0] < x[$1] }
                ctx.setLineDash(phase: 0, lengths: [2, 4])
                ctx.beginPath(); ctx.addLines(between: three.map { CGPoint(x: x[$0], y: y[$0]) })
                if let path = ctx.path {
                    ctx.setStrokeColor(ThemeKit.color(Self.black, am * 0.5)); ctx.setLineWidth(2.2); ctx.strokePath()
                    ctx.addPath(path); ctx.setStrokeColor(ThemeKit.color(Self.cyan, am)); ctx.setLineWidth(0.7); ctx.strokePath()
                }
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // 7. bass rings from α
        let ringR = h * (small ? 0.45 : 0.5)
        for ring in rings {
            let q = 1 - ring.age / 1.05
            let radius = 3 + ringR * (1 - q * q), ra = ring.strength * 0.55 * pow(q, 1.5), rlw = 0.5 + 1.3 * q
            guard ra >= 0.004 else { continue }
            let rect = CGRect(x: ring.x - radius, y: ring.y - radius, width: radius * 2, height: radius * 2)
            ctx.setStrokeColor(ThemeKit.color(Self.black, ra * 0.3)); ctx.setLineWidth(rlw + 1.6); ctx.strokeEllipse(in: rect)
            ctx.setStrokeColor(ThemeKit.color(SculptureStyleColors.mix(ring.color, Self.white, 0.35), ra)); ctx.setLineWidth(rlw); ctx.strokeEllipse(in: rect)
        }

        // 8. star glow (additive radial gradients)
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        let gk = small ? 4.0 : 8.0
        i = 0
        while i < n {
            let value = v[i], pe = prominence[i]
            let gI = value * value * 0.35 + pe * value * 0.7
            if gI >= 0.02 && i < glowGradients.count {
                let gr = r[i] * 2.6 + gk * value * (0.4 + 0.6 * pe) + 4 * bass * pe * value
                ctx.saveGState()
                ctx.setAlpha(CGFloat(min(1, gI * (1 + 0.3 * bass))))
                ctx.drawRadialGradient(glowGradients[i], startCenter: CGPoint(x: x[i], y: y[i]), startRadius: 0,
                                       endCenter: CGPoint(x: x[i], y: y[i]), endRadius: gr, options: [])
                ctx.restoreGState()
            }
            i += 1
        }
        ctx.restoreGState()

        // 9. star cores (+ diffraction spikes on loud stars)
        let fth = small ? 0.65 : 0.55
        i = 0
        while i < n {
            let value = v[i], pe = prominence[i], c = color(i)
            ctx.setFillColor(ThemeKit.color(SculptureStyleColors.mix(c, Self.white, 0.22 + (small ? 0.3 : 0.5) * value * (0.4 + 0.6 * pe)), 0.62 + 0.38 * min(1, value * 1.5)))
            ThemeKit.dot(ctx, x[i], y[i], r[i])
            if value > fth && pe > 0.3 {
                let fk = (value - fth) / (1 - fth) * pe, sl = r[i] + 1.5 + fk * (small ? 4 : 9) + 3 * bass * fk
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x[i] - sl, y: y[i])); ctx.addLine(to: CGPoint(x: x[i] + sl, y: y[i]))
                ctx.move(to: CGPoint(x: x[i], y: y[i] - sl)); ctx.addLine(to: CGPoint(x: x[i], y: y[i] + sl))
                ctx.setStrokeColor(ThemeKit.color(SculptureStyleColors.mix(c, Self.white, 0.7), 0.2 + 0.55 * fk)); ctx.setLineWidth(small ? 0.6 : 0.8); ctx.strokePath()
            }
            i += 1
        }

        // 10. peak twinkles
        if !small {
            ctx.setLineWidth(0.8)
            i = 0
            while i < n {
                let pv = Self.lvl(frame.peaks[i]), gap = pv - v[i]
                if gap >= 0.05 && pv >= 0.3 && prominence[i] >= 0.15 {
                    let tw = min(1, (gap - 0.05) * 6) * pv * (0.45 + 0.5 * prominence[i])
                    if tw >= 0.01 {
                        let off = pv * lift + 3 + gap * h * 0.09, ts = 1.6 + pv * 2.8
                        let tx = layout.bx[i] + layout.ox[i] * off, ty = min(h - 4, max(4, layout.by[i] + layout.oy[i] * off))
                        ctx.beginPath()
                        ctx.move(to: CGPoint(x: tx - ts, y: ty - ts)); ctx.addLine(to: CGPoint(x: tx + ts, y: ty + ts))
                        ctx.move(to: CGPoint(x: tx + ts, y: ty - ts)); ctx.addLine(to: CGPoint(x: tx - ts, y: ty + ts))
                        ctx.setStrokeColor(ThemeKit.color(SculptureStyleColors.mix(color(i), Self.white, 0.45), tw)); ctx.strokePath()
                    }
                }
                i += 1
            }
        }

        // 11. α core (one blurred highlight) + reticle + readout, β/γ designations
        if alphaV > 0.05 {
            let ka = Self.smooth01((alphaV - 0.05) / 0.4), c = color(alpha)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: CGFloat((small ? 4 : 10) + 10 * bass), color: ThemeKit.color(c, 0.9 * ka))
            ctx.setFillColor(ThemeKit.color(SculptureStyleColors.mix(c, Self.white, 0.7), 0.6 + 0.4 * alphaV))
            ThemeKit.dot(ctx, x[alpha], y[alpha], r[alpha] * 1.05)
            ctx.restoreGState()
        }
        guard !small else { return }
        let rk = Self.smooth01((alphaV - 0.18) / 0.35) * 0.8
        if reticleX == nil || reticleAlpha < 0.02 { reticleX = x[alpha]; reticleY = y[alpha] } else if let rx = reticleX {
            let e = 1 - exp(-dt / 0.06)
            reticleX = rx + (x[alpha] - rx) * e; reticleY += (y[alpha] - reticleY) * e
        }
        reticleAlpha = rk
        var labelBox = CGRect.null
        if rk > 0.01, let rx = reticleX {
            let ry = reticleY, rr0 = r[alpha] + 6 + 3 * bass
            ctx.beginPath()
            ctx.addEllipse(in: CGRect(x: rx - rr0, y: ry - rr0, width: rr0 * 2, height: rr0 * 2))
            var q = 0
            while q < 4 {
                let ang = Double(q) * Double.pi / 2, cx = cos(ang), sy = sin(ang)
                ctx.move(to: CGPoint(x: rx + cx * (rr0 + 1.5), y: ry + sy * (rr0 + 1.5))); ctx.addLine(to: CGPoint(x: rx + cx * (rr0 + 4.5), y: ry + sy * (rr0 + 4.5)))
                q += 1
            }
            if let path = ctx.path {
                ctx.setStrokeColor(ThemeKit.color(Self.black, rk * 0.3)); ctx.setLineWidth(2.4); ctx.strokePath()
                ctx.addPath(path); ctx.setStrokeColor(ThemeKit.color(Self.cyan, rk)); ctx.setLineWidth(0.8); ctx.strokePath()
            }
            let fc = 30 * pow(16000.0 / 30, (Double(alpha) + 0.5) / Double(n))
            let label = "α " + (fc < 1000 ? "\(Int(fc.rounded())) Hz" : String(format: fc < 9950 ? "%.1f kHz" : "%.0f kHz", fc / 1000))
            let tw = ThemeKit.textWidth(label, size: 9)
            var lx = rx + rr0 + 7, ly = ry - rr0 - 2
            let left = lx + tw > w - 4
            if left { lx = rx - rr0 - 7 }
            if ly < 7 { ly = ry + rr0 + 8 }
            ThemeKit.text(ctx, label, x: CGFloat(lx), y: CGFloat(ly + 3), size: 9, color: ThemeKit.color(Self.cyan, rk * 0.8),
                          align: left ? .right : .left, halo: ThemeKit.color(Self.black, rk * 0.32), cache: textCache)
            labelBox = CGRect(x: left ? lx - tw : lx, y: ly - 6, width: tw, height: 12)
        }
        var s = 0
        while s < 2 {
            let si = s == 0 ? beta : gamma
            s += 1
            guard si >= 0 else { continue }
            let ga = Self.smooth01((v[si] - 0.4) / 0.25) * 0.5
            guard ga >= 0.01 else { continue }
            let gx = x[si] + r[si] + 3.5
            var gy = y[si] - r[si] - 3.5
            if gy < 6 { gy = y[si] + r[si] + 6 }
            if labelBox.insetBy(dx: -2, dy: -2).intersects(CGRect(x: gx, y: gy - 5, width: 6, height: 10)) { continue }
            ThemeKit.text(ctx, si == beta ? "β" : "γ", x: CGFloat(gx), y: CGFloat(gy + 3), size: 9, color: ThemeKit.color(Self.cyan, ga),
                          halo: ThemeKit.color(Self.black, ga * 0.4), cache: textCache)
        }
    }

    private func pickOther(_ n: Int, _ a: Int, _ b: Int, _ previous: Int) -> Int {
        var best = -1, bestV = -1.0
        var i = 0
        while i < n {
            if abs(i - a) >= 4 && (b < 0 || abs(i - b) >= 4) && v[i] > bestV { bestV = v[i]; best = i }
            i += 1
        }
        if previous >= 0 && previous < n && previous != best && abs(previous - a) >= 4 && (b < 0 || abs(previous - b) >= 4)
            && v[previous] > 0.1 && v[previous] >= bestV * 0.85 { best = previous }
        return best
    }

    private func build(_ key: String, _ n: Int, _ w: Double, _ h: Double, _ small: Bool) {
        var l = Layout()
        l.key = key; l.n = n
        l.padX = w * 0.055; l.use = w - 2 * l.padX
        let pitch = l.use / Double(n), spread = h * (small ? 0.19 : 0.21)
        l.bx = Array(repeating: 0, count: n); l.by = l.bx; l.ox = l.bx; l.oy = l.bx
        var i = 0
        while i < n {
            let sx = l.padX + (Double(i) + 0.5) / Double(n) * l.use + (Self.hash(i, 1) - 0.5) * 0.85 * pitch
            let u = (sx - l.padX) / l.use
            let ys = Self.spineY(u, h), dyu = Self.spineDY(u, h)
            let len = max(1e-9, (l.use * l.use + dyu * dyu).squareRoot())
            let nx = -dyu / len, ny = l.use / len
            let d = (Self.hash(i, 2) + Self.hash(i, 3) - 1) * spread
            let s = d < 0 ? -1.0 : 1.0
            l.bx[i] = sx + nx * d; l.by[i] = ys + ny * d
            l.ox[i] = nx * s; l.oy[i] = ny * s
            i += 1
        }
        let m = small ? 24 : 48
        var k = 0
        while k <= m { let uu = -0.03 + 1.06 * Double(k) / Double(m); l.spine.append(CGPoint(x: l.padX + uu * l.use, y: Self.spineY(uu, h))); k += 1 }
        layout = l
        x = Array(repeating: 0, count: n); y = x; v = x; r = x; prominence = x
        target = -1; beta = -1; gamma = -1; reticleX = nil; reticleAlpha = 0
        gradientKey = ""
    }

    private func buildGradients(_ palette: Palette, _ n: Int, _ key: String) {
        gradientKey = key
        glowGradients = []
        var i = 0
        while i < n {
            let c = palette.color(at: Double(i) / Double(n - 1))
            if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: [ThemeKit.color(c, 0.9), ThemeKit.color(c, 0.3), ThemeKit.color(c, 0)] as CFArray, locations: [0, 0.28, 1]) {
                glowGradients.append(g)
            }
            i += 1
        }
    }
}
