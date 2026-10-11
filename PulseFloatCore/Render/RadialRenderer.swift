import CoreGraphics
import Foundation

/// 原型 drawRadial 的左右對稱放射線與低頻脈動圓盤；同一實例須序列使用。
/// options.artwork 有值時，中央圓盤以 options.dt 平滑放大並顯示封面或 App 圖示；沒有圖片時畫面與原本完全相同。
public final class RadialRenderer: SpectrumRenderer {
    private let paletteCache = RenderPaletteCache()
    /// 目前要顯示（淡入中或已完整顯示）的中央圖片。
    private var currentArtwork: CenterArtwork?
    private var currentAlpha: Double = 0
    /// 換圖時保留的前一張，淡出完才丟掉。
    private var previousArtwork: CenterArtwork?
    private var previousAlpha: Double = 0
    /// 圓盤放大程度 0...1：0 是原本的短邊 × 0.18，1 是有圖片時的短邊 × 0.27。
    private var artworkMix: Double = 0

    /// 新舊圖片交叉淡入淡出的秒數。
    private static let crossfadeSeconds = 0.35
    /// 圓盤放大／縮回的時間常數（秒）。
    private static let growTimeConstant = 0.25

    /// 建立獨立繪圖器，不綁定 actor。
    public init() {}

    /// 以 pt 與 y 向下的 context 繪圖；look 須先 clamped，空或不等長 frame 只清空。
    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(origin: .zero, size: size))
        guard RenderMath.isDrawable(size: size, frame: frame) else { return }
        advanceArtwork(to: options.artwork, dt: options.dt)
        let count = frame.bandCount
        let colors = paletteCache.colors(for: look.palette, count: count)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minimum = min(size.width, size.height)
        let bass = RenderMath.unit(frame.bass)
        // 有圖片時圓盤變大、脈動減半、放射線縮短，整體外徑與原本相同；mix 為 0 時算式與原本逐位元相同。
        let mix = CGFloat(artworkMix)
        let radius = minimum * (0.18 + 0.09 * mix) * (1 + (0.08 - 0.04 * mix) * bass)
        let length = minimum * (0.3 - 0.09 * mix)
        let lineWidth = max(1.2, min(5, (.pi * radius) / CGFloat(count) * 0.62))
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        var side = -1.0
        while side <= 1 {
            var index = 0
            while index < count {
                let angle = -.pi / 2 + side * (.pi * (Double(index) + 0.5) / Double(count))
                let cosine = CGFloat(cos(angle))
                let sine = CGFloat(sin(angle))
                let extent = max(1.5, RenderMath.unit(frame.values[index]) * length)
                let start = radius + 3
                let end = start + extent
                context.setStrokeColor(colors[index].cgColor(alpha: 0.95))
                context.beginPath()
                context.move(to: CGPoint(x: center.x + cosine * start, y: center.y + sine * start))
                context.addLine(to: CGPoint(x: center.x + cosine * end, y: center.y + sine * end))
                context.strokePath()
                if !options.isThumbnail {
                    let peakRadius = radius + 3 + max(1.5, RenderMath.unit(frame.peaks[index]) * length) + lineWidth * 1.6
                    context.setFillColor(colors[index].cgColor(alpha: 0.9))
                    context.fillEllipse(in: CGRect(x: center.x + cosine * peakRadius - lineWidth * 0.5,
                                                   y: center.y + sine * peakRadius - lineWidth * 0.5,
                                                   width: lineWidth, height: lineWidth))
                }
                index += 1
            }
            side += 2
        }
        let coreRadius = max(1, radius - 2)
        let corePath = circle(center: center, radius: coreRadius)
        let dark = RGB(red: 10, green: 12, blue: 18)
        if let gradient = RenderMath.gradient([dark.cgColor(alpha: 0.92), dark.cgColor(alpha: 0.75)], locations: [0, 1]) {
            context.saveGState()
            context.addPath(corePath)
            context.clip()
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: max(1, radius), options: [])
            context.restoreGState()
        }
        let palette = Palette(look.palette)
        let ringGradient = RenderMath.gradient([palette.color(at: 0).cgColor(), palette.color(at: 1).cgColor()], locations: [0, 1])
        let coverVisibility = drawArtwork(in: context, center: center, coreRadius: coreRadius,
                                          ringGradient: ringGradient, isThumbnail: options.isThumbnail)
        if let gradient = ringGradient {
            let start = CGPoint(x: center.x - radius, y: center.y - radius)
            let end = CGPoint(x: center.x + radius, y: center.y + radius)
            context.setLineWidth(options.isThumbnail ? 1.2 : 2)
            RenderMath.strokeGradient(gradient, in: context, path: corePath, start: start, end: end)
            // 封面蓋住圓盤時淡出原本的內圈。
            let innerAlpha = (0.25 + 0.5 * bass) * (1 - coverVisibility)
            if innerAlpha > 0.001 {
                context.setAlpha(innerAlpha)
                context.setLineWidth(options.isThumbnail ? 0.8 : 1)
                RenderMath.strokeGradient(gradient, in: context, path: circle(center: center, radius: coreRadius * 0.72), start: start, end: end)
            }
        }
    }

    /// 依 dt 推進交叉淡入與圓盤大小；兩者都會收斂到確切的目標值，之後靜音時畫面完全靜止。
    private func advanceArtwork(to artwork: CenterArtwork?, dt rawDT: Double) {
        let dt = rawDT.isFinite ? min(0.1, max(0, rawDT)) : 0
        if artwork != currentArtwork {
            // 保留比較明顯的那張繼續淡出，避免連續換圖時閃一下。
            if currentArtwork != nil, currentAlpha >= previousAlpha || previousArtwork == nil {
                previousArtwork = currentArtwork
                previousAlpha = currentAlpha
            }
            currentArtwork = artwork
            currentAlpha = 0
        }
        let step = dt / Self.crossfadeSeconds
        currentAlpha = currentArtwork == nil ? 0 : min(1, currentAlpha + step)
        previousAlpha = max(0, previousAlpha - step)
        if previousAlpha <= 0 {
            previousArtwork = nil
            previousAlpha = 0
        }
        let target: Double = currentArtwork == nil ? 0 : 1
        artworkMix += (target - artworkMix) * (1 - exp(-dt / Self.growTimeConstant))
        if abs(target - artworkMix) < 0.001 { artworkMix = target }
    }

    /// 畫淡出中的前一張與目前的圖片；回傳封面目前的覆蓋程度 0...1（用來淡出原本的內圈）。
    private func drawArtwork(in context: CGContext, center: CGPoint, coreRadius: CGFloat,
                             ringGradient: CGGradient?, isThumbnail: Bool) -> CGFloat {
        var coverVisibility: CGFloat = 0
        if let previousArtwork, previousAlpha > 0 {
            let alpha = Self.eased(previousAlpha)
            draw(previousArtwork, alpha: alpha, in: context, center: center, coreRadius: coreRadius,
                 ringGradient: ringGradient, isThumbnail: isThumbnail)
            if previousArtwork.kind == .cover { coverVisibility += alpha }
        }
        if let currentArtwork, currentAlpha > 0 {
            let alpha = Self.eased(currentAlpha)
            draw(currentArtwork, alpha: alpha, in: context, center: center, coreRadius: coreRadius,
                 ringGradient: ringGradient, isThumbnail: isThumbnail)
            if currentArtwork.kind == .cover { coverVisibility += alpha }
        }
        return min(1, coverVisibility)
    }

    private func draw(_ artwork: CenterArtwork, alpha: CGFloat, in context: CGContext, center: CGPoint,
                      coreRadius: CGFloat, ringGradient: CGGradient?, isThumbnail: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        switch artwork.kind {
        case .cover:
            let radius = max(1, coreRadius - 2)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            // 柔和的暗色陰影：從封面邊緣往外約 5 pt 漸淡，不碰到放射線。
            let shadowColor = RGB(red: 0, green: 0, blue: 0)
            if let shadow = RenderMath.gradient([shadowColor.cgColor(alpha: 0.55), shadowColor.cgColor(alpha: 0)], locations: [0, 1]) {
                context.drawRadialGradient(shadow, startCenter: center, startRadius: max(0, radius - 1),
                                           endCenter: center, endRadius: radius + 5, options: [])
            }
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            drawUpright(artwork.image, in: rect, context: context)
            context.restoreGState()
            if let ringGradient {
                context.setAlpha(alpha * 0.6)
                context.setLineWidth(isThumbnail ? 0.8 : 1)
                RenderMath.strokeGradient(ringGradient, in: context, path: circle(center: center, radius: radius),
                                          start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY))
            }
        case .appIcon:
            // App 圖示本身有透明邊與圓角，不裁切，寬度約為圓盤半徑的 1.25 倍。
            let side = coreRadius * 1.25
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            drawUpright(artwork.image, in: rect, context: context)
        }
    }

    /// context 是 y 向下座標；CGContext.draw 會把圖畫成上下顛倒，所以在 rect 內局部翻轉回來。
    private func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// smoothstep 緩動，0 與 1 保持不變。
    private static func eased(_ value: Double) -> CGFloat {
        let t = min(1, max(0, value))
        return CGFloat(t * t * (3 - 2 * t))
    }

    private func circle(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }
}
