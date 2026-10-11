import CoreGraphics
import PulseFloatCore
import SceneKit
import simd

/// 一種雕塑色彩風格在 3D 場景裡的材質資料（由 `SculptureStyleColors` 推導，三個主題共用）。
public struct SceneLook: Sendable {
    /// 主體顏色沿 0...1（低頻 → 高頻）的取樣。
    public let base: [RGB]
    /// 發光／強調色（起音、熱點）。
    public let accent: RGB
    /// 起音脈衝經過時混入的顏色。
    public let pulse: RGB
    /// 第二組光色：配色的三個點（給光暈、粒子、等高線用）。
    public let glow: [RGB]
    public let roughness: Double
    public let metalness: Double
    /// 這個風格偏亮（白瓷、櫻花）：在淺色桌布上需要較深的描邊或陰影。
    public let isLight: Bool

    /// 位置 t（0...1）的主體顏色。
    public func baseColor(at t: Double) -> RGB {
        let x = (t.isFinite ? min(1, max(0, t)) : 0.5) * Double(base.count - 1)
        let i = min(base.count - 2, Int(x))
        return SculptureStyleColors.mix(base[i], base[i + 1], x - Double(i))
    }

    /// 位置 t（0...1）的光色。
    public func glowColor(at t: Double) -> RGB {
        let x = (t.isFinite ? min(1, max(0, t)) : 0.5) * Double(glow.count - 1)
        let i = min(glow.count - 2, Int(x))
        return SculptureStyleColors.mix(glow[i], glow[i + 1], x - Double(i))
    }
}

/// 色彩轉換與 PBR 材質工具。
public enum SceneMaterials {
    /// 由風格與配色推導 3D 材質資料。
    public static func look(style: SculptureStyle, palette: PaletteID) -> SceneLook {
        let colors = SculptureStyleColors.of(style)
        let paletteColors = Palette(palette)
        var base: [RGB] = []
        var i = 0
        while i < 5 { base.append(colors.baseColor(at: Double(i) / 4, palette: palette)); i += 1 }
        let glow: [RGB]
        switch colors.fill {
        case let .gradient(a, b, c), let .glow(_, a, b, c, _):
            glow = [a, b, c]
        case .solid, .palette:
            glow = [paletteColors.color(at: 0), paletteColors.color(at: 0.5), paletteColors.color(at: 1)]
        }
        let middle = colors.baseColor(at: 0.5, palette: palette)
        let luminance = 0.2126 * Double(middle.red) + 0.7152 * Double(middle.green) + 0.0722 * Double(middle.blue)
        return SceneLook(base: base, accent: colors.accent, pulse: colors.pulse, glow: glow,
                         roughness: colors.roughness, metalness: colors.metalness, isLight: luminance > 170)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// sRGB 的 CGColor（SceneKit 會自行轉成線性）。
    public static func color(_ c: RGB, _ alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [CGFloat(c.red) / 255, CGFloat(c.green) / 255, CGFloat(c.blue) / 255,
                                               CGFloat(min(1, max(0, alpha)))]) ?? CGColor(gray: 0, alpha: 1)
    }

    /// shader uniform 用的線性 RGB（0...1）。
    public static func linear(_ c: RGB) -> SIMD3<Float> {
        func channel(_ v: Int) -> Float {
            let s = Float(min(255, max(0, v))) / 255
            return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(c.red), channel(c.green), channel(c.blue))
    }

    /// shader uniform 用的 SCNVector3（線性 RGB）。
    public static func vector(_ c: RGB, scale: Float = 1) -> SCNVector3 {
        let v = linear(c) * scale
        return SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
    }

    /// physically based 材質。
    public static func pbr(base: RGB, metalness: Double, roughness: Double, emission: RGB? = nil, emissionIntensity: Double = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color(base)
        material.metalness.contents = NSNumber(value: min(1, max(0, metalness)))
        material.roughness.contents = NSNumber(value: min(1, max(0.04, roughness)))
        if let emission {
            material.emission.contents = color(emission)
            material.emission.intensity = CGFloat(emissionIntensity)
        }
        return material
    }

    /// 不受光照、只發光的材質（光環、粒子、線條）；blendMode 預設加法。
    public static func unlit(_ c: RGB, alpha: Double = 1, additive: Bool = true) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color(c, alpha)
        material.blendMode = additive ? .add : .alpha
        material.writesToDepthBuffer = !additive
        material.isDoubleSided = true
        return material
    }

    /// 程式產生的攝影棚環境貼圖（等距長方投影 256×128）：上方柔光箱、左右兩條輪廓光、深色地面。
    /// 給 PBR 材質反射用；不當作背景顯示。
    public static func studioEnvironment(warmth: Double = 0) -> CGImage? {
        let width = 256, height = 128
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let row = context.bytesPerRow
        let warm = min(1, max(0, warmth))
        var y = 0
        while y < height {
            let v = Double(y) / Double(height - 1) // 0 = 天頂（CGContext 記憶體第一列在上）
            var x = 0
            while x < width {
                let u = Double(x) / Double(width)
                var l = 0.04 + 0.10 * max(0, 1 - v * 1.6)                      // 天空漸層
                l += 1.6 * exp(-pow((v - 0.18) / 0.07, 2)) * exp(-pow((u - 0.5) / 0.09, 2))   // 頂光柔光箱
                l += 0.9 * exp(-pow((v - 0.42) / 0.16, 2)) * exp(-pow((u - 0.17) / 0.025, 2)) // 左輪廓光
                l += 0.7 * exp(-pow((v - 0.42) / 0.16, 2)) * exp(-pow((u - 0.83) / 0.025, 2)) // 右輪廓光
                if v > 0.55 { l = 0.02 + 0.03 * (1 - v) }                    // 地面
                let tone = min(1, l)
                let r = tone * (1 + 0.06 * warm), g = tone, b = tone * (1 - 0.06 * warm) + 0.01
                let p = pixels + y * row + x * 4
                p[0] = UInt8(min(255, max(0, (r * 255).rounded())))
                p[1] = UInt8(min(255, max(0, (g * 255).rounded())))
                p[2] = UInt8(min(255, max(0, (b * 255).rounded())))
                p[3] = 255
                x += 1
            }
            y += 1
        }
        return context.makeImage()
    }
}
