import CoreGraphics

/// 原型 drawBars 的漸層直條、峰值帽與倒影；同一實例須序列使用。
public final class BarsRenderer: SpectrumRenderer {
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
        let padX = size.width * 0.05
        let padY = size.height * (options.isThumbnail ? 0.1 : 0.12)
        let pitch = (size.width - padX * 2) / CGFloat(count)
        let barWidth = max(1, pitch * (1 - look.barGap))
        let radius = min(barWidth / 2, 3)
        let base = look.mirror ? size.height / 2 : (look.reflection ? size.height * 0.74 : size.height - padY)
        let maxHeight = look.mirror ? size.height / 2 - padY : base - padY
        var index = 0
        while index < count {
            let x = padX + CGFloat(index) * pitch + (pitch - barWidth) / 2
            let barHeight = max(2, RenderMath.unit(frame.values[index]) * maxHeight)
            let color = colors[index]
            let rect = CGRect(x: x, y: base - barHeight, width: barWidth, height: barHeight * (look.mirror ? 2 : 1))
            if let gradient = RenderMath.gradient([color.cgColor(), color.cgColor(alpha: 0.55)], locations: [0, 1]) {
                RenderMath.fillGradient(gradient, in: context, path: RenderMath.roundedRect(rect, radius: radius),
                                        start: CGPoint(x: 0, y: base - maxHeight), end: CGPoint(x: 0, y: base))
            }
            if !look.mirror && look.reflection {
                let reflection = CGRect(x: x, y: base + 2, width: barWidth, height: barHeight * 0.32)
                RenderMath.fill(RenderMath.roundedRect(reflection, radius: radius), in: context, color: color.cgColor(alpha: 0.16))
            }
            let peakHeight = max(2, RenderMath.unit(frame.peaks[index]) * maxHeight)
            context.setFillColor(color.cgColor(alpha: 0.95))
            context.fill(CGRect(x: x, y: base - peakHeight - 4, width: barWidth, height: options.isThumbnail ? 1.5 : 2))
            if look.mirror {
                context.fill(CGRect(x: x, y: base + peakHeight + 2, width: barWidth, height: options.isThumbnail ? 1 : 2))
            }
            index += 1
        }
    }
}
