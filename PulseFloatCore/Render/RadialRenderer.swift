import CoreGraphics
import Foundation

/// 原型 drawRadial 的左右對稱放射線與低頻脈動圓盤；同一實例須序列使用。
public final class RadialRenderer: SpectrumRenderer {
    private let paletteCache = RenderPaletteCache()

    /// 建立獨立繪圖器，不綁定 actor。
    public init() {}

    /// 以 pt 與 y 向下的 context 繪圖；look 須先 clamped，空或不等長 frame 只清空。
    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(origin: .zero, size: size))
        guard RenderMath.isDrawable(size: size, frame: frame) else { return }
        let count = frame.bandCount
        let colors = paletteCache.colors(for: look.palette, count: count)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minimum = min(size.width, size.height)
        let bass = RenderMath.unit(frame.bass)
        let radius = minimum * 0.18 * (1 + 0.08 * bass)
        let length = minimum * 0.3
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
        if let gradient = RenderMath.gradient([palette.color(at: 0).cgColor(), palette.color(at: 1).cgColor()], locations: [0, 1]) {
            let start = CGPoint(x: center.x - radius, y: center.y - radius)
            let end = CGPoint(x: center.x + radius, y: center.y + radius)
            context.setLineWidth(options.isThumbnail ? 1.2 : 2)
            RenderMath.strokeGradient(gradient, in: context, path: corePath, start: start, end: end)
            context.setAlpha(0.25 + 0.5 * bass)
            context.setLineWidth(options.isThumbnail ? 0.8 : 1)
            RenderMath.strokeGradient(gradient, in: context, path: circle(center: center, radius: coreRadius * 0.72), start: start, end: end)
        }
    }

    private func circle(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }
}
