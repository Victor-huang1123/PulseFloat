import PulseFloatCore
import SceneKit

/// SceneKit 主題的外觀設定；設定改變時宿主才會呼叫 `SceneTheme.apply(_:)`。
public struct SceneSettings: Equatable, Sendable {
    /// 雕塑色彩風格（材質與主色）。
    public var style: SculptureStyle
    /// 三色配色（風格為 `.palette` 或需要第二組顏色時使用）。
    public var palette: PaletteID
    /// 精簡（填滿浮動條）或雕塑（台座、陰影、環繞鏡頭）。
    public var presentation: ScenePresentation
    /// 畫質：粒子數、網格密度、反鋸齒與後製。
    public var quality: RenderQuality
    /// 視窗寬高比（浮動條固定約 2.6）。
    public var aspect: Double
    /// 音訊地形：線框或半透明曲面（其他主題忽略）。
    public var terrainSurface: TerrainSurface

    public init(style: SculptureStyle = .porcelain, palette: PaletteID = .aurora,
                presentation: ScenePresentation = .compact, quality: RenderQuality = .medium, aspect: Double = 2.6,
                terrainSurface: TerrainSurface = .wireframe) {
        self.style = style
        self.palette = palette
        self.presentation = presentation
        self.quality = quality
        self.aspect = aspect.isFinite && aspect > 0.2 ? min(8, aspect) : 2.6
        self.terrainSurface = terrainSurface
    }

    public init(look: VisualizerConfig.Look, aspect: Double) {
        self.init(style: look.sculptureStyle, palette: look.palette, presentation: look.presentation,
                  quality: look.quality, aspect: aspect, terrainSurface: look.terrainSurface)
    }
}

/// 一個 SceneKit 主題。全部在主執行緒使用。
///
/// 規則（三個主題共同遵守）：
/// - 動畫只能由 `frame`（values / peaks / features）和 `dt` 推動；旋轉、流動一律用 `frame.features.time`
///   （音訊時鐘，靜音時停止），不能用牆上時間或 SceneKit 的 `u_time`／actions／粒子系統。
/// - 靜音（`features.isSilent`）且內部狀態都回到靜止後，畫面必須逐像素不變，並回報 `isAtRest == true`。
/// - 每幀 CPU 工作要小（目標 < 2 ms，含 SceneKit encode）：重的運算放在 shader modifier，CPU 只更新少量 uniform。
/// - 背景透明：不要設定 `scene.background`；需要光暈時用 emission + 相機 bloom（只寫入 RGB，是加法光）。
///   視窗以 premultiplied alpha 疊在桌布上：純加法光在淺色桌布上會消失，所以主體需要有 alpha 的部分
///   （深色核心、半透明面、細描邊），在深色與淺色桌布上都要清楚。
/// - 不要用 SCNParticleSystem、SCNAction、SCNAnimation 或 SCNTransaction 動畫（它們跟著 SceneKit 時間走，靜音時不會停）。
@MainActor
public protocol SceneTheme: AnyObject {
    /// 共用舞台（相機、燈光、台座）；宿主透過它套用使用者的鏡頭操作。
    var stage: SceneStage { get }
    /// 要繪製的場景（通常是 `stage.scene`）。
    var scene: SCNScene { get }
    /// 目前的相機節點（通常是 `stage.cameraNode`）。
    var pointOfView: SCNNode { get }
    /// 套用設定；可以重建幾何與材質。第一次 `update` 之前一定會先呼叫一次。
    func apply(_ settings: SceneSettings)
    /// 前進一幀（dt 秒，0...0.05）。
    func update(frame: SpectrumFrame, dt: Double)
    /// 上一次 `update` 之後畫面已完全靜止（宿主可以停止重繪）。
    var isAtRest: Bool { get }
    /// 正在播放的封面（nil 表示不顯示）；只有中央適合放圖的主題（黑洞）會用，其他主題忽略。
    func setArtwork(_ image: CGImage?)
}

extension SceneTheme {
    public func setArtwork(_ image: CGImage?) {}
}

/// 依主題建立 SceneKit 主題；不是 SceneKit 主題時回傳 nil。
@MainActor
public enum SceneThemeFactory {
    public static func make(_ theme: ThemeID) -> (any SceneTheme)? {
        switch theme {
        case .blackHole: BlackHoleTheme()
        case .particleSphere: ParticleSphereTheme()
        case .terrain: TerrainTheme()
        default: nil
        }
    }
}
