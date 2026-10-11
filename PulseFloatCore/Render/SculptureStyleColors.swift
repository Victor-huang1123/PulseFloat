import CoreGraphics

/// 3D 雕塑（無限／解析）每種色彩風格的完整色彩資料：鰭片顏色、脈衝顏色、材質，以及 HUD 文字與標籤顏色。
/// 數值來自 docs/design/concepts/concept-mobius.js 的 STYLES。不可變值型別，可跨執行緒傳遞。
public struct SculptureStyleColors: Sendable {
    /// 鰭片沿著頻率位置 0...1 的顏色來源。
    public enum Fill: Sendable {
        /// 單一顏色。
        case solid(RGB)
        /// 三色漸層（低頻 → 中頻 → 高頻）。
        case gradient(RGB, RGB, RGB)
        /// 深色底色混入三色光暈（mix 為光暈比例 0...1）。
        case glow(base: RGB, RGB, RGB, RGB, mix: Double)
        /// 跟隨目前的 `PaletteID`，與米白 25% 混合。
        case palette
    }

    public let fill: Fill
    /// 重低音脈衝經過時鰭片混入的顏色。
    public let pulse: RGB
    /// 材質粗糙度 0...1（SceneKit physically based）。
    public let roughness: Double
    /// 材質金屬度 0...1。
    public let metalness: Double
    /// HUD 主文字色（含 alpha）。
    public let ink: (RGB, Double)
    /// HUD 次要文字／引線顏色（含 alpha）。
    public let soft: (RGB, Double)
    /// 強調色（拍點、錨點）。
    public let accent: RGB
    /// 黑色小標籤的底色與字色。
    public let tagBackground: (RGB, Double)
    public let tagForeground: RGB
    /// 文字外框（讓文字在任何桌布上都看得到）。
    public let halo: (RGB, Double)

    private static let cream = RGB(red: 242, green: 238, blue: 228)
    private static let lime = RGB(red: 226, green: 240, blue: 150)

    /// 取得指定風格的色彩資料。
    public static func of(_ style: SculptureStyle) -> SculptureStyleColors {
        switch style {
        case .porcelain:
            return .init(fill: .solid(cream), pulse: lime, roughness: 0.58, metalness: 0.04,
                         ink: (RGB(red: 28, green: 26, blue: 24), 0.88), soft: (RGB(red: 28, green: 26, blue: 24), 0.5),
                         accent: RGB(red: 255, green: 138, blue: 31), tagBackground: (RGB(red: 20, green: 18, blue: 16), 0.92),
                         tagForeground: RGB(red: 244, green: 241, blue: 234), halo: (RGB(red: 250, green: 248, blue: 244), 0.55))
        case .graphite:
            return .init(fill: .solid(RGB(red: 44, green: 44, blue: 48)), pulse: lime, roughness: 0.38, metalness: 0.35,
                         ink: (RGB(red: 236, green: 234, blue: 228), 0.92), soft: (RGB(red: 236, green: 234, blue: 228), 0.55),
                         accent: lime, tagBackground: (RGB(red: 236, green: 234, blue: 228), 0.9),
                         tagForeground: RGB(red: 26, green: 26, blue: 28), halo: (RGB(red: 10, green: 10, blue: 12), 0.5))
        case .aurora:
            return .init(fill: .gradient(RGB(red: 33, green: 230, blue: 193), RGB(red: 58, green: 155, blue: 255), RGB(red: 163, green: 92, blue: 255)),
                         pulse: RGB(red: 255, green: 255, blue: 255), roughness: 0.35, metalness: 0.2,
                         ink: (RGB(red: 235, green: 245, blue: 255), 0.92), soft: (RGB(red: 200, green: 225, blue: 255), 0.6),
                         accent: RGB(red: 33, green: 230, blue: 193), tagBackground: (RGB(red: 33, green: 230, blue: 193), 0.9),
                         tagForeground: RGB(red: 4, green: 18, blue: 26), halo: (RGB(red: 4, green: 10, blue: 24), 0.5))
        case .sakura:
            return .init(fill: .gradient(RGB(red: 255, green: 227, blue: 236), RGB(red: 255, green: 179, blue: 200), RGB(red: 247, green: 198, blue: 224)),
                         pulse: RGB(red: 255, green: 110, blue: 160), roughness: 0.55, metalness: 0.02,
                         ink: (RGB(red: 110, green: 32, blue: 64), 0.9), soft: (RGB(red: 110, green: 32, blue: 64), 0.55),
                         accent: RGB(red: 255, green: 93, blue: 143), tagBackground: (RGB(red: 110, green: 32, blue: 64), 0.92),
                         tagForeground: RGB(red: 255, green: 233, blue: 240), halo: (RGB(red: 255, green: 245, blue: 248), 0.6))
        case .amber:
            return .init(fill: .gradient(RGB(red: 255, green: 217, blue: 138), RGB(red: 242, green: 165, blue: 65), RGB(red: 200, green: 116, blue: 43)),
                         pulse: RGB(red: 255, green: 244, blue: 214), roughness: 0.32, metalness: 0.55,
                         ink: (RGB(red: 64, green: 34, blue: 10), 0.9), soft: (RGB(red: 64, green: 34, blue: 10), 0.55),
                         accent: RGB(red: 255, green: 138, blue: 31), tagBackground: (RGB(red: 64, green: 34, blue: 10), 0.92),
                         tagForeground: RGB(red: 255, green: 243, blue: 220), halo: (RGB(red: 255, green: 248, blue: 236), 0.55))
        case .jade:
            return .init(fill: .gradient(RGB(red: 216, green: 243, blue: 220), RGB(red: 116, green: 198, blue: 157), RGB(red: 45, green: 106, blue: 79)),
                         pulse: RGB(red: 240, green: 255, blue: 200), roughness: 0.3, metalness: 0.1,
                         ink: (RGB(red: 16, green: 52, blue: 36), 0.9), soft: (RGB(red: 16, green: 52, blue: 36), 0.55),
                         accent: RGB(red: 82, green: 183, blue: 136), tagBackground: (RGB(red: 16, green: 52, blue: 36), 0.92),
                         tagForeground: RGB(red: 233, green: 247, blue: 238), halo: (RGB(red: 240, green: 250, blue: 244), 0.55))
        case .neon:
            return .init(fill: .glow(base: RGB(red: 22, green: 22, blue: 30), RGB(red: 0, green: 245, blue: 212), RGB(red: 241, green: 91, blue: 181), RGB(red: 155, green: 93, blue: 229), mix: 0.55),
                         pulse: RGB(red: 255, green: 255, blue: 255), roughness: 0.4, metalness: 0.3,
                         ink: (RGB(red: 240, green: 240, blue: 255), 0.92), soft: (RGB(red: 200, green: 200, blue: 255), 0.6),
                         accent: RGB(red: 241, green: 91, blue: 181), tagBackground: (RGB(red: 241, green: 91, blue: 181), 0.92),
                         tagForeground: RGB(red: 18, green: 8, blue: 24), halo: (RGB(red: 6, green: 4, blue: 14), 0.55))
        case .palette:
            return .init(fill: .palette, pulse: lime, roughness: 0.45, metalness: 0.1,
                         ink: (RGB(red: 235, green: 245, blue: 255), 0.92), soft: (RGB(red: 200, green: 225, blue: 255), 0.6),
                         accent: RGB(red: 255, green: 138, blue: 31), tagBackground: (RGB(red: 235, green: 245, blue: 255), 0.9),
                         tagForeground: RGB(red: 11, green: 13, blue: 20), halo: (RGB(red: 4, green: 10, blue: 24), 0.5))
        }
    }

    /// 頻率位置 position（0 低頻 … 1 高頻）的鰭片基本色。
    public func baseColor(at position: Double, palette: PaletteID) -> RGB {
        let t = position.isFinite ? min(1, max(0, position)) : 0.5
        switch fill {
        case let .solid(color):
            return color
        case let .gradient(a, b, c):
            return Self.mix3(a, b, c, t)
        case let .glow(base, a, b, c, mix):
            return Self.mix(base, Self.mix3(a, b, c, t), mix)
        case .palette:
            return Self.mix(Palette(palette).color(at: t), Self.cream, 0.25)
        }
    }

    /// a → b 的線性混合（amount 0...1），各通道四捨五入。
    public static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        let k = min(1, max(0, amount))
        return RGB(red: Int((Double(a.red) + Double(b.red - a.red) * k).rounded()),
                   green: Int((Double(a.green) + Double(b.green - a.green) * k).rounded()),
                   blue: Int((Double(a.blue) + Double(b.blue - a.blue) * k).rounded()))
    }

    private static func mix3(_ a: RGB, _ b: RGB, _ c: RGB, _ t: Double) -> RGB {
        t < 0.5 ? mix(a, b, t * 2) : mix(b, c, (t - 0.5) * 2)
    }
}
