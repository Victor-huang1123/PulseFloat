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
    /// 距離上一幀的秒數（0...0.05）；需要時間的主題（衛星、脈衝、鏡頭）用它前進，靜音時不得產生動作。
    public var dt: Double
    /// 3D 雕塑主題的色彩風格（2D 備援與縮圖也用它上色）。
    public var sculptureStyle: SculptureStyle
    /// 圓環中央要顯示的圖片（正在播放的封面或出聲 App 的圖示）；nil 時畫面與沒有這個功能時完全相同。
    /// 目前只有圓環放射使用，其他主題忽略。
    public var artwork: CenterArtwork?

    /// 建立繪圖選項，不改變輸入；呼叫端須提供有限的正 scale 與 0...1 的 fade。
    public init(isThumbnail: Bool = false, fade: Double, scale: CGFloat = 1, dt: Double = 1.0 / 60,
                sculptureStyle: SculptureStyle = .porcelain, artwork: CenterArtwork? = nil) {
        self.isThumbnail = isThumbnail
        self.fade = fade
        self.scale = scale
        self.dt = dt
        self.sculptureStyle = sculptureStyle
        self.artwork = artwork
    }
}

/// 圓環中央的圖片；建立後不可變，可跨執行緒傳遞。相等只比較 id 與 kind（圖片內容不比較）。
public struct CenterArtwork: @unchecked Sendable, Equatable {
    // @unchecked：CGImage 建立後不可變，Core Graphics 保證可在多執行緒讀取。

    /// 圖片種類：封面會裁成圓形；App 圖示保留原本形狀。
    public enum Kind: Sendable, Equatable {
        /// 歌曲封面或影片縮圖（建議已裁成正方形）。
        case cover
        /// 出聲 App 的圖示（透明背景）。
        case appIcon
    }

    /// 識別目前內容的字串（例如 App＋歌名＋歌手）；id 改變時繪圖器會交叉淡入新圖。
    public let id: String
    /// 要畫的圖片；任何像素尺寸皆可，建議不超過 256×256。
    public let image: CGImage
    /// 圖片種類，決定裁切方式。
    public let kind: Kind

    /// 建立中央圖片，不複製或修改 image。
    public init(id: String, image: CGImage, kind: Kind) {
        self.id = id
        self.image = image
        self.kind = kind
    }

    /// 只比較 id 與 kind；同一首歌換成不同 CGImage 實例仍視為相同，不會觸發交叉淡入。
    public static func == (lhs: CenterArtwork, rhs: CenterArtwork) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}
