import PulseFloatCore

/// 黑洞在 8 種雕塑風格下的配色與材質參數。
/// hot（內緣）→ mid（主體）→ cool（外緣）是盤面的溫度漸層；dust 是吸光塵帶（在淺色桌布上提供深色結構）；
/// ring 是細環；spark 是高頻火花。
struct BlackHolePalette: Equatable {
    var hot: RGB
    var mid: RGB
    var cool: RGB
    var dust: RGB
    var ring: RGB
    var stream: RGB
    var streamAlt: RGB
    var spark: RGB
    /// 最熱處混入白色的比例（0 = 保持色相）。
    var whiteHot: Float = 0.8
    /// 盤面發光強度。
    var emission: Float = 1
    /// 盤面最大不透明度（淺色桌布上需要夠高）。
    var opacity: Float = 0.92
    /// 塵帶強度。
    var dustStrength: Float = 0.8

    static func make(style: SculptureStyle, palette: PaletteID) -> BlackHolePalette {
        switch style {
        case .amber:
            return BlackHolePalette(hot: RGB(red: 255, green: 204, blue: 118), mid: RGB(red: 238, green: 132, blue: 40),
                                    cool: RGB(red: 118, green: 40, blue: 12), dust: RGB(red: 40, green: 16, blue: 4),
                                    ring: RGB(red: 255, green: 196, blue: 120), stream: RGB(red: 255, green: 206, blue: 140),
                                    streamAlt: RGB(red: 214, green: 120, blue: 48), spark: RGB(red: 255, green: 246, blue: 226))
        case .graphite:
            return BlackHolePalette(hot: RGB(red: 236, green: 238, blue: 230), mid: RGB(red: 146, green: 148, blue: 154),
                                    cool: RGB(red: 58, green: 58, blue: 64), dust: RGB(red: 10, green: 10, blue: 12),
                                    ring: RGB(red: 226, green: 240, blue: 150), stream: RGB(red: 214, green: 218, blue: 222),
                                    streamAlt: RGB(red: 110, green: 114, blue: 122), spark: RGB(red: 226, green: 240, blue: 150),
                                    whiteHot: 0.5, emission: 0.95, opacity: 0.95, dustStrength: 1)
        case .porcelain:
            return BlackHolePalette(hot: RGB(red: 255, green: 170, blue: 92), mid: RGB(red: 248, green: 240, blue: 226),
                                    cool: RGB(red: 160, green: 150, blue: 136), dust: RGB(red: 40, green: 34, blue: 30),
                                    ring: RGB(red: 255, green: 138, blue: 31), stream: RGB(red: 250, green: 246, blue: 236),
                                    streamAlt: RGB(red: 196, green: 186, blue: 170), spark: RGB(red: 255, green: 160, blue: 70),
                                    whiteHot: 0.55, emission: 0.95, opacity: 0.94, dustStrength: 0.9)
        case .aurora:
            return BlackHolePalette(hot: RGB(red: 70, green: 240, blue: 206), mid: RGB(red: 50, green: 140, blue: 255),
                                    cool: RGB(red: 100, green: 48, blue: 220), dust: RGB(red: 6, green: 10, blue: 34),
                                    ring: RGB(red: 163, green: 140, blue: 255), stream: RGB(red: 120, green: 240, blue: 220),
                                    streamAlt: RGB(red: 90, green: 130, blue: 255), spark: RGB(red: 230, green: 255, blue: 250),
                                    whiteHot: 0.7, emission: 1.05, opacity: 0.9, dustStrength: 0.85)
        case .sakura:
            return BlackHolePalette(hot: RGB(red: 255, green: 196, blue: 214), mid: RGB(red: 244, green: 120, blue: 168),
                                    cool: RGB(red: 140, green: 44, blue: 100), dust: RGB(red: 80, green: 18, blue: 46),
                                    ring: RGB(red: 255, green: 93, blue: 143), stream: RGB(red: 255, green: 206, blue: 220),
                                    streamAlt: RGB(red: 236, green: 130, blue: 172), spark: RGB(red: 255, green: 120, blue: 168),
                                    whiteHot: 0.6, emission: 0.95, opacity: 0.93, dustStrength: 0.85)
        case .jade:
            return BlackHolePalette(hot: RGB(red: 186, green: 250, blue: 200), mid: RGB(red: 64, green: 184, blue: 132),
                                    cool: RGB(red: 20, green: 82, blue: 60), dust: RGB(red: 6, green: 30, blue: 22),
                                    ring: RGB(red: 180, green: 240, blue: 196), stream: RGB(red: 200, green: 244, blue: 214),
                                    streamAlt: RGB(red: 82, green: 183, blue: 136), spark: RGB(red: 240, green: 255, blue: 200),
                                    whiteHot: 0.65, emission: 1, opacity: 0.92, dustStrength: 0.85)
        case .neon:
            return BlackHolePalette(hot: RGB(red: 0, green: 245, blue: 212), mid: RGB(red: 241, green: 91, blue: 181),
                                    cool: RGB(red: 96, green: 40, blue: 190), dust: RGB(red: 16, green: 8, blue: 30),
                                    ring: RGB(red: 0, green: 245, blue: 212), stream: RGB(red: 255, green: 120, blue: 200),
                                    streamAlt: RGB(red: 120, green: 90, blue: 240), spark: RGB(red: 255, green: 255, blue: 255),
                                    whiteHot: 0.45, emission: 1.15, opacity: 0.86, dustStrength: 1)
        case .palette:
            // 跟隨目前配色：最亮的顏色當內緣，外緣混入中性灰（和同色系的風格比起來核心更白、外圍更沉）
            let colors = Palette(palette)
            let first = colors.color(at: 0), middle = colors.color(at: 0.5), last = colors.color(at: 1)
            let black = RGB(red: 6, green: 6, blue: 10), white = RGB(red: 255, green: 255, blue: 255)
            let gray = RGB(red: 96, green: 96, blue: 104)
            return BlackHolePalette(hot: SculptureStyleColors.mix(first, white, 0.4), mid: middle,
                                    cool: SculptureStyleColors.mix(SculptureStyleColors.mix(last, gray, 0.45), black, 0.3),
                                    dust: SculptureStyleColors.mix(last, black, 0.85),
                                    ring: first, stream: SculptureStyleColors.mix(first, white, 0.3), streamAlt: last,
                                    spark: SculptureStyleColors.mix(first, white, 0.6),
                                    whiteHot: 0.75, emission: 1, opacity: 0.9, dustStrength: 0.9)
        }
    }
}
