import CoreGraphics

/// sRGB 整數色彩；每個通道為 0...255，可跨執行緒傳遞。
public struct RGB: Equatable, Sendable {
    /// 紅色通道，範圍 0...255。
    public let red: Int
    /// 綠色通道，範圍 0...255。
    public let green: Int
    /// 藍色通道，範圍 0...255。
    public let blue: Int

    /// 建立 sRGB 色彩；超出 0...255 的通道會夾住，可於任意執行緒呼叫。
    public init(red: Int, green: Int, blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }

    /// 轉成 sRGB CGColor；alpha 夾在 0...1，NaN 視為 0，可於任意執行緒呼叫。
    public func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha.isNaN ? 0 : min(1, max(0, alpha))
        )
    }
}

/// 原型定義的三色 sRGB 漸層；不可變值型別，可跨執行緒傳遞。
public struct Palette: Sendable {
    private let first: RGB
    private let middle: RGB
    private let last: RGB

    /// 建立指定的三色漸層，可於任意執行緒呼叫。
    public init(_ id: PaletteID) {
        switch id {
        case .aurora:
            first = RGB(red: 33, green: 230, blue: 193)
            middle = RGB(red: 58, green: 155, blue: 255)
            last = RGB(red: 163, green: 92, blue: 255)
        case .ember:
            first = RGB(red: 255, green: 210, blue: 63)
            middle = RGB(red: 255, green: 107, blue: 53)
            last = RGB(red: 255, green: 45, blue: 135)
        case .glacier:
            first = RGB(red: 234, green: 247, blue: 255)
            middle = RGB(red: 143, green: 211, blue: 255)
            last = RGB(red: 76, green: 111, blue: 255)
        case .mono:
            first = RGB(red: 255, green: 255, blue: 255)
            middle = RGB(red: 213, green: 218, blue: 229)
            last = RGB(red: 152, green: 161, blue: 180)
        }
    }

    /// 取 0...1 位置的兩段線性內插，通道四捨五入至整數；超出夾住，NaN 視為 0。
    public func color(at t: Double) -> RGB {
        let position = (t.isNaN ? 0 : min(1, max(0, t))) * 2
        let start = position < 1 ? first : middle
        let end = position < 1 ? middle : last
        let fraction = position < 1 ? position : position - 1
        return RGB(
            red: Int((Double(start.red) + Double(end.red - start.red) * fraction).rounded()),
            green: Int((Double(start.green) + Double(end.green - start.green) * fraction).rounded()),
            blue: Int((Double(start.blue) + Double(end.blue - start.blue) * fraction).rounded())
        )
    }
}

/// 每個 renderer 私有持有的配色快取；不可同時從多個執行緒使用。
final class RenderPaletteCache {
    private var paletteID: PaletteID?
    private var colors: [RGB] = []

    func colors(for id: PaletteID, count: Int) -> [RGB] {
        if paletteID != id || colors.count != count {
            let palette = Palette(id)
            colors.removeAll(keepingCapacity: true)
            colors.reserveCapacity(count)
            var index = 0
            while index < count {
                colors.append(palette.color(at: count > 1 ? Double(index) / Double(count - 1) : 0))
                index += 1
            }
            paletteID = id
        }
        return colors
    }
}
