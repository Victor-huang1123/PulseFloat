import CoreGraphics
import PulseFloatCore
import XCTest

@MainActor
final class RenderMenuBarTests: XCTestCase {
    func testSevenFullHeightTemplateBarsAreGrayscale() async throws {
        let size = CGSize(width: 26, height: 16)
        let bitmap = try RenderTestSupport.Bitmap(size: size)
        MenuBarRenderer().draw(
            in: bitmap.context, size: size, frame: RenderTestSupport.frame(),
            config: VisualizerConfig.MenuBar(), palette: .aurora
        )
        let barWidth = (26.0 - 1.5 * 6) / 7
        for index in 0..<7 {
            let center = Int(floor(Double(index) * (barWidth + 1.5) + barWidth / 2))
            for y in 0..<16 {
                XCTAssertGreaterThan(bitmap.alpha(x: center, y: y), 0, "bar \(index), y=\(y)")
            }
            XCTAssertGreaterThan(bitmap.alpha(x: center, y: 0), 150, "bar \(index) top")
            XCTAssertGreaterThan(bitmap.alpha(x: center, y: 15), 150, "bar \(index) bottom")
        }
        var runs = 0
        var previousVisible = false
        // 1.5 pt 間隔在 1x 下會跨兩個帶 AA 的像素；用 template alpha 0.92 的半高辨認柱核心。
        let halfTemplateAlpha = 0.92 * 255 / 2
        for x in 0..<26 {
            let visible = Double(bitmap.alpha(x: x, y: 8)) > halfTemplateAlpha
            if visible && !previousVisible { runs += 1 }
            previousVisible = visible
        }
        XCTAssertEqual(runs, 7)
        for y in 0..<16 {
            for x in 0..<26 where bitmap.alpha(x: x, y: y) > 0 {
                let red = bitmap.component(x: x, y: y, channel: 0)
                XCTAssertEqual(red, bitmap.component(x: x, y: y, channel: 1))
                XCTAssertEqual(red, bitmap.component(x: x, y: y, channel: 2))
            }
        }
    }

    func testColoredDotsDrawPaletteAndInvalidFramesClear() async throws {
        let size = CGSize(width: 26, height: 16)
        let renderer = MenuBarRenderer()
        let bitmap = try RenderTestSupport.Bitmap(size: size)
        var config = VisualizerConfig.MenuBar()
        config.colored = true
        config.style = .dots
        renderer.draw(in: bitmap.context, size: size, frame: RenderTestSupport.frame(), config: config, palette: .ember)
        XCTAssertGreaterThan(bitmap.alphaSum, 0)
        var coloredPixels = 0
        for y in 0..<16 {
            for x in 0..<26 where bitmap.alpha(x: x, y: y) > 0 {
                if bitmap.component(x: x, y: y, channel: 0) != bitmap.component(x: x, y: y, channel: 1) {
                    coloredPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 0)
        let mismatch = SpectrumFrame(values: [1], peaks: [], bass: 1)
        renderer.draw(in: bitmap.context, size: size, frame: mismatch, config: config, palette: .ember)
        XCTAssertEqual(bitmap.alphaSum, 0)
        renderer.draw(in: bitmap.context, size: size, frame: .silent(bandCount: 0), config: config, palette: .ember)
        XCTAssertEqual(bitmap.alphaSum, 0)
    }

    func testTinyAndZeroSizesWithSparseBandsDoNotCrash() async throws {
        let bitmap = try RenderTestSupport.Bitmap(size: CGSize(width: 26, height: 16))
        for style in MenuBarStyle.allCases {
            var config = VisualizerConfig.MenuBar()
            config.style = style
            for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 26, height: 1)] {
                MenuBarRenderer().draw(
                    in: bitmap.context, size: size, frame: RenderTestSupport.frame(bandCount: 1),
                    config: config, palette: .aurora
                )
            }
        }
    }

    func testDotsWithNoRoomForVerticalGapsRemainClear() async throws {
        let bitmap = try RenderTestSupport.Bitmap(size: CGSize(width: 26, height: 1))
        MenuBarRenderer().draw(
            in: bitmap.context, size: CGSize(width: 26, height: 1), frame: RenderTestSupport.frame(),
            config: VisualizerConfig.MenuBar(style: .dots), palette: .aurora
        )
        XCTAssertEqual(bitmap.alphaSum, 0)
    }
}
