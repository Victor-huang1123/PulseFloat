import Foundation
import PulseFloatCore
import XCTest

@MainActor
final class LiveSpectrumSourceTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameDt = 1.0 / 60

    /// 寫入一段 1171.875 Hz（48 kHz/4096 的 bin 100，落在預設 band 37）的正弦。
    private func writeSine(_ ring: SampleRingBuffer, seconds: Double, amplitude: Float, phase: inout Int) {
        let count = Int(seconds * sampleRate)
        var chunk = [Float](repeating: 0, count: count)
        for index in 0..<count {
            chunk[index] = amplitude * Float(sin(2 * Double.pi * 1171.875 * Double(phase + index) / sampleRate))
        }
        phase += count
        chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: count) }
    }

    private func writeSilence(_ ring: SampleRingBuffer, seconds: Double) {
        let chunk = [Float](repeating: 0, count: Int(seconds * sampleRate))
        chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: chunk.count) }
    }

    private func maxValue(_ frame: SpectrumFrame) -> Float { frame.values.max() ?? 0 }

    func testStartsSilentAndStaysFlatWithoutAudio() {
        let source = LiveSpectrumSource(ring: SampleRingBuffer(), sampleRate: sampleRate)
        XCTAssertEqual(source.mode, .silent)
        var frame = source.nextFrame(dt: 0)
        for _ in 0..<120 { frame = source.nextFrame(dt: frameDt) }
        XCTAssertEqual(source.mode, .silent)
        XCTAssertEqual(frame.bandCount, 64)
        XCTAssertEqual(maxValue(frame), 0, "沒有聲音時不能有任何跳動")
        XCTAssertEqual(frame.peaks.max() ?? 0, 0)
    }

    func testAudibleInputSwitchesToLiveAndPeaksAtTheSineBand() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var phase = 0
        var frame = source.nextFrame(dt: 0)
        for _ in 0..<40 {
            writeSine(ring, seconds: frameDt, amplitude: 0.5, phase: &phase)
            frame = source.nextFrame(dt: frameDt)
        }
        XCTAssertEqual(source.mode, .live)
        let loudest = frame.values.indices.max { frame.values[$0] < frame.values[$1] }
        XCTAssertNotNil(loudest)
        // 空間平滑會把能量帶到鄰近頻帶；最高點必須在 band 37 附近。
        XCTAssertTrue((36...38).contains(loudest ?? -1), "loudest band = \(String(describing: loudest))")
        XCTAssertGreaterThan(frame.values[37], frame.values[10] + 0.3)
    }

    func testDigitalSilenceDropsBarsToZeroAndReportsSilentAfterTwoSeconds() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var phase = 0
        for _ in 0..<20 {
            writeSine(ring, seconds: frameDt, amplitude: 0.5, phase: &phase)
            _ = source.nextFrame(dt: frameDt)
        }
        XCTAssertEqual(source.mode, .live)
        var frame = source.nextFrame(dt: 0)
        // 1.9 秒的靜音：柱子已經落下，但狀態仍是 live（歌曲之間的短暫停頓不改選單文字）。
        for _ in 0..<114 {
            writeSilence(ring, seconds: frameDt)
            frame = source.nextFrame(dt: frameDt)
        }
        XCTAssertEqual(source.mode, .live)
        XCTAssertLessThan(maxValue(frame), 0.01, "靜音後柱子要落下")
        for _ in 0..<12 {
            writeSilence(ring, seconds: frameDt)
            frame = source.nextFrame(dt: frameDt)
        }
        XCTAssertEqual(source.mode, .silent)
        XCTAssertLessThan(maxValue(frame), 0.001)
        // 有聲音後立即恢復。
        writeSine(ring, seconds: 0.1, amplitude: 0.5, phase: &phase)
        frame = source.nextFrame(dt: frameDt)
        XCTAssertEqual(source.mode, .live)
        XCTAssertGreaterThan(maxValue(frame), 0.05)
    }

    func testStalledInputFeedsSilenceInsteadOfFreezingOnOldAudio() {
        // tap 停止（沒有新樣本）時，即使緩衝裡留著有聲音的資料，柱子也要落下。
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var phase = 0
        writeSine(ring, seconds: 0.2, amplitude: 0.5, phase: &phase)
        var frame = source.nextFrame(dt: frameDt)
        XCTAssertEqual(source.mode, .live)
        for _ in 0..<160 { frame = source.nextFrame(dt: frameDt) }
        XCTAssertEqual(source.mode, .silent)
        XCTAssertLessThan(maxValue(frame), 0.001)
    }

    func testVeryQuietInputBelowMinus90DbfsIsSilence() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var phase = 0
        var frame = source.nextFrame(dt: 0)
        for _ in 0..<150 {
            writeSine(ring, seconds: frameDt, amplitude: 2e-5, phase: &phase) // ≈ −94 dBFS
            frame = source.nextFrame(dt: frameDt)
        }
        XCTAssertEqual(source.mode, .silent)
        XCTAssertEqual(maxValue(frame), 0, "低於 gate 的訊號不顯示")
    }

    func testSampleRateAndBandConfigurationUpdates() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        source.setSampleRate(44_100)
        XCTAssertEqual(source.sampleRate, 44_100)
        source.setSampleRate(-1)
        source.setSampleRate(.nan)
        XCTAssertEqual(source.sampleRate, 44_100)

        var config = VisualizerConfig.default
        config.bands.count = 32
        source.setConfig(config)
        var phase = 0
        writeSine(ring, seconds: 0.2, amplitude: 0.5, phase: &phase)
        let frame = source.nextFrame(dt: frameDt)
        XCTAssertEqual(frame.bandCount, 32)
        XCTAssertEqual(frame.peaks.count, 32)
    }

    func testFramesStayFiniteAndInRange() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var phase = 0
        for step in 0..<200 {
            if step % 3 == 0 { writeSine(ring, seconds: frameDt, amplitude: 1, phase: &phase) }
            let frame = source.nextFrame(dt: step % 7 == 0 ? 0 : frameDt)
            for value in frame.values + frame.peaks + [frame.bass] {
                XCTAssertTrue(value.isFinite && value >= 0 && value <= 1.0001, "out of range: \(value)")
            }
        }
    }
}
