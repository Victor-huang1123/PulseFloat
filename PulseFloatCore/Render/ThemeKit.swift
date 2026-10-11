import CoreGraphics
import CoreText
import Foundation

/// 新主題（軌道、儀表、星圖、無限、解析）共用的小型 Core Graphics 工具。
/// 只在呼叫端的繪圖執行緒上同步使用；不保存狀態。
enum ThemeKit {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func color(_ c: RGB, _ alpha: Double) -> CGColor {
        CGColor(colorSpace: sRGB, components: [CGFloat(c.red) / 255, CGFloat(c.green) / 255, CGFloat(c.blue) / 255,
                                               CGFloat(min(1, max(0, alpha.isFinite ? alpha : 0)))])
            ?? CGColor(gray: 0, alpha: 0)
    }

    static func color(_ pair: (RGB, Double), alphaScale: Double = 1) -> CGColor { color(pair.0, pair.1 * alphaScale) }

    /// 往白色提亮 k（0...1）。
    static func lift(_ c: RGB, _ k: Double) -> RGB {
        RGB(red: Int((Double(c.red) + Double(255 - c.red) * k).rounded()),
            green: Int((Double(c.green) + Double(255 - c.green) * k).rounded()),
            blue: Int((Double(c.blue) + Double(255 - c.blue) * k).rounded()))
    }

    static func clamp01(_ v: Double) -> Double { v > 0 ? (v < 1 ? v : 1) : 0 }
    static func clamp01(_ v: Float) -> Double { clamp01(Double(v)) }

    static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// 沿單位方向 (c, s) 從半徑 r0（半寬 h0）到 r1（半寬 h1）的四邊形，加入目前路徑。
    static func addQuad(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, c: CGFloat, s: CGFloat,
                        r0: CGFloat, h0: CGFloat, r1: CGFloat, h1: CGFloat) {
        let nx = -s, ny = c
        ctx.move(to: CGPoint(x: cx + c * r0 + nx * h0, y: cy + s * r0 + ny * h0))
        ctx.addLine(to: CGPoint(x: cx + c * r1 + nx * h1, y: cy + s * r1 + ny * h1))
        ctx.addLine(to: CGPoint(x: cx + c * r1 - nx * h1, y: cy + s * r1 - ny * h1))
        ctx.addLine(to: CGPoint(x: cx + c * r0 - nx * h0, y: cy + s * r0 - ny * h0))
        ctx.closePath()
    }

    /// 以水平漸層描繪目前路徑（stroke → clip → gradient）。
    static func strokeCurrentPath(_ ctx: CGContext, width: CGFloat, colors: [CGColor], locations: [CGFloat],
                                  from x0: CGFloat, to x1: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations) else { return }
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
        ctx.restoreGState()
    }

    enum Align { case left, center, right }

    /// 每個 renderer 自己持有的 CTLine 快取（同一字串、字型、顏色只建立一次）；超過上限時整批清空。
    final class TextCache {
        fileprivate var lines: [String: (line: CTLine, halo: CTLine?, width: CGFloat)] = [:]
        init() {}
    }

    /// 在 y 向下的 context 畫一行字（y 是基線）。halo 不為 nil 時先畫一層外框，讓字在任何桌布上都讀得到。
    @discardableResult
    static func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     mono: Bool = true, bold: Bool = false, light: Bool = false,
                     color: CGColor, align: Align = .left, halo: CGColor? = nil, cache: TextCache? = nil) -> CGFloat {
        if let cache {
            let key = "\(string)|\(size)|\(mono)\(bold)\(light)|\(color.components ?? [])|\(halo?.components ?? [])"
            let entry: (line: CTLine, halo: CTLine?, width: CGFloat)
            if let hit = cache.lines[key] {
                entry = hit
            } else {
                let made = makeLines(string, size: size, mono: mono, bold: bold, light: light, color: color, halo: halo)
                if cache.lines.count > 256 { cache.lines.removeAll(keepingCapacity: true) }
                cache.lines[key] = made
                entry = made
            }
            let originX = align == .left ? x : (align == .center ? x - entry.width / 2 : x - entry.width)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if let haloLine = entry.halo { ctx.textPosition = CGPoint(x: originX, y: y); CTLineDraw(haloLine, ctx) }
            ctx.textPosition = CGPoint(x: originX, y: y)
            CTLineDraw(entry.line, ctx)
            ctx.restoreGState()
            return entry.width
        }
        let font = makeFont(size: size, mono: mono, bold: bold, light: light)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let originX: CGFloat
        switch align {
        case .left: originX = x
        case .center: originX = x - width / 2
        case .right: originX = x - width
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if let halo {
            let haloAttributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): halo,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): NSNumber(value: 6),
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): halo,
            ]
            let haloLine = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: haloAttributes))
            ctx.textPosition = CGPoint(x: originX, y: y)
            CTLineDraw(haloLine, ctx)
        }
        ctx.textPosition = CGPoint(x: originX, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return width
    }

    private static func makeLines(_ string: String, size: CGFloat, mono: Bool, bold: Bool, light: Bool,
                                  color: CGColor, halo: CGColor?) -> (line: CTLine, halo: CTLine?, width: CGFloat) {
        let font = makeFont(size: size, mono: mono, bold: bold, light: light)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [fontKey: font, colorKey: color]))
        var haloLine: CTLine?
        if let halo {
            haloLine = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                fontKey: font, colorKey: halo,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): NSNumber(value: 6),
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): halo,
            ]))
        }
        return (line, haloLine, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    static func textWidth(_ string: String, size: CGFloat, mono: Bool = true, bold: Bool = false, light: Bool = false) -> CGFloat {
        let font = makeFont(size: size, mono: mono, bold: bold, light: light)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func makeFont(size: CGFloat, mono: Bool, bold: Bool, light: Bool) -> CTFont {
        let base: CTFont
        if mono {
            base = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        }
        if mono && bold {
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        }
        if light && !mono {
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontTraitsAttribute: [kCTFontWeightTrait: NSNumber(value: -0.4)],
                kCTFontFamilyNameAttribute: CTFontCopyFamilyName(base),
            ] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return base
    }
}
