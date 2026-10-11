import AppKit
import PulseFloatCore
import PulseFloatScene

/// 主題選單的縮圖：用真正的 renderer 畫一張「副歌拍點」的畫面（合成示範音樂經過真實的特徵引擎）。
/// 2D 主題用 Core Graphics renderer，3D 主題用離屏 SceneRenderer；疊在深色圓角底上，64×24 pt @2x。
/// 產生一次後快取；只在主執行緒使用。
@MainActor
enum ThemeThumbnails {
    static let size = NSSize(width: 64, height: 24)
    private static let background = RGB(red: 18, green: 21, blue: 32)

    /// 依目前的配色與雕塑色彩產生所有主題的縮圖。
    static func make(look: VisualizerConfig.Look) -> [ThemeID: NSImage] {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        // 示範音樂跑到副歌的拍點（DemoAudio 每 8 秒切換主歌／副歌，12.53 秒是副歌的第 2 拍之後）。
        let audio = DemoAudio(seed: 7)
        var frames: [SpectrumFrame] = []
        frames.reserveCapacity(760)
        while audio.seconds < 12.53 { frames.append(audio.next(dt: 1.0 / 60)) }
        guard let last = frames.last else { return [:] }

        var result: [ThemeID: NSImage] = [:]
        for theme in ThemeID.allCases {
            if theme.isScene, let renderer = SceneRenderer() {
                var settings = SceneSettings(look: look, aspect: Double(size.width / size.height))
                settings.presentation = .compact
                settings.quality = .medium
                renderer.setTheme(theme, settings: settings)
                var index = max(0, frames.count - 240)
                while index < frames.count - 1 { renderer.advance(frame: frames[index], dt: 1.0 / 60); index += 1 }
                if let image = renderer.renderOffscreen(frame: last, dt: 1.0 / 60, width: width, height: height),
                   let composited = image.composited(top: background, bottom: background) {
                    result[theme] = rounded(composited)
                }
            } else {
                result[theme] = rounded(drawCoreGraphics(theme, frames: frames, look: look, width: width, height: height, scale: scale))
            }
        }
        return result
    }

    private static func drawCoreGraphics(_ theme: ThemeID, frames: [SpectrumFrame], look: VisualizerConfig.Look,
                                         width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background.cgColor())
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let renderer = RendererFactory.make(theme: theme)
        var thumbLook = look
        thumbLook.theme = theme
        let options = RenderOptions(isThumbnail: true, fade: 1 - exp(-(1.0 / 60) / 0.07), scale: scale, dt: 1.0 / 60,
                                    sculptureStyle: look.sculptureStyle)
        // 讓有時間狀態的主題（脈衝、鏡頭）跑一小段再截圖；只畫最後一幀到圖上。
        var index = max(0, frames.count - 12)
        while index < frames.count {
            if index == frames.count - 1 {
                context.saveGState()
                renderer.draw(in: context, size: size, frame: frames[index], look: thumbLook, options: options)
                context.restoreGState()
            } else if let scratch = scratchContext(width: width, height: height, scale: scale) {
                renderer.draw(in: scratch, size: size, frame: frames[index], look: thumbLook, options: options)
            }
            index += 1
        }
        return context.makeImage()
    }

    private static var scratch: CGContext?
    private static func scratchContext(width: Int, height: Int, scale: CGFloat) -> CGContext? {
        if let scratch, scratch.width == width, scratch.height == height { return scratch }
        let made = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        made?.translateBy(x: 0, y: CGFloat(height))
        made?.scaleBy(x: scale, y: -scale)
        scratch = made
        return made
    }

    /// 圓角裁切成 NSImage（選單會依 size 以 pt 顯示）。
    private static func rounded(_ image: CGImage?) -> NSImage? {
        guard let image else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            NSGraphicsContext.current?.cgContext.draw(image, in: rect)
            return true
        }
    }
}
