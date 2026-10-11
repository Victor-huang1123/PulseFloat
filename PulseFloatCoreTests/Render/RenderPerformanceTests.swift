import CoreGraphics
import Foundation
import PulseFloatCore
import XCTest

@MainActor
final class RenderPerformanceTests: XCTestCase {
    func testSixtyFullFramesStayWithinDebugRenderingBudget() async throws {
        let size = CGSize(width: 520, height: 200)
        let frame = RenderTestSupport.frame()
        let look = VisualizerConfig.Look()
        let options = RenderOptions(fade: RenderTestSupport.fade, scale: 2)
        for theme in RenderTestSupport.legacyThemes {
            let bitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
            let renderer = RendererFactory.make(theme: theme)
            // 一次性的 buffer 建立與配色快取不計入每幀預算。
            var warmup = 0
            while warmup < 5 {
                renderer.draw(in: bitmap.context, size: size, frame: frame, look: look, options: options)
                warmup += 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            var index = 0
            while index < 60 {
                renderer.draw(in: bitmap.context, size: size, frame: frame, look: look, options: options)
                index += 1
            }
            let averageMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 60
            let budgetMilliseconds = theme == .neon ? 5.0 : 4.0
            XCTAssertLessThanOrEqual(averageMilliseconds, budgetMilliseconds,
                                     "\(theme): 520x200 pt @2x，60 幀平均 \(averageMilliseconds) ms")
            XCTAssertGreaterThan(bitmap.alphaSum, 0)
        }
    }
}
