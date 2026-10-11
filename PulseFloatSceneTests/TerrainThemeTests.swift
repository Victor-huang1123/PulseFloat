import PulseFloatCore
@testable import PulseFloatScene
import XCTest

/// 音訊地形專屬的測試：空間核（低頻寬、高頻窄）、歷史緩衝隨音訊時鐘捲動並在靜音時凍結、
/// 新切片從前面出現往後退、起音標記、畫質改變解析度且保留地景、兩種外觀都畫得出來。
@MainActor
final class TerrainThemeTests: XCTestCase {
    private let dt = 1.0 / 60

    private func features(time: Double, activity: Float = 1, onset: Float = 0) -> AudioFeatures {
        var f = AudioFeatures()
        f.activity = activity
        f.time = time
        f.onsetEnvelope = onset
        return f
    }

    private func frame(_ values: [Float], time: Double, activity: Float = 1, onset: Float = 0) -> SpectrumFrame {
        SpectrumFrame(values: values, peaks: values, bass: 0, features: features(time: time, activity: activity, onset: onset))
    }

    /// 單一頻段的脈衝。
    private func impulse(at band: Int, count: Int = 64) -> [Float] {
        var values = [Float](repeating: 0, count: count)
        values[band] = 1
        return values
    }

    /// 即時列高於最大值一半的欄數。
    private func halfWidth(_ row: [Float]) -> Int {
        let peak = row.max() ?? 0
        return row.filter { $0 > peak * 0.5 }.count
    }

    func testKernelSumsToOneAndIsBroadInTheBassAndNarrowInTheTreble() {
        let kernel = TerrainKernel(columns: 128, bands: 64)
        var j = 0
        while j < 128 {
            var sum: Float = 0
            var t = 0
            while t < kernel.count[j] { sum += kernel.weights[j * kernel.taps + t]; t += 1 }
            XCTAssertEqual(sum, 1, accuracy: 1e-3, "第 \(j) 欄的權重總和")
            j += 1
        }
        XCTAssertGreaterThan(TerrainKernel.sigma(u: 0, bands: 64), 4 * TerrainKernel.sigma(u: 1, bands: 64))
        // 容忍任何頻段數（包括 0 與 1）。
        XCTAssertEqual(TerrainKernel(columns: 64, bands: 0).count.reduce(0, +), 0)
        XCTAssertEqual(TerrainKernel(columns: 64, bands: 1).count.first, 1)
    }

    func testBassFormsBroadMountainsAndTrebleFineRidges() {
        let bass = TerrainHistory(columns: 128, rows: 96, rowsPerSecond: 24, lineStep: 3, device: nil)
        let treble = TerrainHistory(columns: 128, rows: 96, rowsPerSecond: 24, lineStep: 3, device: nil)
        var time = 0.0
        var i = 0
        while i < 120 {
            time += dt
            _ = bass.advance(values: impulse(at: 6), features: features(time: time), dt: dt)
            _ = treble.advance(values: impulse(at: 56), features: features(time: time), dt: dt)
            i += 1
        }
        let bassWidth = halfWidth(bass.live), trebleWidth = halfWidth(treble.live)
        XCTAssertGreaterThanOrEqual(bassWidth, 3 * trebleWidth, "低頻 \(bassWidth) 欄、高頻 \(trebleWidth) 欄")
        // 低頻的山在左邊、高頻的稜線在右邊（對數頻率 X 軸）。
        XCTAssertLessThan(bass.live.firstIndex(of: bass.live.max() ?? 0) ?? 999, 32)
        XCTAssertGreaterThan(treble.live.firstIndex(of: treble.live.max() ?? 0) ?? 0, 100)
    }

    func testHistoryScrollsWithTheAudioClockAndFreezesInSilence() {
        let history = TerrainHistory(columns: 64, rows: 48, rowsPerSecond: 30, lineStep: 2, device: nil)
        let values = [Float](repeating: 0.5, count: 64)
        var time = 0.0
        var i = 0
        while i < 120 {            // 2 秒音訊
            time += dt
            XCTAssertTrue(history.advance(values: values, features: features(time: time), dt: dt))
            i += 1
        }
        XCTAssertEqual(Double(history.sliceCount), 60, accuracy: 2, "30 切片／音訊秒 × 2 秒")

        // 聲音漸弱（activity 0.5，音訊時鐘以一半速度前進）：地形進度 = 音訊時鐘 × activity²，
        // 2 秒只前進 2 × 0.5 × 0.25 = 0.25 音訊秒 → 約 7.5 個切片。
        let before = history.sliceCount
        i = 0
        while i < 120 {
            time += dt * 0.5
            _ = history.advance(values: values, features: features(time: time, activity: 0.5), dt: dt)
            i += 1
        }
        XCTAssertEqual(Double(history.sliceCount - before), 7.5, accuracy: 1.5)

        // 靜音：時鐘停止 → 不提交、不捲動、不改即時列，回報沒有變化。
        let frozen = (history.sliceCount, history.head, history.frac, history.live, history.value(k: 10, column: 20))
        i = 0
        while i < 240 {
            XCTAssertFalse(history.advance(values: impulse(at: 3), features: features(time: time, activity: 0), dt: dt))
            i += 1
        }
        XCTAssertEqual(history.sliceCount, frozen.0)
        XCTAssertEqual(history.head, frozen.1)
        XCTAssertEqual(history.frac, frozen.2)
        XCTAssertEqual(history.live, frozen.3)
        XCTAssertEqual(history.value(k: 10, column: 20), frozen.4)
    }

    func testNewSlicesAppearAtTheFrontAndRecedeIntoTheDepth() {
        let history = TerrainHistory(columns: 64, rows: 96, rowsPerSecond: 30, lineStep: 3, device: nil)
        var time = 0.0
        func play(_ values: [Float], seconds: Double, onset: Float = 0) {
            var elapsed = 0.0
            while elapsed < seconds - 1e-9 {
                time += dt
                elapsed += dt
                _ = history.advance(values: values, features: features(time: time, onset: onset), dt: dt)
            }
        }
        func strongestRow() -> Int {
            var best = 0
            var k = 0
            while k < history.rows {
                if history.value(k: k, column: 10) > history.value(k: best, column: 10) { best = k }
                k += 1
            }
            return best
        }
        func maxBeat(near k: Int) -> Float {
            var best: Float = 0
            var i = max(0, k - 4)
            while i <= min(history.rows - 1, k + 4) { best = max(best, history.beat(k: i)); i += 1 }
            return best
        }
        let loud = [Float](repeating: 0.9, count: 64)
        let quiet = [Float](repeating: 0, count: 64)
        play(quiet, seconds: 0.5)
        play(loud, seconds: 0.1, onset: 1)
        play(quiet, seconds: 0.3)
        let first = strongestRow()
        XCTAssertGreaterThan(first, 3, "響亮的切片已經離開最前面")
        XCTAssertGreaterThan(maxBeat(near: first), 0.1, "起音標記跟著那個切片")
        play(quiet, seconds: 1.0)
        let later = strongestRow()
        XCTAssertEqual(Double(later - first), 30, accuracy: 3, "1 音訊秒後往後退了約 30 列")
        XCTAssertGreaterThan(maxBeat(near: later), 0.1)
        XCTAssertLessThan(history.value(k: 0, column: 10), 0.05, "最前面是安靜的新切片")
    }

    func testMalformedValuesStayFiniteAndInRange() {
        let history = TerrainHistory(columns: 64, rows: 48, rowsPerSecond: 30, lineStep: 2, device: nil)
        let inputs: [[Float]] = [[], [1], [.nan, .infinity, -.infinity, -3, 7], [Float](repeating: .nan, count: 64)]
        var time = 0.0
        for values in inputs {
            var i = 0
            while i < 30 {
                time += dt
                _ = history.advance(values: values, features: features(time: time), dt: dt)
                i += 1
            }
            XCTAssertTrue(history.live.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(values)")
        }
        // 時鐘倒退或跳太多：重新同步，不會一次提交大量切片。
        let count = history.sliceCount
        _ = history.advance(values: [], features: features(time: time + 1000), dt: dt)
        _ = history.advance(values: [], features: features(time: 1), dt: dt)
        XCTAssertLessThanOrEqual(history.sliceCount - count, 6)
    }

    func testQualityChangesResolutionAndKeepsTheLandscape() throws {
        let renderer = try XCTUnwrap(SceneRenderer())
        renderer.setTheme(.terrain, settings: SceneSettings(quality: .low))
        let theme = try XCTUnwrap(renderer.theme as? TerrainTheme)
        let audio = DemoAudio(seed: 3)
        var i = 0
        while i < 180 { renderer.advance(frame: audio.next(dt: dt), dt: dt); i += 1 }
        XCTAssertEqual(theme.history?.columns, 64)
        XCTAssertEqual(theme.history?.rows, 48)
        renderer.apply(SceneSettings(quality: .high))
        let history = try XCTUnwrap(theme.history)
        XCTAssertEqual(history.columns, 128)
        XCTAssertEqual(history.rows, 160)
        XCTAssertNotNil(history.texture, "高度歷史放在 Metal 貼圖")
        var energy: Float = 0
        var k = 0
        while k < history.rows { energy += history.value(k: k, column: 20); k += 1 }
        XCTAssertGreaterThan(energy, 1, "換畫質時保留已經長出來的地形")
        renderer.apply(SceneSettings(quality: .medium))
        XCTAssertEqual(theme.history?.columns, 96)
        XCTAssertEqual(theme.history?.rows, 96)
        XCTAssertLessThan(TerrainLayout(SceneSettings(quality: .low)).rowsPerSecond,
                          TerrainLayout(SceneSettings(quality: .high)).rowsPerSecond)
    }

    func testBothVariantsDrawDifferentImagesAndFreezeInSilence() throws {
        var images: [TerrainSurface: SceneImage] = [:]
        for surface in TerrainSurface.allCases {
            for presentation in ScenePresentation.allCases {
                let renderer = try XCTUnwrap(SceneRenderer())
                renderer.setTheme(.terrain, settings: SceneSettings(presentation: presentation, terrainSurface: surface))
                let audio = DemoAudio(seed: 11)
                var i = 0
                while i < 150 { renderer.advance(frame: audio.next(dt: dt), dt: dt); i += 1 }
                let image = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 390, height: 150))
                XCTAssertGreaterThan(image.visibleRatio, 0.2, "\(surface) \(presentation)")
                if presentation == .compact { images[surface] = image }
                audio.program = .silence
                i = 0
                while i < 240 { renderer.advance(frame: audio.next(dt: dt), dt: dt); i += 1 }
                XCTAssertTrue(renderer.isAtRest, "\(surface) \(presentation)")
                let a = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 390, height: 150))
                i = 0
                while i < 30 { renderer.advance(frame: audio.next(dt: dt), dt: dt); i += 1 }
                let b = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 390, height: 150))
                XCTAssertTrue(a.pixels == b.pixels, "\(surface) \(presentation) 靜音時畫面仍在變")
            }
        }
        let wire = try XCTUnwrap(images[.wireframe]), surface = try XCTUnwrap(images[.surface])
        XCTAssertFalse(wire.pixels == surface.pixels, "線框與曲面應該不同")
    }

    func testSilenceBeforeAnyMusicShowsAFlatRestingLandscape() throws {
        let renderer = try XCTUnwrap(SceneRenderer())
        renderer.setTheme(.terrain, settings: SceneSettings())
        let image = try XCTUnwrap(renderer.renderOffscreen(frame: .silent(bandCount: 64), dt: dt, width: 390, height: 150))
        XCTAssertTrue(renderer.isAtRest)
        XCTAssertGreaterThan(image.visibleRatio, 0.1, "沒有聲音時仍然看得到平靜的地形網格")
    }
}
