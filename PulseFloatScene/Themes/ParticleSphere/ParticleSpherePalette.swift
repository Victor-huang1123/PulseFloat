import PulseFloatCore

/// 粒子球在一種雕塑風格下的顏色配方。
/// 每顆粒子同時有「本體色」（premultiplied 的遮蓋部分，讓淺色桌布上看得到）與「光色」（加法光，深色桌布上發亮）。
/// 本體色一律壓到中深色調（亮度 ≤ 約 105），所以淺色風格在淺色桌布上仍有清楚的輪廓。
struct ParticleSpherePalette: Equatable {
    /// 光色漸層（低 → 高，sRGB）。
    var glow: [RGB]
    /// 本體色漸層（sRGB）。
    var body: [RGB]
    /// 能量與核心的熱色。
    var hot: RGB
    /// 能量推向熱色的程度 0...1。
    var hotMix: Float
    /// 粒子本體的不透明度（遮蓋）。
    var bodyOpacity: Float
    /// 加法光的強度。
    var glowGain: Float
    /// 核心光暈的本體不透明度（太高會在淺色桌布上變成一片霧）。
    var haloOpacity: Float

    static func make(style: SculptureStyle, look: SceneLook) -> ParticleSpherePalette {
        let colors = SculptureStyleColors.of(style)
        var glow = look.glow.count >= 3 ? Array(look.glow.prefix(3)) : [look.baseColor(at: 0), look.baseColor(at: 0.5), look.baseColor(at: 1)]
        var hot = look.pulse
        var hotMix: Float = 0.55
        var glowGain: Float = 0.62
        var bodyOpacity: Float = 0.95
        var haloOpacity: Float = 0.2
        switch style {
        case .porcelain:
            glow = [RGB(red: 246, green: 238, blue: 222), RGB(red: 255, green: 251, blue: 242), RGB(red: 236, green: 228, blue: 210)]
            hot = colors.accent
            hotMix = 0.38
            glowGain = 0.5
            bodyOpacity = 1
        case .graphite:
            glow = [RGB(red: 150, green: 154, blue: 164), RGB(red: 118, green: 121, blue: 130), RGB(red: 92, green: 95, blue: 104)]
            hot = colors.accent
            hotMix = 0.8
            glowGain = 0.55
            bodyOpacity = 1
        case .aurora, .neon:
            hot = RGB(red: 255, green: 255, blue: 255)
            hotMix = 0.45
        case .sakura, .amber, .jade:
            glowGain = 0.5
            bodyOpacity = 1
        case .palette:
            break
        }
        let ink = inkTone(style)
        let body = glow.map { darken($0, toward: ink, maxLuminance: 96) }
        if look.isLight { haloOpacity = 0.16 }
        return ParticleSpherePalette(glow: glow, body: body, hot: hot, hotMix: hotMix, bodyOpacity: bodyOpacity,
                                     glowGain: glowGain, haloOpacity: haloOpacity)
    }

    /// 本體色要混入的深色：風格的文字色或外框色（取較深的那個），都不夠深時用深藍黑。
    static func inkTone(_ style: SculptureStyle) -> RGB {
        let colors = SculptureStyleColors.of(style)
        if luminance(colors.ink.0) < 90 { return colors.ink.0 }
        if luminance(colors.halo.0) < 90 { return colors.halo.0 }
        return RGB(red: 12, green: 14, blue: 24)
    }

    /// 把顏色往 ink 混，直到亮度不超過 maxLuminance（保留色相）。
    static func darken(_ c: RGB, toward ink: RGB, maxLuminance: Double) -> RGB {
        let l = luminance(c), li = luminance(ink)
        guard l > maxLuminance, l - li > 1 else { return c }
        let k = (l - maxLuminance) / (l - li)
        return SculptureStyleColors.mix(c, ink, k)
    }

    static func luminance(_ c: RGB) -> Double {
        0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)
    }
}
