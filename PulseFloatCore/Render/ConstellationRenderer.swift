import CoreGraphics

/// 暫時的佔位實作（委派給 BarsRenderer）；將由正式移植取代。
public final class ConstellationRenderer: SpectrumRenderer {
    private let fallback = BarsRenderer()
    public init() {}

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        fallback.draw(in: context, size: size, frame: frame, look: look, options: options)
    }
}
