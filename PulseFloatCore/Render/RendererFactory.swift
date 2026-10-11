/// 依主題建立獨立 renderer；工廠無共享狀態，可於任意執行緒呼叫。
public enum RendererFactory {
    /// 建立沒有前一主題殘影的繪圖器；回傳實例必須序列使用。
    public static func make(theme: ThemeID) -> any SpectrumRenderer {
        switch theme {
        case .bars: BarsRenderer()
        case .radial: RadialRenderer()
        case .neon: NeonRenderer()
        case .led: LedRenderer()
        case .orbit: OrbitRenderer()
        case .hud: HUDRenderer()
        case .constellation: ConstellationRenderer()
        case .mobius: MobiusRenderer(analysis: false)
        case .analysis: MobiusRenderer(analysis: true)
        }
    }
}
