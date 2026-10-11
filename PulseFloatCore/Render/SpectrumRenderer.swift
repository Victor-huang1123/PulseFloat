import CoreGraphics

/// 純 Core Graphics 頻譜繪圖器；同一實例必須序列使用，不綁定 actor。
public protocol SpectrumRenderer: AnyObject {
    /// size 單位為 pt；context 已是 y 向下座標並套用 backing scale。
    /// look 應先經 VisualizerConfig.clamped()；空或不等長的 frame 只清空畫面。
    func draw(
        in context: CGContext,
        size: CGSize,
        frame: SpectrumFrame,
        look: VisualizerConfig.Look,
        options: RenderOptions
    )
}

/// 每幀繪圖選項，可跨執行緒傳遞。
public struct RenderOptions: Sendable {
    /// 是否採原型的小型縮圖幾何及光暈。
    public var isThumbnail: Bool
    /// Neon 殘影淡出比例 0...1；呼叫端以 1 − exp(−dt / 0.07) 計算，dt 單位為秒。
    public var fade: Double
    /// 點轉像素的正倍率；由 view 的 backingScaleFactor 提供，測試通常為 1 或 2。
    public var scale: CGFloat

    /// 建立繪圖選項，不改變輸入；呼叫端須提供有限的正 scale 與 0...1 的 fade。
    public init(isThumbnail: Bool = false, fade: Double, scale: CGFloat = 1) {
        self.isThumbnail = isThumbnail
        self.fade = fade
        self.scale = scale
    }
}
