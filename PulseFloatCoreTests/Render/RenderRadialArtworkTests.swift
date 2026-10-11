import CoreGraphics
import Foundation
import PulseFloatCore
import XCTest

/// 圓環放射中央的封面／App 圖示：位置、裁切、方向、交叉淡入、靜音靜止，以及沒有圖片時與原本逐像素相同。
@MainActor
final class RenderRadialArtworkTests: XCTestCase {
    private static let size = RenderTestSupport.size          // 320×120，短邊 120
    private static let center = CGPoint(x: 160, y: 60)
    private static let dt = 1.0 / 60
    // 有圖片且 bass=0 收斂後：radius = 120 × 0.27 = 32.4，coreRadius = 30.4，封面半徑 28.4，圖示邊長 38。
    private static let coverRadius: CGFloat = 28.4

    private struct Pixel {
        let red: Int, green: Int, blue: Int, alpha: Int
        var isRed: Bool { red > 200 && green < 60 && blue < 60 && alpha > 200 }
        var isBlue: Bool { blue > 200 && red < 60 && green < 60 && alpha > 200 }
    }

    /// 由像素資料直接建立；第 0 列是圖片最上面一列。
    private func solidImage(top: (UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8)? = nil, side: Int = 64) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var row = 0
        while row < side {
            let color = row < side / 2 ? top : (bottom ?? top)
            var column = 0
            while column < side {
                let offset = (row * side + column) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = 255
                column += 1
            }
            row += 1
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))
    }

    private func pixel(_ bitmap: RenderTestSupport.Bitmap, _ x: Int, _ y: Int) -> Pixel {
        Pixel(red: Int(bitmap.component(x: x, y: y, channel: 0)), green: Int(bitmap.component(x: x, y: y, channel: 1)),
              blue: Int(bitmap.component(x: x, y: y, channel: 2)), alpha: Int(bitmap.alpha(x: x, y: y)))
    }

    private func snapshot(_ bitmap: RenderTestSupport.Bitmap) -> [UInt8] {
        guard let data = bitmap.context.data else { return [] }
        let count = bitmap.context.bytesPerRow * bitmap.height
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private func render(_ renderer: RadialRenderer, into bitmap: RenderTestSupport.Bitmap, frame: SpectrumFrame,
                        artwork: CenterArtwork?, frames: Int, dt: Double = RenderRadialArtworkTests.dt, thumbnail: Bool = false) {
        var step = 0
        while step < frames {
            renderer.draw(in: bitmap.context, size: Self.size, frame: frame, look: VisualizerConfig.Look(),
                          options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, dt: dt, artwork: artwork))
            step += 1
        }
    }

    /// 0.2...1 起伏的頻譜，bass 也跟著變。
    private func loudFrame(_ step: Int) -> SpectrumFrame {
        var values = [Float](repeating: 0, count: 64)
        var index = 0
        while index < 64 {
            values[index] = Float(0.2 + 0.8 * (0.5 + 0.5 * sin(Double(index) * 0.4 + Double(step) * 0.3)))
            index += 1
        }
        return SpectrumFrame(values: values, peaks: values.map { min(1, $0 + 0.1) }, bass: step % 10 < 3 ? 0.9 : 0.2)
    }

    // MARK: - 契約

    func testCenterArtworkEqualityUsesIDAndKindOnly() throws {
        let red = try solidImage(top: (255, 0, 0))
        let blue = try solidImage(top: (0, 0, 255))
        XCTAssertEqual(CenterArtwork(id: "a", image: red, kind: .cover), CenterArtwork(id: "a", image: blue, kind: .cover))
        XCTAssertNotEqual(CenterArtwork(id: "a", image: red, kind: .cover), CenterArtwork(id: "b", image: red, kind: .cover))
        XCTAssertNotEqual(CenterArtwork(id: "a", image: red, kind: .cover), CenterArtwork(id: "a", image: red, kind: .appIcon))
        XCTAssertNil(RenderOptions(fade: 0.2).artwork)
    }

    // MARK: - 封面

    func testCoverAppearsInsideTheCentreCircleAndNowhereElse() throws {
        let artwork = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0)), kind: .cover)
        for frame in [SpectrumFrame.silent(bandCount: 64), RenderTestSupport.frame(level: 1)] {
            let bitmap = try RenderTestSupport.Bitmap()
            let renderer = RadialRenderer()
            // bass=1 時圓盤脈動 4%；用 bass=0 的 silent 與 bass=1 的滿格各驗一次。
            render(renderer, into: bitmap, frame: frame, artwork: artwork, frames: 180)
            let pulse: CGFloat = frame.bass > 0 ? 1.04 : 1
            let artRadius = (Self.size.height * 0.27 * pulse - 2) - 2
            var insideRed = 0
            var insideTotal = 0
            var outsideRed = 0
            var y = 0
            while y < bitmap.height {
                var x = 0
                while x < bitmap.width {
                    let distance = hypot(CGFloat(x) + 0.5 - Self.center.x, CGFloat(y) + 0.5 - Self.center.y)
                    let isRed = pixel(bitmap, x, y).isRed
                    if distance < artRadius - 1.5 {
                        insideTotal += 1
                        if isRed { insideRed += 1 }
                    } else if distance > artRadius + 1.5, isRed {
                        outsideRed += 1
                    }
                    x += 1
                }
                y += 1
            }
            XCTAssertGreaterThan(insideTotal, 2000)
            XCTAssertEqual(insideRed, insideTotal, "bass=\(frame.bass)：圓內每個像素都應是封面")
            XCTAssertEqual(outsideRed, 0, "bass=\(frame.bass)：封面不可超出圓形")
        }
    }

    func testCoverIsDrawnUpright() throws {
        let artwork = CenterArtwork(id: "split", image: try solidImage(top: (255, 0, 0), bottom: (0, 0, 255)), kind: .cover)
        let bitmap = try RenderTestSupport.Bitmap(scale: 2)
        render(RadialRenderer(), into: bitmap, frame: .silent(bandCount: 64), artwork: artwork, frames: 120)
        // scale 2：中心在像素 (320, 120)；上半部應是紅色、下半部藍色。
        XCTAssertTrue(pixel(bitmap, 320, 120 - 30).isRed)
        XCTAssertTrue(pixel(bitmap, 320, 120 + 30).isBlue)
    }

    func testCoreGrowsFromTheOriginalSizeWhenArtworkArrives() throws {
        let artwork = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0)), kind: .cover)
        let renderer = RadialRenderer()
        let bitmap = try RenderTestSupport.Bitmap()
        let silent = SpectrumFrame.silent(bandCount: 64)
        render(renderer, into: bitmap, frame: silent, artwork: nil, frames: 10)
        // 原本 coreRadius 19.6；y=60-24 在原本的放射線起點（r0+3=24.6）以內、也在原本圓盤外。
        let probe = (x: 160, y: 60 - 24)
        XCTAssertFalse(pixel(bitmap, probe.x, probe.y).isRed)
        render(renderer, into: bitmap, frame: silent, artwork: artwork, frames: 1)
        XCTAssertFalse(pixel(bitmap, probe.x, probe.y).isRed, "第一幀不應瞬間跳到大圓盤")
        render(renderer, into: bitmap, frame: silent, artwork: artwork, frames: 120)
        XCTAssertTrue(pixel(bitmap, probe.x, probe.y).isRed)
    }

    func testCrossfadeKeepsThePreviousCoverWhileFading() throws {
        let red = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0)), kind: .cover)
        let blue = CenterArtwork(id: "blue", image: try solidImage(top: (0, 0, 255)), kind: .cover)
        let renderer = RadialRenderer()
        let bitmap = try RenderTestSupport.Bitmap()
        let silent = SpectrumFrame.silent(bandCount: 64)
        render(renderer, into: bitmap, frame: silent, artwork: red, frames: 120)
        XCTAssertTrue(pixel(bitmap, 160, 60).isRed)
        render(renderer, into: bitmap, frame: silent, artwork: blue, frames: 1)
        let start = pixel(bitmap, 160, 60)
        XCTAssertGreaterThan(start.red, 180, "剛換圖時舊封面仍在")
        render(renderer, into: bitmap, frame: silent, artwork: blue, frames: 9)
        let middle = pixel(bitmap, 160, 60)
        XCTAssertGreaterThan(middle.red, 30)
        XCTAssertGreaterThan(middle.blue, 30)
        render(renderer, into: bitmap, frame: silent, artwork: blue, frames: 20)
        XCTAssertTrue(pixel(bitmap, 160, 60).isBlue, "0.5 秒後應完全換成新封面")
    }

    // MARK: - App 圖示

    func testAppIconIsDrawnUnclippedAtAboutOneQuarterMoreThanTheCoreRadius() throws {
        let artwork = CenterArtwork(id: "icon:test", image: try solidImage(top: (255, 0, 0)), kind: .appIcon)
        let bitmap = try RenderTestSupport.Bitmap()
        render(RadialRenderer(), into: bitmap, frame: .silent(bandCount: 64), artwork: artwork, frames: 180)
        // 邊長 1.25 × 30.4 = 38：方形 [141, 179] × [41, 79]。四角（距中心約 24.7 pt）仍是圖示，表示沒有被裁成圓形。
        XCTAssertTrue(pixel(bitmap, 160, 60).isRed)
        XCTAssertTrue(pixel(bitmap, 177, 77).isRed)
        XCTAssertTrue(pixel(bitmap, 142, 42).isRed)
        XCTAssertTrue(pixel(bitmap, 177, 42).isRed)
        // 方形外、封面圓形內的位置不是圖示。
        XCTAssertFalse(pixel(bitmap, 180, 60).isRed)
        XCTAssertFalse(pixel(bitmap, 160, 81).isRed)
        XCTAssertFalse(pixel(bitmap, 139, 60).isRed)
    }

    // MARK: - 沒有圖片時與原本相同

    func testNilArtworkIsPixelIdenticalToARendererThatNeverSawArtwork() throws {
        let artwork = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0)), kind: .cover)
        for thumbnail in [false, true] {
            let fresh = RadialRenderer()
            let used = RadialRenderer()
            let freshBitmap = try RenderTestSupport.Bitmap(scale: 2)
            let usedBitmap = try RenderTestSupport.Bitmap(scale: 2)
            var step = 0
            while step < 90 {
                used.draw(in: usedBitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(),
                          options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, scale: 2, dt: Self.dt, artwork: artwork))
                step += 1
            }
            // 拿掉圖片後 4 秒：淡出（0.35 s）與縮回（時間常數 0.25 s）都已收斂。
            step = 0
            while step < 240 {
                used.draw(in: usedBitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(),
                          options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, scale: 2, dt: Self.dt))
                step += 1
            }
            for check in [loudFrame(7), SpectrumFrame.silent(bandCount: 64), RenderTestSupport.frame(level: 1)] {
                let options = RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, scale: 2, dt: Self.dt)
                fresh.draw(in: freshBitmap.context, size: Self.size, frame: check, look: VisualizerConfig.Look(), options: options)
                used.draw(in: usedBitmap.context, size: Self.size, frame: check, look: VisualizerConfig.Look(), options: options)
                XCTAssertTrue(snapshot(freshBitmap) == snapshot(usedBitmap), "thumbnail=\(thumbnail) bass=\(check.bass)")
            }
        }
    }

    // MARK: - 靜音靜止

    func testSilenceWithArtworkSettlesToAStaticImage() throws {
        let silent = RenderTestSupport.frame(level: 0)
        for kind in [CenterArtwork.Kind.cover, .appIcon] {
            let artwork = CenterArtwork(id: "art", image: try solidImage(top: (255, 0, 0), bottom: (0, 0, 255)), kind: kind)
            let renderer = RadialRenderer()
            let bitmap = try RenderTestSupport.Bitmap(scale: 2)
            var step = 0
            while step < 60 {
                renderer.draw(in: bitmap.context, size: Self.size, frame: loudFrame(step), look: VisualizerConfig.Look(),
                              options: RenderOptions(fade: RenderTestSupport.fade, scale: 2, dt: Self.dt, artwork: artwork))
                step += 1
            }
            render(renderer, into: bitmap, frame: silent, artwork: artwork, frames: 180)
            let settled = snapshot(bitmap)
            // 不同 dt（含 0 與上限外的值）都不應再改變畫面。
            for dt in [Self.dt, 0, 0.05, 0.5] {
                render(renderer, into: bitmap, frame: silent, artwork: artwork, frames: 20, dt: dt)
                XCTAssertTrue(snapshot(bitmap) == settled, "\(kind) dt=\(dt) 靜音時畫面仍在變")
            }
        }
    }

    func testBassPulsesTheCoverGently() throws {
        let artwork = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0)), kind: .cover)
        let renderer = RadialRenderer()
        let bitmap = try RenderTestSupport.Bitmap()
        render(renderer, into: bitmap, frame: .silent(bandCount: 64), artwork: artwork, frames: 180)
        // 封面半徑 28.4；bass=1 時 32.4 × 1.04 − 4 ≈ 29.7。
        XCTAssertFalse(pixel(bitmap, 160, 60 - 30).isRed)
        var pulsing = SpectrumFrame.silent(bandCount: 64)
        pulsing.bass = 1
        render(renderer, into: bitmap, frame: pulsing, artwork: artwork, frames: 1)
        XCTAssertTrue(pixel(bitmap, 160, 60 - 29).isRed)
        XCTAssertFalse(pixel(bitmap, 160, 60 - 32).isRed, "脈動不超過約 4%")
    }

    // MARK: - 效能

    /// 與 RenderPerformanceTests 相同的 Debug 預算（520×200 pt @2x，4 ms/幀）；交叉淡入時同時畫兩張 256 px 封面。
    func testArtworkStaysWithinTheRadialDebugBudget() throws {
        let size = CGSize(width: 520, height: 200)
        let first = CenterArtwork(id: "a", image: try solidImage(top: (255, 0, 0), bottom: (0, 0, 255), side: 256), kind: .cover)
        let second = CenterArtwork(id: "b", image: try solidImage(top: (0, 255, 0), side: 256), kind: .cover)
        let bitmap = try RenderTestSupport.Bitmap(size: size, scale: 2)
        let renderer = RadialRenderer()
        var step = 0
        while step < 5 {
            renderer.draw(in: bitmap.context, size: size, frame: RenderTestSupport.frame(), look: VisualizerConfig.Look(),
                          options: RenderOptions(fade: RenderTestSupport.fade, scale: 2, dt: Self.dt, artwork: first))
            step += 1
        }
        let start = ProcessInfo.processInfo.systemUptime
        step = 0
        while step < 60 {
            // 每 20 幀換一次圖，讓大部分時間都在交叉淡入（最耗時的情況）。
            let artwork = (step / 20) % 2 == 0 ? second : first
            renderer.draw(in: bitmap.context, size: size, frame: loudFrame(step), look: VisualizerConfig.Look(),
                          options: RenderOptions(fade: RenderTestSupport.fade, scale: 2, dt: Self.dt, artwork: artwork))
            step += 1
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 60
        print("RenderRadialArtworkTests radial+artwork: \(String(format: "%.2f", average)) ms/frame (Debug, 520x200 @2x)")
        XCTAssertLessThanOrEqual(average, 4.0)
    }

    // MARK: - 穩健性

    func testArtworkSurvivesOddSizesFramesAndTimeSteps() throws {
        let artwork = CenterArtwork(id: "red", image: try solidImage(top: (255, 0, 0), side: 1), kind: .cover)
        let icon = CenterArtwork(id: "icon", image: try solidImage(top: (0, 255, 0), side: 3), kind: .appIcon)
        let renderer = RadialRenderer()
        let frames = [
            SpectrumFrame(values: [], peaks: [], bass: 0),
            SpectrumFrame(values: [1, 0.5], peaks: [1], bass: 1),
            SpectrumFrame(values: [Float](repeating: .nan, count: 64), peaks: [Float](repeating: .infinity, count: 64), bass: .nan),
            RenderTestSupport.frame(level: 1),
        ]
        for size in [Self.size, CGSize(width: 4, height: 4), CGSize(width: 40, height: 12)] {
            let bitmap = try RenderTestSupport.Bitmap(size: size)
            for frame in frames {
                for dt in [0, Self.dt, 5, -1, .nan, .infinity] {
                    for art in [artwork, icon, nil] {
                        for thumbnail in [false, true] {
                            renderer.draw(in: bitmap.context, size: size, frame: frame, look: VisualizerConfig.Look(),
                                          options: RenderOptions(isThumbnail: thumbnail, fade: RenderTestSupport.fade, dt: dt, artwork: art))
                        }
                    }
                }
            }
        }
    }
}
