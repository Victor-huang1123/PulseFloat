import PulseFloatCore
import SceneKit

/// 地形在某個雕塑風格與外觀下的顏色與材質參數（顯示空間 sRGB 0...1，直接交給 shader）。
///
/// 兩個家族：
/// - 亮色風格（白瓷、櫻花、琥珀、翡翠）：像白色建築模型——淺色半透明填色、深色墨線、強調色的峰頂與鼓點。
/// - 深色風格（石墨、極光、霓虹、配色）：深色玻璃般的填色、發光的彩色線，鼓點用脈衝色。
/// 兩者都有 alpha 覆蓋的填色，所以在淺色與深色桌布上都看得清楚。
struct TerrainPalette {
    var fillLow = SIMD4<Float>(0, 0, 0, 0.6)
    var fillHigh = SIMD4<Float>(0, 0, 0, 0.4)
    var fillHot = SIMD4<Float>(0, 0, 0, 0)
    var line = SIMD4<Float>(1, 1, 1, 1)
    var lineHot = SIMD4<Float>(1, 1, 1, 0.4)
    var beat = SIMD4<Float>(1, 1, 1, 1)
    /// (ambient, key, fill, specular)
    var lighting = SIMD4<Float>(0.4, 0.6, 0.15, 0.3)
    var shininess: Float = 40
    var fresnel: Float = 0.3
    /// 切面：剖面色、台座色、輪廓線色、峰頂輪廓線色、地層線 alpha。
    var face = SIMD3<Float>(0.5, 0.5, 0.5)
    var faceLow = SIMD3<Float>(0.4, 0.4, 0.4)
    var rim = SIMD3<Float>(1, 1, 1)
    var rimHot = SIMD3<Float>(1, 1, 1)
    var strataAlpha: Float = 0.15
    var groundAlpha: Float = 0.5
    /// 景深最遠處剩下的不透明度。
    var fogFar: Float = 0.25

    static func make(style: SculptureStyle, look: SceneLook, surface: TerrainSurface) -> TerrainPalette {
        let colors = SculptureStyleColors.of(style)
        var p = TerrainPalette()
        let black = RGB(red: 8, green: 9, blue: 13)
        let white = RGB(red: 255, green: 255, blue: 255)
        let ink = colors.ink.0
        let isSurface = surface == .surface
        if look.isLight {
            let low = SculptureStyleColors.mix(look.baseColor(at: 0.1), white, 0.3)
            let high = look.baseColor(at: 0.9)
            p.fillLow = v4(low, isSurface ? 0.9 : 0.94)
            p.fillHigh = v4(high, isSurface ? 0.7 : 0.72)
            p.fillHot = v4(SculptureStyleColors.mix(high, colors.accent, 0.55), isSurface ? 0.55 : 0.35)
            p.line = v4(ink, 0.92)
            p.lineHot = v4(SculptureStyleColors.mix(ink, colors.accent, 0.75), 0.26)
            p.beat = v4(colors.accent, isSurface ? 0.55 : 1)
            p.lighting = SIMD4(0.4, 0.58, 0.12, isSurface ? 0.14 : 0.06)
            p.shininess = isSurface ? 90 : 30
            p.fresnel = isSurface ? 0.4 : 0.25
            p.face = v3(SculptureStyleColors.mix(look.baseColor(at: 0.5), white, 0.15))
            p.faceLow = v3(SculptureStyleColors.mix(look.baseColor(at: 0.5), ink, 0.16))
            p.rim = v3(ink)
            p.rimHot = v3(SculptureStyleColors.mix(ink, colors.accent, 0.8))
            p.strataAlpha = 0.16
            p.groundAlpha = 0.55
            p.fogFar = 0.3
        } else {
            let (glowLow, glowHigh) = ramp(colors: colors, look: look)
            let mid = look.baseColor(at: 0.5)
            let solid: Bool
            if case .solid = colors.fill { solid = true } else { solid = false }
            if isSurface {
                if solid {
                    // 石墨：深灰金屬面，只有峰頂帶強調色
                    p.fillLow = v4(SculptureStyleColors.mix(mid, black, 0.3), 0.86)
                    p.fillHigh = v4(SculptureStyleColors.mix(ink, mid, 0.55), 0.66)
                    p.fillHot = v4(SculptureStyleColors.mix(colors.accent, ink, 0.3), 0.22)
                } else {
                    p.fillLow = v4(SculptureStyleColors.mix(glowLow, black, 0.72), 0.84)
                    p.fillHigh = v4(SculptureStyleColors.mix(glowHigh, black, 0.25), 0.62)
                    p.fillHot = v4(SculptureStyleColors.mix(glowHigh, white, 0.25), 0.5)
                }
            } else {
                p.fillLow = v4(SculptureStyleColors.mix(mid, black, 0.86), 0.74)
                p.fillHigh = v4(SculptureStyleColors.mix(glowHigh, black, 0.8), 0.5)
                p.fillHot = v4(SculptureStyleColors.mix(glowHigh, black, 0.6), 0.4)
            }
            p.line = v4(glowLow, 1)
            p.lineHot = v4(glowHigh, 0.3)
            p.beat = v4(colors.pulse, isSurface ? 0.45 : 1)
            p.lighting = SIMD4(0.4, 0.66, 0.18, isSurface ? 0.32 : 0.2)
            p.shininess = isSurface ? 90 : 40
            p.fresnel = isSurface ? 0.55 : 0.3
            p.face = v3(SculptureStyleColors.mix(mid, black, 0.7))
            p.faceLow = v3(SculptureStyleColors.mix(mid, black, 0.84))
            p.rim = v3(glowLow)
            p.rimHot = v3(glowHigh)
            p.strataAlpha = 0.26
            p.groundAlpha = 0.6
            p.fogFar = 0.22
        }
        return p
    }

    /// 深色家族的線色（谷 → 峰）：漸層風格用它的光色兩端；光暈風格（霓虹）用青 → 洋紅；
    /// 單色風格（石墨）用墨色 → 強調色；配色風格用配色。
    private static func ramp(colors: SculptureStyleColors, look: SceneLook) -> (RGB, RGB) {
        switch colors.fill {
        case .solid:
            return (colors.ink.0, colors.accent)
        case .glow:
            return (look.glowColor(at: 0), look.glowColor(at: 0.5))
        case .gradient, .palette:
            return (look.glowColor(at: 0.1), look.glowColor(at: 0.95))
        }
    }

    static func v3(_ c: RGB) -> SIMD3<Float> {
        SIMD3(Float(c.red) / 255, Float(c.green) / 255, Float(c.blue) / 255)
    }

    static func v4(_ c: RGB, _ w: Float) -> SIMD4<Float> {
        SIMD4(Float(c.red) / 255, Float(c.green) / 255, Float(c.blue) / 255, w)
    }
}
