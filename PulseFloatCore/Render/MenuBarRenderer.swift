import CoreGraphics

/// 原型 drawMenu 的迷你直條或點陣；同一實例須序列使用，不綁定 actor。
public final class MenuBarRenderer {
    /// 建立獨立繪圖器。
    public init() {}

    /// 以 pt 與 y 向下的 context 繪圖，通常為 26×16 pt；config 應先 clamped。
    /// colored 為 false 時每個像素皆為灰階，供 template image 使用；空或不等長 frame 只清空。
    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, config: VisualizerConfig.MenuBar, palette: PaletteID) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(origin: .zero, size: size))
        guard RenderMath.isDrawable(size: size, frame: frame) else { return }
        let count = min(9, max(5, config.count))
        let gap: CGFloat = 1.5
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard width > 0 else { return }
        let colors = Palette(palette)
        var group = 0
        while group < count {
            let first = group * frame.bandCount / count
            let end = min(frame.bandCount, max(first + 1, (group + 1) * frame.bandCount / count))
            var value: CGFloat = 0
            var index = first
            while index < end {
                value = max(value, RenderMath.unit(frame.values[index]))
                index += 1
            }
            let color = config.colored
                ? colors.color(at: Double(group) / Double(count - 1)).cgColor()
                : RGB(red: 255, green: 255, blue: 255).cgColor(alpha: 0.92)
            context.setFillColor(color)
            let x = CGFloat(group) * (width + gap)
            switch config.style {
            case .bars:
                let height = max(2, value * size.height)
                context.addPath(RenderMath.roundedRect(CGRect(x: x, y: (size.height - height) / 2, width: width, height: height), radius: width / 2))
                context.fillPath()
            case .dots:
                let diameter = min(width, (size.height - 3 * 1.5) / 4)
                if diameter > 0 {
                    let lit = max(1, Int((value * 4).rounded()))
                    var dot = 0
                    while dot < 4 {
                        context.setAlpha(dot < lit ? 1 : 0.25)
                        context.fillEllipse(in: CGRect(x: x + (width - diameter) / 2,
                                                       y: size.height - diameter - CGFloat(dot) * (diameter + 1.5),
                                                       width: diameter, height: diameter))
                        dot += 1
                    }
                    context.setAlpha(1)
                }
            }
            group += 1
        }
    }
}
