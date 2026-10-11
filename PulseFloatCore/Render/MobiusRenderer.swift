import CoreGraphics

/// 暫時的佔位實作（委派給 BarsRenderer）；將由正式移植取代。
public final class MobiusRenderer: SpectrumRenderer {
    private let fallback = BarsRenderer()
    /// analysis = true 時是「解析」主題的 2D 備援（含標題與區段標註）。
    public let analysis: Bool
    public init(analysis: Bool) { self.analysis = analysis }

    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        fallback.draw(in: context, size: size, frame: frame, look: look, options: options)
    }
}
