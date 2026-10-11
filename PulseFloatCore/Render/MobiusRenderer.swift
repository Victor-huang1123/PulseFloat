import CoreGraphics
import Foundation

/// 「無限」：數百片鰭片組成的 ∞ 雕塑（萊茵生命風格），以透視投影＋深度排序＋雙面光照畫成立體感。
/// `analysis == true` 時是「解析 ANALYSIS OS」：加上隨重低音切換的鏡頭、區段標註、標題、拍點與中英字幕。
/// 頻率沿緞帶連續且左右對稱：兩個交叉點是中頻、左圈最外側最低頻、右圈最外側最高頻（接環處無斷層）。
/// 沒有聲音時不擺動、沒有脈衝、鏡頭回到正面全景後完全靜止。同一實例須序列使用。
public final class MobiusRenderer: SpectrumRenderer {
    /// analysis = true 時是「解析」主題。
    public let analysis: Bool

    // geometry (model space), rebuilt when the fin count changes
    private var finCount = 0
    private var px: [Double] = [], py: [Double] = [], pz: [Double] = []
    private var wx: [Double] = [], wy: [Double] = [], wz: [Double] = []
    private var nx: [Double] = [], ny: [Double] = [], nz: [Double] = []
    private var finU: [Double] = []
    // per-frame scratch
    private var sx0: [CGFloat] = [], sy0: [CGFloat] = [], sx1: [CGFloat] = [], sy1: [CGFloat] = []
    private var depth: [Double] = [], shade: [Double] = [], glow: [Double] = [], posF: [Double] = [], spec: [Double] = []
    private var order: [Int] = []

    // audio-driven animation state
    private var angle = 0.0, sway = 0.0
    private var energy = 0.0
    private var pulses: [(u: Double, a: Double)] = []
    private var previousBass = 0.0
    private var armed = true
    // analysis camera
    private var shot = 0
    private var blend = 1.0
    private var camFrom = Camera.full
    private var camNow = Camera.full
    private var sinceSwitch = 0.0
    private var beats = 0
    private var caption = "silent"
    private var captionAge = 0.0
    private var lastDT = 0.0
    private let textCache = ThemeKit.TextCache()
    // analysis overlay text is rasterised into two images and refreshed at most 10 times per second
    private var textImage: CGImage?
    private var calloutImage: CGImage?
    private var textAge = 1.0
    private var textKey = ""

    public init(analysis: Bool) { self.analysis = analysis }

    private struct Camera {
        var yaw: Double, pitch: Double, zoom: Double, focusU: Double?, ox: Double, oy: Double
        static let full = Camera(yaw: 0, pitch: 0.42, zoom: 1, focusU: nil, ox: 0, oy: 0)
        static let threeQuarter = Camera(yaw: 0.6, pitch: 0.62, zoom: 1.12, focusU: nil, ox: 0, oy: 0.02)
        static let macro = Camera(yaw: -0.5, pitch: 0.28, zoom: 3.4, focusU: 0.22, ox: 0, oy: 0)
        static let low = Camera(yaw: -0.38, pitch: 0.1, zoom: 1.05, focusU: nil, ox: 0, oy: -0.02)
    }
    private static let shots: [(name: String, cam: Camera, callouts: Bool)] = [
        ("FULL VIEW", .full, true), ("THREE-QUARTER", .threeQuarter, true), ("MACRO · FINS", .macro, false), ("LOW ANGLE", .low, true),
    ]
    private static let sections: [(key: String, zh: String, range: String, u: Double, from: Double, to: Double, place: Int)] = [
        ("BASS", "低頻", "20–250 Hz", 0.25, 0, 0.25, 0),        // place 0 = bottom-left
        ("MID", "中頻", "250 Hz–4 kHz", 0.02, 0.25, 0.75, 1),    // 1 = top-left
        ("TREBLE", "高頻", "4–16 kHz", 0.75, 0.75, 1, 2),        // 2 = top-right
    ]
    private static let captions: [String: (String, String)] = [
        "silent": ("等待訊號。", "AWAITING SIGNAL."),
        "BASS": ("低頻正在推動回路。", "THE BASS IS DRIVING THE LOOP."),
        "MID": ("中頻沿著回路流動。", "THE MIDS FLOW ALONG THE LOOP."),
        "TREBLE": ("高頻點亮了邊界。", "THE HIGHS LIGHT UP THE EDGE."),
        "macro": ("兩百四十片鰭，一條回路。", "TWO HUNDRED FORTY FINS. ONE LOOP."),
    ]

    /// 頻率位置：交叉點（u = 0、0.5）中頻，u = 0.25 最低頻，u = 0.75 最高頻。
    static func frequencyPosition(_ u: Double) -> Double {
        let x = u - floor(u)
        return x < 0.5 ? 0.5 - 0.5 * sin(Double.pi * x / 0.5) : 0.5 + 0.5 * sin(Double.pi * (x - 0.5) / 0.5)
    }

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame,
                     look: VisualizerConfig.Look, options: RenderOptions) {
        context.clear(CGRect(origin: .zero, size: size))
        let n = min(frame.values.count, frame.peaks.count)
        guard size.width > 8, size.height > 8, n > 0 else { return }
        let small = options.isThumbnail
        let m = small ? 110 : 240
        if finCount != m { buildFrames(m) }
        let dt = options.dt.isFinite ? min(0.05, max(0, options.dt)) : 0
        lastDT = dt
        step(frame: frame, count: n, dt: dt)

        // camera: sway around the symmetric front view (only while there is sound) + analysis shots
        var cam = Camera.full
        if analysis && !small { cam = advanceCamera(dt: dt) }
        let yaw = cam.yaw + 0.28 * sway * sin(angle)
        let cyaw = cos(yaw), syaw = sin(yaw), cp = cos(cam.pitch), sp = sin(cam.pitch)
        let w = Double(size.width), h = Double(size.height)
        let baseScale = min(w * 0.4, h * 1.02) * cam.zoom
        var cx = w / 2 + cam.ox * w, cy = h / 2 + cam.oy * h
        if let focus = cam.focusU {
            // macro: keep the chosen fin in the middle of the frame
            let i = min(finCount - 1, max(0, Int((focus * Double(finCount)).rounded())))
            let r = rotate(px[i], py[i], pz[i], cyaw, syaw, cp, sp)
            let p = 1 / (1 - r.2 * 0.35)
            cx -= r.0 * baseScale * p
            cy += r.1 * baseScale * p
        }

        let style = SculptureStyleColors.of(options.sculptureStyle)
        let lightX = -0.45, lightY = -0.65, lightZ = 0.62
        var i = 0
        while i < m {
            let u = finU[i]
            let f = Self.frequencyPosition(u)
            let e = bandEnergy(frame, n, f)
            let pu = pulseAt(u)
            let half = 0.085 * (1 + 1.5 * e + 0.55 * pu)
            let p = rotate(px[i], py[i], pz[i], cyaw, syaw, cp, sp)
            let wv = rotate(wx[i], wy[i], wz[i], cyaw, syaw, cp, sp)
            let nv = rotate(nx[i], ny[i], nz[i], cyaw, syaw, cp, sp)
            let za = p.2 + wv.2 * half, zb = p.2 - wv.2 * half
            let pa = 1 / (1 - za * 0.35), pb = 1 / (1 - zb * 0.35)
            sx0[i] = CGFloat(cx + (p.0 + wv.0 * half) * baseScale * pa)
            sy0[i] = CGFloat(cy - (p.1 + wv.1 * half) * baseScale * pa)
            sx1[i] = CGFloat(cx + (p.0 - wv.0 * half) * baseScale * pb)
            sy1[i] = CGFloat(cy - (p.1 - wv.1 * half) * baseScale * pb)
            depth[i] = p.2
            let lam = abs(nv.0 * lightX + nv.1 * lightY + nv.2 * lightZ)
            shade[i] = 0.58 + 0.42 * lam
            spec[i] = style.metalness * pow(lam, 6) * 0.75 + (1 - style.roughness) * pow(lam, 18) * 0.25
            glow[i] = min(1, pu * 0.9 + e * 0.18)
            posF[i] = f
            order[i] = i
            i += 1
        }
        let d = depth
        order.sort { d[$0] < d[$1] }

        // soft ground shadow so the sculpture sits on light wallpapers too
        if !small {
            context.saveGState()
            let gy = CGFloat(min(h * 0.92, cy + baseScale * 0.62))
            context.translateBy(x: CGFloat(cx), y: gy)
            context.scaleBy(x: 1, y: 0.16)
            let colors = [ThemeKit.color(RGB(red: 40, green: 36, blue: 30), 0.16), ThemeKit.color(RGB(red: 40, green: 36, blue: 30), 0)]
            if let g = CGGradient(colorsSpace: ThemeKit.sRGB, colors: colors as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                           endRadius: CGFloat(baseScale * 0.95), options: [])
            }
            context.restoreGState()
        }

        let pitchPx = CGFloat(baseScale * Double.pi * 2 * 0.62 / Double(m))
        let lw = max(0.8, pitchPx * 0.72)
        context.setLineCap(.butt)
        // outlines in one batched stroke (gives the slatted look and an edge on light wallpapers)
        context.beginPath()
        var k = 0
        while k < m {
            let j = order[k]
            context.move(to: CGPoint(x: sx0[j], y: sy0[j]))
            context.addLine(to: CGPoint(x: sx1[j], y: sy1[j]))
            k += 1
        }
        context.setStrokeColor(ThemeKit.color(style.soft, alphaScale: small ? 0.45 : 0.55))
        context.setLineWidth(lw + 0.7)
        context.strokePath()
        // fins back to front (colour set via components: no CGColor allocation per fin)
        context.setLineWidth(lw)
        context.setStrokeColorSpace(ThemeKit.sRGB)
        var rgba: [CGFloat] = [0, 0, 0, 1]
        k = 0
        while k < m {
            let j = order[k]
            let base = style.baseColor(at: posF[j], palette: look.palette)
            let g = glow[j], sh = shade[j]
            let sp = spec[j]
            rgba[0] = CGFloat(min(1, (Double(base.red) * sh * (1 - g) + Double(style.pulse.red) * g) / 255 + sp))
            rgba[1] = CGFloat(min(1, (Double(base.green) * sh * (1 - g) + Double(style.pulse.green) * g) / 255 + sp))
            rgba[2] = CGFloat(min(1, (Double(base.blue) * sh * (1 - g) + Double(style.pulse.blue) * g) / 255 + sp))
            context.setStrokeColor(rgba)
            context.beginPath()
            context.move(to: CGPoint(x: sx0[j], y: sy0[j]))
            context.addLine(to: CGPoint(x: sx1[j], y: sy1[j]))
            context.strokePath()
            k += 1
        }

        guard !small, size.height >= 120 else { return }
        if analysis {
            drawAnalysisOverlay(context, size, frame, n, style, cx: cx, cy: cy, scale: baseScale,
                                rot: (cyaw, syaw, cp, sp), pixelScale: options.scale)
        } else {
            drawSpecimenLabels(context, size, style)
        }
    }

    // MARK: - animation

    private func step(frame: SpectrumFrame, count n: Int, dt: Double) {
        var sum = 0.0
        var i = 0
        while i < n { sum += ThemeKit.clamp01(frame.values[i]); i += 1 }
        energy = sum / Double(n)
        if energy < 0.01 { energy = 0 }
        // sway phase advances only with sound; its amplitude eases back to the front view in silence, then stops exactly
        angle = (angle + dt * energy * 0.9).truncatingRemainder(dividingBy: 2 * Double.pi)
        sway += ((energy > 0 ? 1 : 0) - sway) * (1 - exp(-dt / (energy > 0 ? 0.4 : 0.6)))
        if energy == 0 && sway < 1e-3 { sway = 0 }
        let bass = ThemeKit.clamp01(frame.bass)
        if armed && bass > 0.55 && bass > previousBass + 0.02 { pulses.append((0, bass)); armed = false; beats += 1 }
        if bass < 0.35 { armed = true }
        previousBass = bass
        var j = 0
        while j < pulses.count {
            pulses[j].u += dt * 0.55
            pulses[j].a *= exp(-dt * 0.9)
            j += 1
        }
        pulses.removeAll { $0.u >= 1 || $0.a <= 0.02 }
    }

    private func pulseAt(_ u: Double) -> Double {
        var v = 0.0
        var j = 0
        while j < pulses.count {
            var d = abs(u - pulses[j].u).truncatingRemainder(dividingBy: 1)
            d = min(d, 1 - d)
            v += pulses[j].a * exp(-(d * d) / 0.0012)
            j += 1
        }
        return min(1.5, v)
    }

    private func bandEnergy(_ frame: SpectrumFrame, _ n: Int, _ f: Double) -> Double {
        let x = min(Double(n - 1), max(0, f * Double(n - 1)))
        let i = Int(x), j = min(n - 1, i + 1), fr = x - Double(i)
        let v = ThemeKit.clamp01(frame.values[i]) * (1 - fr) + ThemeKit.clamp01(frame.values[j]) * fr
        return v < 0.004 ? 0 : v
    }

    private func advanceCamera(dt: Double) -> Camera {
        let onset = beats != lastBeats
        lastBeats = beats
        if energy > 0 { sinceSwitch += dt }
        var target = shot
        if energy > 0 && onset && sinceSwitch > 3.2 { target = (shot + 1) % Self.shots.count }
        if energy == 0 { target = 0 }
        if target != shot { camFrom = camNow; shot = target; blend = 0; sinceSwitch = 0 }
        if blend < 1 { blend = min(1, blend + dt / 1.6) }
        let to = Self.shots[shot].cam
        let k = blend < 0.5 ? 4 * blend * blend * blend : 1 - pow(-2 * blend + 2, 3) / 2
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        var cam = Camera(yaw: lerp(camFrom.yaw, to.yaw), pitch: lerp(camFrom.pitch, to.pitch), zoom: lerp(camFrom.zoom, to.zoom),
                         focusU: nil, ox: lerp(camFrom.ox, to.ox), oy: lerp(camFrom.oy, to.oy))
        // macro focus fades in/out with the blend so the transition stays smooth
        if to.focusU != nil && k > 0.5 { cam.focusU = to.focusU }
        if camFrom.focusU != nil && k <= 0.5 { cam.focusU = camFrom.focusU }
        camNow = cam
        return cam
    }
    private var lastBeats = 0

    // MARK: - geometry

    private func buildFrames(_ m: Int) {
        finCount = m
        px = Array(repeating: 0, count: m); py = px; pz = px; wx = px; wy = px; wz = px; nx = px; ny = px; nz = px; finU = px
        sx0 = Array(repeating: 0, count: m); sy0 = sx0; sx1 = sx0; sy1 = sx0
        depth = Array(repeating: 0, count: m); shade = depth; glow = depth; posF = depth; spec = depth
        order = Array(0..<m)
        func lem(_ t: Double) -> (Double, Double, Double) {
            let s = sin(t), c = cos(t), d = 1 + s * s
            return (c / d, s * c / d, 0.28 * s)
        }
        var i = 0
        while i < m {
            let u = Double(i) / Double(m), t = Double.pi / 2 + u * Double.pi * 2
            let p = lem(t), a = lem(t - 0.002), b = lem(t + 0.002)
            var tx = b.0 - a.0, ty = b.1 - a.1, tz = b.2 - a.2
            let tl = max(1e-9, (tx * tx + ty * ty + tz * tz).squareRoot()); tx /= tl; ty /= tl; tz /= tl
            var bx = ty, by = -tx
            let bl = max(1e-9, (bx * bx + by * by).squareRoot()); bx /= bl; by /= bl
            let bz = 0.0
            let n0x = by * tz - bz * ty, n0y = bz * tx - bx * tz, n0z = bx * ty - by * tx
            let twist = u * Double.pi + 0.35 * sin(u * Double.pi * 4)
            let ct = cos(twist), st = sin(twist)
            let wxv = bx * ct + n0x * st, wyv = by * ct + n0y * st, wzv = bz * ct + n0z * st
            px[i] = p.0; py[i] = p.1; pz[i] = p.2
            wx[i] = wxv; wy[i] = wyv; wz[i] = wzv
            nx[i] = ty * wzv - tz * wyv; ny[i] = tz * wxv - tx * wzv; nz[i] = tx * wyv - ty * wxv
            finU[i] = u
            i += 1
        }
    }

    @inline(__always)
    private func rotate(_ x: Double, _ y: Double, _ z: Double, _ cy: Double, _ sy: Double, _ cp: Double, _ sp: Double) -> (Double, Double, Double) {
        let x1 = x * cy + z * sy, z1 = -x * sy + z * cy
        return (x1, y * cp - z1 * sp, y * sp + z1 * cp)
    }

    // MARK: - overlays

    private func drawSpecimenLabels(_ ctx: CGContext, _ size: CGSize, _ style: SculptureStyleColors) {
        let ink = ThemeKit.color(style.ink, alphaScale: 0.9), halo = ThemeKit.color(style.halo)
        let w = size.width, h = size.height
        ThemeKit.text(ctx, "SPECIMEN ∞ — ANALYSIS", x: 14, y: 18, size: 9, color: ink, halo: halo, cache: textCache)
        let level = energy > 0 ? String(format: "%.1f dB", 20 * log10(max(1e-4, energy))) : "—∞ dB"
        ThemeKit.text(ctx, "LVL \(level)", x: w - 14, y: 18, size: 9, color: ink, align: .right, halo: halo, cache: textCache)
        ThemeKit.text(ctx, "LOW ◂", x: 14, y: h - 12, size: 9, color: ink, halo: halo, cache: textCache)
        ThemeKit.text(ctx, "▸ HIGH", x: w - 14, y: h - 12, size: 9, color: ink, align: .right, halo: halo, cache: textCache)
    }

    private func groupEnergy(_ frame: SpectrumFrame, _ n: Int, _ from: Double, _ to: Double) -> Double {
        let i0 = Int(from * Double(n)), i1 = max(i0 + 1, min(n, Int(to * Double(n))))
        var s = 0.0
        var i = i0
        while i < i1 { s += ThemeKit.clamp01(frame.values[i]); i += 1 }
        let v = s / Double(i1 - i0)
        return v < 0.01 ? 0 : v
    }

    private func drawAnalysisOverlay(_ ctx: CGContext, _ size: CGSize, _ frame: SpectrumFrame, _ n: Int,
                                     _ style: SculptureStyleColors, cx: Double, cy: Double, scale: Double,
                                     rot: (Double, Double, Double, Double), pixelScale: CGFloat) {
        let w = size.width, h = size.height
        let big = h >= 260
        let soft = ThemeKit.color(style.soft)

        // caption state (changes at most every 2 s, immediately when silence starts)
        var topKey = "MID", topE = -1.0
        var s = 0
        while s < Self.sections.count {
            let e = groupEnergy(frame, n, Self.sections[s].from, Self.sections[s].to)
            if e > topE { topE = e; topKey = Self.sections[s].key }
            s += 1
        }
        let want = energy == 0 ? "silent" : (Self.shots[shot].cam.focusU != nil ? "macro" : topKey)
        captionAge += lastDT
        if want != caption && (captionAge > 2 || want == "silent") { caption = want; captionAge = 0 }

        // All text is rasterised into two cached images, refreshed at most 10×/s (and only on change in silence).
        textAge += lastDT
        let key = "\(Int(w))x\(Int(h))@\(pixelScale)|\(style.ink.0.red),\(style.ink.0.green),\(style.ink.0.blue)|\(shot)|\(caption)|\(energy == 0)"
        if textImage == nil || key != textKey || (energy > 0 && textAge >= 0.1) {
            textAge = 0
            textKey = key
            textImage = rasterize(size, pixelScale) { t in self.drawStaticText(t, size, frame, n, style, big: big) }
            calloutImage = rasterize(size, pixelScale) { t in self.drawCalloutText(t, size, frame, n, style, big: big) }
        }

        // beat meter (top right) — cheap, drawn every frame
        let dots = 4, dx: CGFloat = 9, x0 = w - 14 - CGFloat(dots - 1) * dx, y0: CGFloat = 16
        ctx.setStrokeColor(soft); ctx.setLineWidth(0.8)
        ctx.beginPath(); ctx.move(to: CGPoint(x: x0 - 18, y: y0)); ctx.addLine(to: CGPoint(x: w - 14, y: y0)); ctx.strokePath()
        var d = 0
        while d < dots {
            let on = energy > 0 && beats % dots == d
            ctx.setFillColor(on ? ThemeKit.color(style.accent, 1) : soft)
            ThemeKit.dot(ctx, x0 + CGFloat(d) * dx, y0, on ? 2.6 : 1.6)
            d += 1
        }
        if let textImage { drawImage(ctx, textImage, size, alpha: 1) }

        // callouts: leader lines + anchors follow the camera; labels come from the cached image
        let ease = blend < 0.5 ? 4 * blend * blend * blend : 1 - pow(-2 * blend + 2, 3) / 2
        let show = Self.shots[shot].callouts ? ease : 0
        guard show > 0.02 else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(show))
        s = 0
        while s < Self.sections.count {
            let section = Self.sections[s]
            s += 1
            let i = min(finCount - 1, max(0, Int((section.u * Double(finCount)).rounded())))
            let r = rotate(px[i], py[i], pz[i], rot.0, rot.1, rot.2, rot.3)
            let p = 1 / (1 - r.2 * 0.35)
            let ax = CGFloat(cx + r.0 * scale * p), ay = CGFloat(cy - r.1 * scale * p)
            guard ax > -10, ax < w + 10, ay > -10, ay < h + 10 else { continue }
            let anchor = calloutAnchor(section.place, size, big: big)
            ctx.setStrokeColor(soft); ctx.setLineWidth(0.7)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ax, y: ay))
            ctx.addLine(to: CGPoint(x: anchor.elbowX, y: anchor.y + 3))
            ctx.addLine(to: CGPoint(x: anchor.right ? anchor.elbowX + 6 : anchor.elbowX - 6, y: anchor.y + 3))
            ctx.strokePath()
            ctx.setFillColor(ThemeKit.color(style.accent, 1)); ThemeKit.dot(ctx, ax, ay, 2.2)
        }
        ctx.restoreGState()
        if let calloutImage { drawImage(ctx, calloutImage, size, alpha: CGFloat(show)) }
    }

    private func calloutAnchor(_ place: Int, _ size: CGSize, big: Bool) -> (x: CGFloat, y: CGFloat, elbowX: CGFloat, right: Bool) {
        let right = place == 2
        let x: CGFloat = right ? size.width - 14 : 14
        let y: CGFloat = place == 0 ? size.height - (big ? 52 : 40) : (big ? 78 : 62)
        return (x, y, right ? x - (big ? 150 : 112) : x + (big ? 150 : 112), right)
    }

    private func drawStaticText(_ ctx: CGContext, _ size: CGSize, _ frame: SpectrumFrame, _ n: Int,
                                _ style: SculptureStyleColors, big: Bool) {
        let w = size.width, h = size.height
        let ink = ThemeKit.color(style.ink), soft = ThemeKit.color(style.soft), halo = ThemeKit.color(style.halo)
        ThemeKit.text(ctx, "PULSEFLOAT", x: 14, y: 22, size: big ? 15 : 12, mono: false, bold: true, color: ink, halo: halo, cache: textCache)
        ThemeKit.text(ctx, "SYNTHESIZE AUDIO", x: 14, y: 30, size: big ? 7 : 6, color: soft, halo: halo, cache: textCache)
        let analysisY: CGFloat = big ? 46 : 41
        let aw = ThemeKit.text(ctx, "ANALYSIS ", x: 14, y: analysisY, size: big ? 13 : 10.5, mono: false, light: true, color: ink, halo: halo, cache: textCache)
        ThemeKit.text(ctx, "OS", x: 14 + aw, y: analysisY, size: big ? 13 : 10.5, mono: false, bold: true, color: ink, halo: halo, cache: textCache)
        var loudest = 0, best = -1.0
        var b = 0
        while b < n { let v = Double(frame.values[b]); if v > best { best = v; loudest = b }; b += 1 }
        let fl = n > 1 ? Double(loudest) / Double(n - 1) : 0.5
        let uL = fl < 0.5 ? asin(min(1, (0.5 - fl) / 0.5)) / Double.pi * 0.5 : 0.5 + asin(min(1, (fl - 0.5) / 0.5)) / Double.pi * 0.5
        let fin = best > 0 ? Int((uL * Double(finCount)).rounded()) % finCount : 0
        ThemeKit.text(ctx, "\(Self.shots[shot].name) · FIN \(String(format: "%03d", fin)) / \(finCount)",
                      x: w - 14, y: 28, size: 6.5, color: soft, align: .right, halo: halo)
        let cap = Self.captions[caption] ?? ("", "")
        ThemeKit.text(ctx, cap.0, x: w / 2, y: h - (big ? 22 : 17), size: big ? 11 : 9, mono: false, bold: true, color: ink, align: .center, halo: halo, cache: textCache)
        ThemeKit.text(ctx, cap.1, x: w / 2, y: h - (big ? 11 : 8), size: big ? 6.5 : 5.5, color: soft, align: .center, halo: halo, cache: textCache)
        ThemeKit.text(ctx, "POWERED BY PULSEFLOAT —", x: w - 14, y: h - 10, size: big ? 7 : 6, bold: true, color: soft, align: .right, halo: halo, cache: textCache)
    }

    private func drawCalloutText(_ ctx: CGContext, _ size: CGSize, _ frame: SpectrumFrame, _ n: Int,
                                 _ style: SculptureStyleColors, big: Bool) {
        let ink = ThemeKit.color(style.ink), soft = ThemeKit.color(style.soft), halo = ThemeKit.color(style.halo)
        var s = 0
        while s < Self.sections.count {
            let section = Self.sections[s]
            s += 1
            let anchor = calloutAnchor(section.place, size, big: big)
            let e = groupEnergy(frame, n, section.from, section.to)
            let db = e > 0 ? String(format: "%.1f dB", 20 * log10(e)) : "—∞ dB"
            let tag = "SPECTRUM SECT."
            let tw = ThemeKit.textWidth(tag, size: 5.5, bold: true) + 6
            let tagX = anchor.right ? anchor.x - tw : anchor.x
            ctx.setFillColor(ThemeKit.color(style.tagBackground)); ctx.fill(CGRect(x: tagX, y: anchor.y - 18, width: tw, height: 8))
            ThemeKit.text(ctx, tag, x: tagX + 3, y: anchor.y - 12, size: 5.5, bold: true, color: ThemeKit.color(style.tagForeground, 1), cache: textCache)
            ThemeKit.text(ctx, "\(section.key) SECTION", x: anchor.x, y: anchor.y - 1, size: big ? 11 : 8.5, mono: false, bold: true,
                          color: ink, align: anchor.right ? .right : .left, halo: halo, cache: textCache)
            ThemeKit.text(ctx, "\(section.zh) · \(section.range) · \(db)", x: anchor.x, y: anchor.y + (big ? 11 : 8), size: big ? 7 : 6,
                          color: soft, align: anchor.right ? .right : .left, halo: halo)
        }
    }

    private func rasterize(_ size: CGSize, _ scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let pw = max(1, Int((size.width * scale).rounded(.up))), ph = max(1, Int((size.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: ThemeKit.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        body(ctx)
        return ctx.makeImage()
    }

    private func drawImage(_ ctx: CGContext, _ image: CGImage, _ size: CGSize, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}
