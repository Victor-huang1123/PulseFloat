import CoreGraphics
import Foundation
@testable import PulseFloatCore
import XCTest

@MainActor
final class RenderNeonTests: XCTestCase {
    func testAfterimageFadesToSilentBaselineWithoutPermanentAlpha() async throws {
        let silent = SpectrumFrame.silent(bandCount: 64)
        let baselineRenderer = NeonRenderer()
        var baseline = 0
        for _ in 0..<60 { baseline = try alphaSum(renderer: baselineRenderer, frame: silent) }
        XCTAssertGreaterThan(baseline, 0)

        let renderer = NeonRenderer()
        let first = try alphaSum(renderer: renderer, frame: RenderTestSupport.frame())
        let second = try alphaSum(renderer: renderer, frame: silent)
        XCTAssertLessThan(second, first)
        XCTAssertGreaterThan(Double(second), 1.5 * Double(baseline))
        var last = second
        for _ in 2..<60 { last = try alphaSum(renderer: renderer, frame: silent) }
        XCTAssertEqual(Double(last), Double(baseline), accuracy: Double(baseline) * 0.01)
    }

    func testFullFrameHasMoreVisiblePixelsAboveHorizon() async throws {
        let bitmap = try RenderTestSupport.Bitmap()
        NeonRenderer().draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        XCTAssertGreaterThan(bitmap.visibleCount(rows: 0..<60), bitmap.visibleCount(rows: 60..<120))
    }

    func testBitmapDimensionsFollowExplicitScaleAndRebuildOnSizeChange() async throws {
        let renderer = NeonRenderer()
        for scale: CGFloat in [1, 2] {
            let bitmap = try RenderTestSupport.Bitmap(scale: scale)
            renderer.draw(
                in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
                look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade, scale: scale)
            )
            XCTAssertEqual(renderer.bitmapPixelSize, CGSize(width: 320 * scale, height: 120 * scale))
            XCTAssertGreaterThan(bitmap.visibleRatio, 0.1)
        }
        let size = CGSize(width: 182.25, height: 70.25)
        let bitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
        renderer.draw(
            in: bitmap.context, size: size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade, scale: 2)
        )
        XCTAssertEqual(renderer.bitmapPixelSize, CGSize(width: 365, height: 141))
    }

    func testExplicitScaleOverridesDestinationContextScale() async throws {
        let bitmap = try RenderTestSupport.Bitmap(scale: 1)
        let renderer = NeonRenderer()
        // 目標沒有 2x CTM；layer-backed draw(_:) 也不能依賴 CTM 得知 backing scale。
        XCTAssertEqual(abs(bitmap.context.ctm.a), 1)
        XCTAssertEqual(abs(bitmap.context.ctm.d), 1)
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade, scale: 2)
        )
        XCTAssertEqual(renderer.bitmapPixelSize, CGSize(width: 640, height: 240))
    }

    func testBackingScaleDoublesBothAxesOfRenderedAlpha() async throws {
        let one = try RenderTestSupport.Bitmap(scale: 1)
        let two = try RenderTestSupport.Bitmap(scale: 2)
        NeonRenderer().draw(
            in: one.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade, scale: 1)
        )
        NeonRenderer().draw(
            in: two.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade, scale: 2)
        )
        XCTAssertGreaterThan(one.alphaSum, 0)
        XCTAssertEqual(Double(two.alphaSum) / Double(one.alphaSum), 4, accuracy: 0.8)
    }

    func testInvalidFrameRemovesHistoryBeforeNextValidFrame() async throws {
        let silent = SpectrumFrame.silent(bandCount: 64)
        let fresh = try alphaSum(renderer: NeonRenderer(), frame: silent)
        for invalid in [SpectrumFrame.silent(bandCount: 0), SpectrumFrame(values: [1], peaks: [], bass: 1)] {
            let renderer = NeonRenderer()
            _ = try alphaSum(renderer: renderer, frame: RenderTestSupport.frame())
            XCTAssertEqual(try alphaSum(renderer: renderer, frame: invalid), 0)
            XCTAssertEqual(try alphaSum(renderer: renderer, frame: silent), fresh)
        }
    }

    func testFullFadeRemovesAfterimageImmediately() async throws {
        let renderer = NeonRenderer()
        let silent = SpectrumFrame.silent(bandCount: 64)
        _ = try alphaSum(renderer: renderer, frame: RenderTestSupport.frame())
        let faded = try alphaSum(renderer: renderer, frame: silent, fade: 1)
        let fresh = try alphaSum(renderer: NeonRenderer(), frame: silent, fade: 1)
        XCTAssertGreaterThan(fresh, 0)
        XCTAssertEqual(Double(faded), Double(fresh), accuracy: Double(fresh) * 0.01)
    }

    func testGlowExtendsAboveLineAndGrowsWithBass() async throws {
        let quiet = try RenderTestSupport.Bitmap()
        let pulse = try RenderTestSupport.Bitmap()
        var quietFrame = RenderTestSupport.frame()
        quietFrame.bass = 0
        NeonRenderer().draw(
            in: quiet.context, size: RenderTestSupport.size, frame: quietFrame,
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        NeonRenderer().draw(
            in: pulse.context, size: RenderTestSupport.size, frame: RenderTestSupport.frame(),
            look: VisualizerConfig.Look(), options: RenderOptions(fade: RenderTestSupport.fade)
        )
        // 全高線段從 y=12 起；y=2 只可能由光暈覆蓋，不能由線段本體通過此斷言。
        XCTAssertGreaterThan(quiet.alpha(x: 160, y: 2), 0)
        XCTAssertGreaterThan(Int(pulse.alpha(x: 160, y: 2)), Int(quiet.alpha(x: 160, y: 2)) + 5)
    }

    func testAccumulatedSRGBTrailKeepsColorWhenCompositedToDisplayP3() async throws {
        let srgb = try RenderTestSupport.Bitmap()
        let directP3 = try RenderTestSupport.Bitmap(colorSpaceName: CGColorSpace.displayP3)
        let convertedP3 = try RenderTestSupport.Bitmap(colorSpaceName: CGColorSpace.displayP3)
        let srgbRenderer = NeonRenderer()
        let p3Renderer = NeonRenderer()
        let frame = RenderTestSupport.frame()
        let look = VisualizerConfig.Look()
        let options = RenderOptions(fade: RenderTestSupport.fade)
        var index = 0
        while index < 60 {
            srgbRenderer.draw(in: srgb.context, size: RenderTestSupport.size, frame: frame, look: look, options: options)
            p3Renderer.draw(in: directP3.context, size: RenderTestSupport.size, frame: frame, look: look, options: options)
            index += 1
        }
        let image = try XCTUnwrap(srgb.context.makeImage())
        convertedP3.context.translateBy(x: 0, y: RenderTestSupport.size.height)
        convertedP3.context.scaleBy(x: 1, y: -1)
        convertedP3.context.draw(image, in: CGRect(origin: .zero, size: RenderTestSupport.size))
        // 低頻青色線段：直接轉 P3 必須接近先以 sRGB 呈現再轉 P3。
        // extendedSRGB 的未夾值 RGB 會令此處紅色明顯過高，甚至變成白色。
        XCTAssertGreaterThan(directP3.alpha(x: 21, y: 35), 200)
        for channel in 0..<3 {
            XCTAssertEqual(Double(directP3.component(x: 21, y: 35, channel: channel)),
                           Double(convertedP3.component(x: 21, y: 35, channel: channel)), accuracy: 8,
                           "P3 channel \(channel)")
        }
        XCTAssertGreaterThan(convertedP3.component(x: 21, y: 35, channel: 1),
                             convertedP3.component(x: 21, y: 35, channel: 0))
    }

    func testReusedGlowBuffersRefreshFrameAndPalettePixels() async throws {
        var low = SpectrumFrame.silent(bandCount: 64)
        var high = SpectrumFrame.silent(bandCount: 64)
        for index in 0..<16 { low.values[index] = 0.9; low.peaks[index] = 0.9 }
        for index in 32..<64 { high.values[index] = 1; high.peaks[index] = 1 }
        low.bass = 0.2
        high.bass = 0.8
        let cases: [(SpectrumFrame, PaletteID)] = [
            (RenderTestSupport.frame(), .aurora), (low, .ember),
            (high, .glacier), (.silent(bandCount: 64), .mono),
            (RenderTestSupport.frame(), .aurora)
        ]
        let sizes: [(CGSize, CGFloat)] = [(RenderTestSupport.size, 1), (CGSize(width: 521.25, height: 201.25), 2)]
        for (size, scale) in sizes {
            let renderer = NeonRenderer()
            let bitmap = try RenderTestSupport.Bitmap(size: size, scale: scale)
            for (frame, palette) in cases {
                let fresh = try RenderTestSupport.Bitmap(size: size, scale: scale)
                var look = VisualizerConfig.Look()
                look.palette = palette
                let options = RenderOptions(fade: 1, scale: scale)
                renderer.draw(in: bitmap.context, size: size, frame: frame, look: look, options: options)
                NeonRenderer().draw(in: fresh.context, size: size, frame: frame, look: look, options: options)
                // fade=1 排除殘影因素；1043x403 px 亦涵蓋並行分段後的全清除與快取更新。
                try assertPixelsEqual(bitmap, fresh, message: "reused glow, palette \(palette), size \(size)")
            }
        }
    }

    func testOddPixelSizesAndThumbnailSwitchesRebuildGlowCorrectly() async throws {
        let renderer = NeonRenderer()
        let cases: [(CGSize, CGFloat, Bool)] = [
            // 1043x403 px 超過並行門檻，403 列不能被 2...8 任一 worker 數整除。
            (CGSize(width: 521.25, height: 201.25), 2, false),
            (CGSize(width: 521.25, height: 201.25), 2, true),
            (CGSize(width: 182.25, height: 70.25), 2, false),
            (CGSize(width: 182.25, height: 70.25), 2, true),
            (CGSize(width: 79.25, height: 31.25), 2, true),
            (CGSize(width: 79.25, height: 31.25), 2, false),
            (CGSize(width: 1.25, height: 1.25), 2, false),
            (CGSize(width: 1.25, height: 1.25), 2, true),
            (CGSize(width: 182.25, height: 70.25), 1, false)
        ]
        for (size, scale, thumbnail) in cases {
            let bitmap = try RenderTestSupport.Bitmap(size: size, scale: scale)
            let fresh = try RenderTestSupport.Bitmap(size: size, scale: scale)
            let options = RenderOptions(isThumbnail: thumbnail, fade: 1, scale: scale)
            let frame = RenderTestSupport.frame()
            renderer.draw(in: bitmap.context, size: size, frame: frame, look: VisualizerConfig.Look(), options: options)
            NeonRenderer().draw(in: fresh.context, size: size, frame: frame, look: VisualizerConfig.Look(), options: options)
            XCTAssertEqual(renderer.bitmapPixelSize, CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale)))
            try assertPixelsEqual(bitmap, fresh, message: "size \(size), scale \(scale), thumbnail \(thumbnail)")
            if bitmap.height == 3 {
                // 3 px 高度小於一般並行分段數且不能整除 4；最後一列仍須繪製，不能被整數分段漏掉。
                XCTAssertGreaterThan(bitmap.alpha(x: 1, y: 2), 0)
            }
        }
    }

    func testSaturatedTrailFadesAtOddRetinaSizeForNormalAndThumbnail() async throws {
        let silent = SpectrumFrame.silent(bandCount: 64)
        let look = VisualizerConfig.Look()
        for size in [CGSize(width: 182.25, height: 70.25), CGSize(width: 521.25, height: 201.25)] {
            for thumbnail in [false, true] {
                let options = RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, scale: 2)
                let baselineRenderer = NeonRenderer()
                let baselineBitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
                var index = 0
                while index < 60 {
                    baselineRenderer.draw(in: baselineBitmap.context, size: size, frame: silent, look: look, options: options)
                    index += 1
                }
                let baseline = baselineBitmap.alphaSum
                let renderer = NeonRenderer()
                let bitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
                index = 0
                while index < 8 {
                    renderer.draw(in: bitmap.context, size: size, frame: RenderTestSupport.frame(), look: look, options: options)
                    index += 1
                }
                let saturated = bitmap.alphaSum
                renderer.draw(in: bitmap.context, size: size, frame: silent, look: look, options: options)
                let afterOneSilent = bitmap.alphaSum
                XCTAssertLessThan(afterOneSilent, saturated)
                XCTAssertGreaterThan(Double(afterOneSilent), 1.5 * Double(baseline))
                index = 1
                while index < 60 {
                    renderer.draw(in: bitmap.context, size: size, frame: silent, look: look, options: options)
                    index += 1
                }
                XCTAssertGreaterThan(baseline, 0)
                XCTAssertEqual(Double(bitmap.alphaSum), Double(baseline), accuracy: Double(baseline) * 0.01,
                               "thumbnail \(thumbnail), \(bitmap.width)x\(bitmap.height) px trail")
            }
        }
    }

    func testParallelGlowMatchesSerialPixelsAcrossSixteenChangingFrames() async throws {
        let size = CGSize(width: 521.25, height: 201.25)
        let serial = NeonRenderer(maximumWorkers: 1)
        let parallel = NeonRenderer()
        let serialBitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
        let parallelBitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
        let fades = [0.0, 0.12, RenderTestSupport.fade, 0.7, 1.0, 0.35]
        let palettes = PaletteID.allCases
        XCTAssertEqual(parallelBitmap.width, 1043)
        XCTAssertEqual(parallelBitmap.height, 403)
        var index = 0
        while index < 16 {
            var frame = SpectrumFrame.silent(bandCount: 64)
            var band = 0
            while band < frame.bandCount {
                let value = index == 0 ? 1 : (index % 7 == 6 ? 0 : Float((band * 11 + index * 7) % 101) / 100)
                frame.values[band] = value
                frame.peaks[band] = min(1, value + 0.1)
                band += 1
            }
            frame.bass = Float((index * 3) % 11) / 10
            var look = VisualizerConfig.Look()
            look.palette = palettes[(index / 3) % palettes.count]
            // 每四幀切換正常/縮圖，保留同一 trail，涵蓋插值邊帶、alpha/配色快取及殘影。
            let thumbnail = (index / 4) % 2 == 1
            let options = RenderOptions(isThumbnail: thumbnail, fade: fades[index % fades.count], scale: 2)
            serial.draw(in: serialBitmap.context, size: size, frame: frame, look: look, options: options)
            parallel.draw(in: parallelBitmap.context, size: size, frame: frame, look: look, options: options)
            try assertPixelsEqual(parallelBitmap, serialBitmap,
                                  message: "parallel vs serial frame \(index), thumbnail \(thumbnail)")
            index += 1
        }
    }

    private func assertPixelsEqual(_ actual: RenderTestSupport.Bitmap, _ expected: RenderTestSupport.Bitmap,
                                   message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        let actualBytes = try XCTUnwrap(actual.context.data)
        let expectedBytes = try XCTUnwrap(expected.context.data)
        var row = 0
        while row < actual.height {
            let actualRow = Data(bytes: actualBytes.advanced(by: row * actual.context.bytesPerRow), count: actual.width * 4)
            let expectedRow = Data(bytes: expectedBytes.advanced(by: row * expected.context.bytesPerRow), count: expected.width * 4)
            if actualRow != expectedRow {
                XCTFail("\(message), first differing RGBA row \(row)", file: file, line: line)
                return
            }
            row += 1
        }
    }

    private func alphaSum(renderer: NeonRenderer, frame: SpectrumFrame,
                          fade: Double = RenderTestSupport.fade) throws -> Int {
        let bitmap = try RenderTestSupport.Bitmap()
        renderer.draw(
            in: bitmap.context, size: RenderTestSupport.size, frame: frame,
            look: VisualizerConfig.Look(), options: RenderOptions(fade: fade)
        )
        return bitmap.alphaSum
    }
}
