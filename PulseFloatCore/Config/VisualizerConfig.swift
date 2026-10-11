import Foundation

/// 頻譜主題識別碼；可跨執行緒傳遞。
public enum ThemeID: String, CaseIterable, Codable, Sendable {
    /// 經典直條。
    case bars
    /// 圓環放射。
    case radial
    /// 霓虹光暈。
    case neon
    /// 極簡點陣。
    case led
    /// 軌道：頻譜從發光的行星地平線升起（Pinterest 太空參考）。
    case orbit
    /// 儀表：太空船儀表與電路走線（Pinterest 太空參考）。
    case hud
    /// 星圖：頻段是星星，響亮的連成星座（Pinterest 太空參考）。
    case constellation
    /// 無限：3D 鰭片組成的 ∞ 雕塑（萊茵生命風格）。
    case mobius
    /// 解析：無限雕塑＋鏡頭運鏡、區段標註與字幕（萊茵生命宣傳片風格）。
    case analysis
}

/// 3D 雕塑（無限、解析）的色彩風格；可跨執行緒傳遞。
public enum SculptureStyle: String, CaseIterable, Codable, Sendable {
    /// 瓷白（萊茵生命預設）。
    case porcelain
    /// 石墨。
    case graphite
    /// 極光漸層。
    case aurora
    /// 櫻花。
    case sakura
    /// 琥珀金屬。
    case amber
    /// 翡翠。
    case jade
    /// 霓虹。
    case neon
    /// 跟隨目前配色。
    case palette
}

/// 漸層配色識別碼；可跨執行緒傳遞。
public enum PaletteID: String, CaseIterable, Codable, Sendable {
    /// 青藍紫極光配色。
    case aurora
    /// 黃橙紅暖色配色。
    case ember
    /// 冰藍配色。
    case glacier
    /// 單色配色。
    case mono
    /// 實驗室米白（萊茵生命風格）：米白 → 暖灰 → 萊姆黃。
    case lab
    /// 櫻花：淡粉 → 粉紅 → 紫。
    case sakura
    /// 夕陽：金黃 → 橘紅 → 紫。
    case sunset
    /// 抹茶：淡綠 → 薄荷 → 深綠。
    case matcha
    /// 新東京霓虹：青 → 洋紅 → 紫。
    case neotokyo
    /// 石墨：白 → 灰 → 深灰。
    case graphite
}

/// 視窗背景模式；可跨執行緒傳遞。
public enum WindowMode: String, CaseIterable, Codable, Sendable {
    /// 毛玻璃卡片背景。
    case card
    /// 透明背景。
    case bare
}

/// 選單列圖示樣式；可跨執行緒傳遞。
public enum MenuBarStyle: String, CaseIterable, Codable, Sendable {
    /// 直條頻譜。
    case bars
    /// 點陣頻譜。
    case dots
}

/// 與原型 JSON 相容的設定值；可跨執行緒傳遞，解碼不夾值，使用前可呼叫 clamped()。
public struct VisualizerConfig: Codable, Equatable, Sendable {
    /// 頻帶設定；值型別可跨執行緒傳遞。
    public struct Bands: Codable, Equatable, Sendable {
        /// 頻帶數量；clamped 後為 16...128 的 4 的倍數。
        public var count: Int
        /// 最低頻率（Hz），範圍 20...120。
        public var fMinHz: Double
        /// 最高頻率（Hz），範圍 6000...20000，且至少為最低頻率的 4 倍。
        public var fMaxHz: Double
        /// 以 1 kHz 為零點的高頻補償（dB/oct），範圍 0...6。
        public var tiltDbPerOct: Double

        /// 建立設定；參數單位與範圍同各屬性，預設值來自原型；不自動夾值。
        public init(
            count: Int = 64,
            fMinHz: Double = 30,
            fMaxHz: Double = 16000,
            tiltDbPerOct: Double = 3.0
        ) {
            self.count = count
            self.fMinHz = fMinHz
            self.fMaxHz = fMaxHz
            self.tiltDbPerOct = tiltDbPerOct
        }

        private enum CodingKeys: String, CodingKey {
            case count
            case fMinHz
            case fMaxHz
            case tiltDbPerOct
        }

        /// 解碼缺少、null 或型別不符的欄位時補預設值；未知 key 忽略，有效數值保留原值。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Bands()
            count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? defaults.count
            fMinHz = (try? container.decodeIfPresent(Double.self, forKey: .fMinHz)) ?? defaults.fMinHz
            fMaxHz = (try? container.decodeIfPresent(Double.self, forKey: .fMaxHz)) ?? defaults.fMaxHz
            tiltDbPerOct = (try? container.decodeIfPresent(Double.self, forKey: .tiltDbPerOct)) ?? defaults.tiltDbPerOct
        }
    }

    /// 音量正規化設定；值型別可跨執行緒傳遞。
    public struct Level: Codable, Equatable, Sendable {
        /// 是否啟用自動增益。
        public var agc: Bool
        /// 顯示動態範圍（dB），範圍 24...84。
        public var rangeDb: Double
        /// 關閉 AGC 時的固定上限（dB），範圍 -40...0。
        public var ceilingDb: Double
        /// AGC 上限回落速度（dB/s），範圍 1...20。
        public var agcReleaseDbPerSec: Double
        /// 正規化高度的對比指數（無單位），範圍 0.6...2.4。
        public var gamma: Double
        /// 未補償輸入的靜音閘值（dBFS），範圍 -160 ... -30。
        public var gateDb: Double

        /// 建立設定；參數單位與範圍同各屬性，預設值來自原型；不自動夾值。
        public init(
            agc: Bool = true,
            rangeDb: Double = 54,
            ceilingDb: Double = -12,
            agcReleaseDbPerSec: Double = 6,
            gamma: Double = 1.3,
            gateDb: Double = -90
        ) {
            self.agc = agc
            self.rangeDb = rangeDb
            self.ceilingDb = ceilingDb
            self.agcReleaseDbPerSec = agcReleaseDbPerSec
            self.gamma = gamma
            self.gateDb = gateDb
        }

        private enum CodingKeys: String, CodingKey {
            case agc
            case rangeDb
            case ceilingDb
            case agcReleaseDbPerSec
            case gamma
            case gateDb
        }

        /// 解碼缺少、null 或型別不符的欄位時補預設值；未知 key 忽略，有效數值保留原值。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Level()
            agc = (try? container.decodeIfPresent(Bool.self, forKey: .agc)) ?? defaults.agc
            rangeDb = (try? container.decodeIfPresent(Double.self, forKey: .rangeDb)) ?? defaults.rangeDb
            ceilingDb = (try? container.decodeIfPresent(Double.self, forKey: .ceilingDb)) ?? defaults.ceilingDb
            agcReleaseDbPerSec = (try? container.decodeIfPresent(Double.self, forKey: .agcReleaseDbPerSec)) ?? defaults.agcReleaseDbPerSec
            gamma = (try? container.decodeIfPresent(Double.self, forKey: .gamma)) ?? defaults.gamma
            gateDb = (try? container.decodeIfPresent(Double.self, forKey: .gateDb)) ?? defaults.gateDb
        }
    }

    /// 動態與平滑設定；值型別可跨執行緒傳遞。
    public struct Motion: Codable, Equatable, Sendable {
        /// 高度上升時間常數（ms），範圍 2...80。
        public var attackMs: Double
        /// 高度回落時間常數（ms），範圍 40...600。
        public var releaseMs: Double
        /// 相鄰頻帶平滑比例（無單位），範圍 0...0.8。
        public var spatial: Double
        /// 峰值停留時間（ms），範圍 0...600。
        public var peakHoldMs: Double
        /// 峰值下落加速度（正規化高度/s²），範圍 0.5...10。
        public var peakGravity: Double

        /// 建立設定；參數單位與範圍同各屬性，預設值來自原型；不自動夾值。
        public init(
            attackMs: Double = 12,
            releaseMs: Double = 140,
            spatial: Double = 0.35,
            peakHoldMs: Double = 160,
            peakGravity: Double = 3.2
        ) {
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.spatial = spatial
            self.peakHoldMs = peakHoldMs
            self.peakGravity = peakGravity
        }

        private enum CodingKeys: String, CodingKey {
            case attackMs
            case releaseMs
            case spatial
            case peakHoldMs
            case peakGravity
        }

        /// 解碼缺少、null 或型別不符的欄位時補預設值；未知 key 忽略，有效數值保留原值。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Motion()
            attackMs = (try? container.decodeIfPresent(Double.self, forKey: .attackMs)) ?? defaults.attackMs
            releaseMs = (try? container.decodeIfPresent(Double.self, forKey: .releaseMs)) ?? defaults.releaseMs
            spatial = (try? container.decodeIfPresent(Double.self, forKey: .spatial)) ?? defaults.spatial
            peakHoldMs = (try? container.decodeIfPresent(Double.self, forKey: .peakHoldMs)) ?? defaults.peakHoldMs
            peakGravity = (try? container.decodeIfPresent(Double.self, forKey: .peakGravity)) ?? defaults.peakGravity
        }
    }

    /// 外觀設定；值型別可跨執行緒傳遞。
    public struct Look: Codable, Equatable, Sendable {
        /// 頻譜主題，預設為直條。
        public var theme: ThemeID
        /// 三色漸層配色，預設為 aurora。
        public var palette: PaletteID
        /// 是否上下鏡像直條。
        public var mirror: Bool
        /// 是否顯示直條倒影。
        public var reflection: Bool
        /// 柱間距佔 pitch 的比例（無單位），範圍 0.05...0.6。
        public var barGap: Double
        /// 視窗背景樣式，預設為毛玻璃卡片。
        public var windowMode: WindowMode
        /// 視窗不透明度（無單位），範圍 0.3...1。
        public var opacity: Double
        /// 3D 雕塑主題（無限、解析）的色彩風格。
        public var sculptureStyle: SculptureStyle

        /// 建立設定；參數單位與範圍同各屬性，預設值來自原型；不自動夾值。
        public init(
            theme: ThemeID = .bars,
            palette: PaletteID = .aurora,
            mirror: Bool = false,
            reflection: Bool = true,
            barGap: Double = 0.28,
            windowMode: WindowMode = .card,
            opacity: Double = 1.0,
            sculptureStyle: SculptureStyle = .porcelain
        ) {
            self.theme = theme
            self.palette = palette
            self.mirror = mirror
            self.reflection = reflection
            self.barGap = barGap
            self.windowMode = windowMode
            self.opacity = opacity
            self.sculptureStyle = sculptureStyle
        }

        private enum CodingKeys: String, CodingKey {
            case theme
            case palette
            case mirror
            case reflection
            case barGap
            case windowMode
            case opacity
            case sculptureStyle
        }

        /// 解碼缺少、null 或型別不符的欄位時補預設值；未知 key 忽略，有效數值保留原值。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Look()
            let themeValue = (try? container.decodeIfPresent(String.self, forKey: .theme))
            theme = themeValue.flatMap(ThemeID.init(rawValue:)) ?? defaults.theme
            let paletteValue = (try? container.decodeIfPresent(String.self, forKey: .palette))
            palette = paletteValue.flatMap(PaletteID.init(rawValue:)) ?? defaults.palette
            mirror = (try? container.decodeIfPresent(Bool.self, forKey: .mirror)) ?? defaults.mirror
            reflection = (try? container.decodeIfPresent(Bool.self, forKey: .reflection)) ?? defaults.reflection
            barGap = (try? container.decodeIfPresent(Double.self, forKey: .barGap)) ?? defaults.barGap
            let windowModeValue = (try? container.decodeIfPresent(String.self, forKey: .windowMode))
            windowMode = windowModeValue.flatMap(WindowMode.init(rawValue:)) ?? defaults.windowMode
            opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? defaults.opacity
            let styleValue = (try? container.decodeIfPresent(String.self, forKey: .sculptureStyle))
            sculptureStyle = styleValue.flatMap(SculptureStyle.init(rawValue:)) ?? defaults.sculptureStyle
        }
    }

    /// 選單列設定；值型別可跨執行緒傳遞。
    public struct MenuBar: Codable, Equatable, Sendable {
        /// 選單列圖示樣式，預設為直條。
        public var style: MenuBarStyle
        /// 選單列柱數，範圍 5...9。
        public var count: Int
        /// 是否使用彩色；false 時使用單色 template image。
        public var colored: Bool

        /// 建立設定；參數單位與範圍同各屬性，預設值來自原型；不自動夾值。
        public init(
            style: MenuBarStyle = .bars,
            count: Int = 7,
            colored: Bool = false
        ) {
            self.style = style
            self.count = count
            self.colored = colored
        }

        private enum CodingKeys: String, CodingKey {
            case style
            case count
            case colored
        }

        /// 解碼缺少、null 或型別不符的欄位時補預設值；未知 key 忽略，有效數值保留原值。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = MenuBar()
            let styleValue = (try? container.decodeIfPresent(String.self, forKey: .style))
            style = styleValue.flatMap(MenuBarStyle.init(rawValue:)) ?? defaults.style
            count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? defaults.count
            colored = (try? container.decodeIfPresent(Bool.self, forKey: .colored)) ?? defaults.colored
        }
    }

    /// 頻帶設定；值型別可跨執行緒傳遞。
    public var bands: Bands
    /// 音量正規化設定；值型別可跨執行緒傳遞。
    public var level: Level
    /// 動態與平滑設定；值型別可跨執行緒傳遞。
    public var motion: Motion
    /// 外觀設定；值型別可跨執行緒傳遞。
    public var look: Look
    /// 選單列設定；值型別可跨執行緒傳遞。
    public var menubar: MenuBar

    /// 原型的完整預設設定，可於任意執行緒讀取。
    public static let `default` = VisualizerConfig()

    /// 建立完整設定；各群組預設為原型值，可於任意執行緒呼叫，不自動夾值。
    public init(
        bands: Bands = Bands(),
        level: Level = Level(),
        motion: Motion = Motion(),
        look: Look = Look(),
        menubar: MenuBar = MenuBar()
    ) {
        self.bands = bands
        self.level = level
        self.motion = motion
        self.look = look
        self.menubar = menubar
    }

    private enum CodingKeys: String, CodingKey {
        case bands
        case level
        case motion
        case look
        case menubar
    }

    /// 解碼部分 JSON；缺少、null 或型別不符的群組補預設值，忽略未知 key，不自動夾值。
    /// 頂層須為 JSON 物件；欄位錯誤只重置該欄位，未知列舉值採該欄位預設值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bands = (try? container.decodeIfPresent(Bands.self, forKey: .bands)) ?? Bands()
        level = (try? container.decodeIfPresent(Level.self, forKey: .level)) ?? Level()
        motion = (try? container.decodeIfPresent(Motion.self, forKey: .motion)) ?? Motion()
        look = (try? container.decodeIfPresent(Look.self, forKey: .look)) ?? Look()
        menubar = (try? container.decodeIfPresent(MenuBar.self, forKey: .menubar)) ?? MenuBar()
    }

    /// 回傳符合各欄位範圍的副本；NaN 使用預設值，無限值夾到端點，可於任意執行緒呼叫。
    public func clamped() -> VisualizerConfig {
        var result = self
        // 先以 Double 四捨五入再夾值，避免 Int 極值在加法或轉回 Int 時溢位。
        let roundedCount = (Double(bands.count) / 4).rounded(.toNearestOrAwayFromZero) * 4
        result.bands.count = Int(min(max(roundedCount, 16), 128))
        result.bands.fMinHz = Self.clamp(bands.fMinHz, to: 20...120, fallback: Self.default.bands.fMinHz)
        result.bands.fMaxHz = Self.clamp(bands.fMaxHz, to: 6000...20000, fallback: Self.default.bands.fMaxHz)
        result.bands.tiltDbPerOct = Self.clamp(bands.tiltDbPerOct, to: 0...6, fallback: Self.default.bands.tiltDbPerOct)
        result.level.rangeDb = Self.clamp(level.rangeDb, to: 24...84, fallback: Self.default.level.rangeDb)
        result.level.ceilingDb = Self.clamp(level.ceilingDb, to: -40...0, fallback: Self.default.level.ceilingDb)
        result.level.agcReleaseDbPerSec = Self.clamp(level.agcReleaseDbPerSec, to: 1...20, fallback: Self.default.level.agcReleaseDbPerSec)
        result.level.gamma = Self.clamp(level.gamma, to: 0.6...2.4, fallback: Self.default.level.gamma)
        result.level.gateDb = Self.clamp(level.gateDb, to: -160 ... -30, fallback: Self.default.level.gateDb)
        result.motion.attackMs = Self.clamp(motion.attackMs, to: 2...80, fallback: Self.default.motion.attackMs)
        result.motion.releaseMs = Self.clamp(motion.releaseMs, to: 40...600, fallback: Self.default.motion.releaseMs)
        result.motion.spatial = Self.clamp(motion.spatial, to: 0...0.8, fallback: Self.default.motion.spatial)
        result.motion.peakHoldMs = Self.clamp(motion.peakHoldMs, to: 0...600, fallback: Self.default.motion.peakHoldMs)
        result.motion.peakGravity = Self.clamp(motion.peakGravity, to: 0.5...10, fallback: Self.default.motion.peakGravity)
        result.look.barGap = Self.clamp(look.barGap, to: 0.05...0.6, fallback: Self.default.look.barGap)
        result.look.opacity = Self.clamp(look.opacity, to: 0.3...1, fallback: Self.default.look.opacity)
        result.menubar.count = min(max(menubar.count, 5), 9)
        result.bands.fMaxHz = max(result.bands.fMaxHz, result.bands.fMinHz * 4)
        return result
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
    }
}
