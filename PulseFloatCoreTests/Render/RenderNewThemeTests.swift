import CoreGraphics
import Foundation
import PulseFloatCore
import XCTest

/// 軌道、儀表、星圖、無限、解析五個主題：有畫面、縮圖可用、異常 frame 不當機、靜音時畫面靜止。
@MainActor
final class RenderNewThemeTests: XCTestCase {
    private static let themes: [ThemeID] = [.orbit, .hud, .constellation, .mobius, .analysis]
    private static let size = CGSize(width: 520, height: 200)

    private func snapshot(_ bitmap: RenderTestSupport.Bitmap) -> [UInt8] {
        guard let data = bitmap.context.data else { return [] }
        let count = bitmap.context.bytesPerRow * bitmap.height
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
    }

    /// 0.25...1 起伏的頻譜，讓峰值偵測、連線與光環都有機會出現。
    private func loudFrame(_ step: Int, bandCount: Int = 64) -> SpectrumFrame {
        var values = [Float](repeating: 0, count: bandCount)
        var i = 0
        while i < bandCount {
            let phase = Double(i) * 0.37 + Double(step) * 0.21
            values[i] = Float(0.25 + 0.75 * (0.5 + 0.5 * sin(phase)))
            i += 1
        }
        return SpectrumFrame(values: values, peaks: values.map { min(1, $0 + 0.15) },
                             bass: step % 20 < 3 ? 0.95 : 0.15)
    }

    func testEveryNewThemeDrawsVisiblePixelsAtFullSizeAndAsThumbnail() throws {
        for theme in Self.themes {
            for thumbnail in [false, true] {
                let size = thumbnail ? CGSize(width: 160, height: 60) : Self.size
                let bitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
                let renderer = RendererFactory.make(theme: theme)
                let options = RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, scale: 2)
                var step = 0
                while step < 30 {
                    renderer.draw(in: bitmap.context, size: size, frame: loudFrame(step), look: VisualizerConfig.Look(), options: options)
                    step += 1
                }
                XCTAssertGreaterThan(bitmap.visibleRatio, 0.01, "\(theme) thumbnail=\(thumbnail)")
            }
        }
    }

    func testMalformedFramesAndTinySizesDoNotCrash() throws {
        let frames = [
            SpectrumFrame(values: [], peaks: [], bass: 0),
            SpectrumFrame(values: [1], peaks: [1], bass: 1),
            SpectrumFrame(values: [1, 0.5, 0.2], peaks: [1], bass: 0.5),
            SpectrumFrame(values: [Float](repeating: .nan, count: 64), peaks: [Float](repeating: .infinity, count: 64), bass: .nan),
        ]
        for theme in Self.themes {
            let renderer = RendererFactory.make(theme: theme)
            for size in [Self.size, CGSize(width: 4, height: 4), CGSize(width: 40, height: 12)] {
                let bitmap = try RenderTestSupport.Bitmap(size: size)
                for frame in frames {
                    for dt in [0, 1.0 / 60, 5, -1, .nan] {
                        renderer.draw(in: bitmap.context, size: size, frame: frame, look: VisualizerConfig.Look(),
                                      options: RenderOptions(fade: RenderTestSupport.fade, dt: dt))
                    }
                }
            }
        }
    }

    func testSilenceAfterMusicSettlesToAStaticImage() throws {
        let silent = RenderTestSupport.frame(level: 0)
        for theme in Self.themes {
            for style in [SculptureStyle.porcelain, .neon] {
                let bitmap = try RenderTestSupport.Bitmap(size: Self.size)
                let renderer = RendererFactory.make(theme: theme)
                let options = RenderOptions(fade: RenderTestSupport.fade, sculptureStyle: style)
                var step = 0
                while step < 120 {
                    renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(), options: options)
                    step += 1
                }
                // 6 秒的靜音足以讓光環、鏡頭、殘光全部回到靜止。
                step = 0
                while step < 360 {
                    renderer.draw(in: bitmap.context, size: Self.size, frame: silent, look: VisualizerConfig.Look(), options: options)
                    step += 1
                }
                let settled = snapshot(bitmap)
                step = 0
                while step < 30 {
                    renderer.draw(in: bitmap.context, size: Self.size, frame: silent, look: VisualizerConfig.Look(), options: options)
                    step += 1
                }
                let now = snapshot(bitmap)
                var changed = 0
                var b = 0
                while b < min(now.count, settled.count) { if now[b] != settled[b] { changed += 1 }; b += 1 }
                XCTAssertEqual(changed, 0, "\(theme) \(style) 靜音時畫面仍在變（\(changed) bytes）")
                XCTAssertGreaterThan(bitmap.alphaSum, 0, "\(theme) 靜音時應保留淡淡的靜態圖，不是全空")
            }
        }
    }

    func testMusicMovesTheImage() throws {
        for theme in Self.themes {
            let bitmap = try RenderTestSupport.Bitmap(size: Self.size)
            let renderer = RendererFactory.make(theme: theme)
            let options = RenderOptions(fade: RenderTestSupport.fade)
            renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(0), look: VisualizerConfig.Look(), options: options)
            let first = snapshot(bitmap)
            var step = 1
            while step < 20 {
                renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(), options: options)
                step += 1
            }
            XCTAssertTrue(snapshot(bitmap) != first, "\(theme)")
        }
    }

    func testEveryPaletteAndSculptureStyleRenders() throws {
        for theme in Self.themes {
            let renderer = RendererFactory.make(theme: theme)
            let bitmap = try RenderTestSupport.Bitmap(size: Self.size)
            for palette in PaletteID.allCases {
                for style in SculptureStyle.allCases {
                    var look = VisualizerConfig.Look()
                    look.palette = palette
                    renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(3), look: look,
                                  options: RenderOptions(fade: RenderTestSupport.fade, sculptureStyle: style))
                    XCTAssertGreaterThan(bitmap.alphaSum, 0, "\(theme) \(palette) \(style)")
                }
            }
        }
    }

    /// Debug build 的寬鬆上限（Release 實測另見 README／交付報告）；防止退化成十幾毫秒。
    func testFullFramesStayWithinDebugBudget() throws {
        let options = RenderOptions(fade: RenderTestSupport.fade, scale: 2)
        for theme in Self.themes {
            let bitmap = try RenderTestSupport.Bitmap(size: Self.size, scale: 2)
            let renderer = RendererFactory.make(theme: theme)
            var step = 0
            while step < 10 {
                renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(), options: options)
                step += 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            step = 0
            while step < 60 {
                renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(), options: options)
                step += 1
            }
            let averageMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 60
            print("RenderNewThemeTests \(theme): \(String(format: "%.2f", averageMilliseconds)) ms/frame (Debug, 520x200 @2x)")
            XCTAssertLessThanOrEqual(averageMilliseconds, 12, "\(theme): 60 幀平均 \(averageMilliseconds) ms")
        }
    }
}
