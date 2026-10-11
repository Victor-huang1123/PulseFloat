import CoreGraphics
import Foundation
import PulseFloatCore
import XCTest

@MainActor
final class RenderThemeTests: XCTestCase {
    func testFullFramesFillAtLeastTenPercentForEveryThemeAndThumbnail() async throws {
        for theme in RenderTestSupport.legacyThemes {
            for thumbnail in [false, true] {
                let bitmap = try RenderTestSupport.Bitmap()
                let renderer = RendererFactory.make(theme: theme)
                renderer.draw(
                    in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
                    look: VisualizerConfig.Look(),
                    options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade)
                )
                XCTAssertGreaterThan(bitmap.visibleRatio, 0.10, "\(theme), thumbnail=\(thumbnail)")
                if theme == .neon {
                    // blur=24 裝置像素的光暈會碰到邊界；四周 2 px 容許 alpha 至 64/255，排除實心線段溢出。
                    XCTAssertLessThanOrEqual(bitmap.borderMaximum(), 64, "neon thumbnail=\(thumbnail)")
                } else {
                    // 全高 radial 的 r0+3+len 約為 0.494*h+3，依原型超出上下邊；此處只驗左右。
                    // 上下邊界另由 testRadialHalfHeightStaysInsideAllBorders 的半高 frame 驗證。
                    XCTAssertEqual(bitmap.borderMaximum(includeHorizontal: theme != .radial), 0,
                                   "\(theme), thumbnail=\(thumbnail)")
                }
            }
        }
    }

    func testRadialHalfHeightStaysInsideAllBorders() async throws {
        for thumbnail in [false, true] {
            let bitmap = try RenderTestSupport.Bitmap()
            RadialRenderer().draw(
                in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(level: 0.5),
                look: VisualizerConfig.Look(),
                options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade)
            )
            XCTAssertEqual(bitmap.borderMaximum(), 0)
        }
    }

    func testSilentBarsOccupyLessThanFivePercentWithoutReflection() async throws {
        var look = VisualizerConfig.Look()
        look.reflection = false
        for thumbnail in [false, true] {
            let bitmap = try RenderTestSupport.Bitmap()
            BarsRenderer().draw(
                in: bitmap.context, size: RenderTestSupport.size, frame: .silent(bandCount: 64), look: look,
                options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade)
            )
            XCTAssertGreaterThan(bitmap.visibleRatio, 0)
            XCTAssertLessThan(bitmap.visibleRatio, 0.05)
        }
    }

    func testBarsHavePrototypePitchAndFirstBarBounds() async throws {
        let bitmap = try RenderTestSupport.Bitmap()
        var look = VisualizerConfig.Look()
        look.barGap = 0.28
        BarsRenderer().draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(), look: look,
            options: RenderOptions(fade: RenderTestSupport.fade)
        )
        // padX=16, pitch=4.5, width=3.24；第一柱 [16.63, 19.87]，中段像素 17...19 有覆蓋。
        for x in 17...19 { XCTAssertGreaterThan(bitmap.alpha(x: x, y: 60), 0) }
        for x in 0..<16 { XCTAssertEqual(bitmap.alpha(x: x, y: 60), 0) }
        XCTAssertEqual(bitmap.alpha(x: 20, y: 60), 0)
        XCTAssertGreaterThan(bitmap.alpha(x: 22, y: 60), 0)
    }

    func testBarsPeakCapReflectionAndMirrorGeometry() async throws {
        let bitmap = try RenderTestSupport.Bitmap()
        var look = VisualizerConfig.Look()
        let renderer = BarsRenderer()
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(), look: look,
            options: RenderOptions(fade: RenderTestSupport.fade)
        )
        XCTAssertGreaterThan(bitmap.alpha(x: 18, y: 11), 200)
        XCTAssertEqual(bitmap.alpha(x: 18, y: 13), 0)
        XCTAssertEqual(bitmap.alpha(x: 18, y: 89), 0)
        XCTAssertEqual(Double(bitmap.alpha(x: 18, y: 100)), 41, accuracy: 3)

        look.mirror = true
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(), look: look,
            options: RenderOptions(fade: RenderTestSupport.fade)
        )
        XCTAssertGreaterThan(bitmap.alpha(x: 18, y: 100), 100)
    }

    func testBarsPaletteCacheRefreshesWhenPaletteChanges() async throws {
        let bitmap = try RenderTestSupport.Bitmap()
        let renderer = BarsRenderer()
        var look = VisualizerConfig.Look()
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(), look: look,
            options: RenderOptions(fade: RenderTestSupport.fade)
        )
        XCTAssertLessThan(bitmap.component(x: 18, y: 20, channel: 0), 100)
        look.palette = .ember
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(), look: look,
            options: RenderOptions(fade: RenderTestSupport.fade)
        )
        XCTAssertGreaterThan(bitmap.component(x: 18, y: 20, channel: 0), 200)
    }

    func testRadialCoreExpandsWithBass() async throws {
        let quiet = try RenderTestSupport.Bitmap()
        let pulse = try RenderTestSupport.Bitmap()
        let silent = SpectrumFrame.silent(bandCount: 64)
        var pulsing = silent
        pulsing.bass = 1
        RadialRenderer().draw(
            in: quiet.context, size: RenderTestSupport.size, frame: silent,
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        RadialRenderer().draw(
            in: pulse.context, size: RenderTestSupport.size, frame: pulsing,
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        // rc=19.6 / 21.328 pt；取上方圓盤外框，避開從 r0+3 起畫的放射線。
        XCTAssertEqual(quiet.alpha(x: 160, y: 38), 0)
        XCTAssertGreaterThan(pulse.alpha(x: 160, y: 38), 128)
    }

    func testLEDUsesRoundedColumnAndLitCountsAndSeparatePeakRow() async throws {
        let bitmap = try RenderTestSupport.Bitmap()
        let frame = SpectrumFrame(values: [Float](repeating: 0.55, count: 64),
                                  peaks: [Float](repeating: 0.8, count: 64), bass: 0)
        LedRenderer().draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: frame,
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        // round(64/1.5)=43 欄；pitch=288/43；rows=floor(96/pitch)=14。
        // round(0.55*14)=8 亮格；round(0.8*14)=11 為峰值列，不能用截斷代替四捨五入。
        let pitch = 288.0 / 43
        let top = 12 + (96 - 14 * pitch) / 2
        let x = Int(floor(16 + pitch / 2))
        for row in 0..<14 {
            let y = Int(floor(top + (13 - Double(row) + 0.5) * pitch))
            let expected = row < 8 ? 242.0 : (row == 11 ? 179.0 : 14.0)
            XCTAssertEqual(Double(bitmap.alpha(x: x, y: y)), expected, accuracy: 3, "LED row \(row)")
        }
    }

    func testLEDCacheInvalidationMatchesFreshRendererPixels() async throws {
        let renderer = LedRenderer()
        let mixed = SpectrumFrame(values: [Float](repeating: 0.55, count: 64),
                                  peaks: [Float](repeating: 0.8, count: 64), bass: 0)
        let resized = CGSize(width: 390, height: 150)
        let cases: [(String, CGSize, SpectrumFrame, Bool, PaletteID)] = [
            ("full", RenderTestSupport.size, RenderTestSupport.frame(), false, .aurora),
            ("lit and peak change", RenderTestSupport.size, mixed, false, .aurora),
            ("silent", RenderTestSupport.size, .silent(bandCount: 64), false, .aurora),
            ("resize", resized, mixed, false, .aurora),
            ("thumbnail", resized, mixed, true, .aurora),
            ("palette", resized, mixed, true, .ember),
            ("restore", RenderTestSupport.size, RenderTestSupport.frame(), false, .aurora)
        ]
        for (name, size, frame, thumbnail, palette) in cases {
            let actual = try RenderTestSupport.Bitmap(size: size)
            let expected = try RenderTestSupport.Bitmap(size: size)
            var look = VisualizerConfig.Look()
            look.palette = palette
            let options = RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade)
            renderer.draw(in: actual.context, size: size, frame: frame, look: look, options: options)
            LedRenderer().draw(in: expected.context, size: size, frame: frame, look: look, options: options)
            let actualBytes = try XCTUnwrap(actual.context.data)
            let expectedBytes = try XCTUnwrap(expected.context.data)
            var matching = true
            var row = 0
            while row < actual.height {
                // 逐列比較全部 RGBA；不把 bytesPerRow 的對齊 padding 當成繪圖資料。
                let actualRow = Data(bytes: actualBytes.advanced(by: row * actual.context.bytesPerRow),
                                     count: actual.width * 4)
                let expectedRow = Data(bytes: expectedBytes.advanced(by: row * expected.context.bytesPerRow),
                                       count: expected.width * 4)
                if actualRow != expectedRow {
                    matching = false
                    break
                }
                row += 1
            }
            XCTAssertTrue(matching, "LED cache after \(name), first differing row \(row)")
        }
    }

    func testEmptyAndMismatchedFramesClearEveryThemeIncludingNeonHistory() async throws {
        let invalid = [
            SpectrumFrame.silent(bandCount: 0),
            SpectrumFrame(values: [1, 1], peaks: [1], bass: 1),
            SpectrumFrame(values: [], peaks: [1], bass: 1)
        ]
        for theme in RenderTestSupport.legacyThemes {
            for frame in invalid {
                let renderer = RendererFactory.make(theme: theme)
                let bitmap = try RenderTestSupport.Bitmap()
                renderer.draw(
                    in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
                    look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
                )
                XCTAssertGreaterThan(bitmap.alphaSum, 0)
                renderer.draw(
                    in: bitmap.context, size: RenderTestSupport.size, frame: frame,
                    look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
                )
                XCTAssertEqual(bitmap.alphaSum, 0, "\(theme)")
            }
        }
    }

    func testZeroAndTinySizesDoNotCrash() async throws {
        for theme in RenderTestSupport.legacyThemes {
            let renderer = RendererFactory.make(theme: theme)
            let bitmap = try RenderTestSupport.Bitmap()
            for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 2, height: 1)] {
                renderer.draw(
                    in: bitmap.context, size: size, frame: RenderTestSupport.frame(),
                    look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
                )
            }
        }
    }

    func testNonfiniteAndOutOfRangeFrameValuesMatchClampedRendering() async throws {
        let malformed = SpectrumFrame(values: [.nan, .infinity, -.infinity, 2],
                                      peaks: [.nan, .infinity, -.infinity, 2], bass: .nan)
        let clamped = SpectrumFrame(values: [0, 1, 0, 1], peaks: [0, 1, 0, 1], bass: 0)
        for theme in RenderTestSupport.legacyThemes {
            let actual = try RenderTestSupport.Bitmap()
            let expected = try RenderTestSupport.Bitmap()
            RendererFactory.make(theme: theme).draw(
                in: actual.context, size: RenderTestSupport.size, frame: malformed,
                look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
            )
            RendererFactory.make(theme: theme).draw(
                in: expected.context, size: RenderTestSupport.size, frame: clamped,
                look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
            )
            XCTAssertEqual(actual.alphaSum, expected.alphaSum, "\(theme)")
            XCTAssertGreaterThan(actual.alphaSum, 0)
        }
    }
}
