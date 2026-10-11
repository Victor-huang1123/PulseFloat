import Foundation
import PulseFloatCore
import XCTest

/// 共用音訊特徵：端到端經過 SampleRingBuffer → LiveSpectrumSource（同一次 FFT）→ AudioFeatureExtractor。
@MainActor
final class AudioFeatureTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameDt = 1.0 / 60

    /// 每幀寫入一段交錯立體聲；generator(t) 回傳 (L, R)。
    private func run(_ source: LiveSpectrumSource, _ ring: SampleRingBuffer, seconds: Double, clock: inout Int,
                     _ generator: (Double) -> (Float, Float)) -> [SpectrumFrame] {
        var frames: [SpectrumFrame] = []
        let perFrame = Int(frameDt * sampleRate)
        var chunk = [Float](repeating: 0, count: perFrame * 2)
        var step = 0
        while Double(step) * frameDt < seconds {
            var i = 0
            while i < perFrame {
                let (l, r) = generator(Double(clock + i) / sampleRate)
                chunk[2 * i] = l
                chunk[2 * i + 1] = r
                i += 1
            }
            clock += perFrame
            chunk.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: perFrame, channelCount: 2) }
            frames.append(source.nextFrame(dt: frameDt))
            step += 1
        }
        return frames
    }

    private func sine(_ hz: Double, _ amplitude: Float) -> (Double) -> (Float, Float) {
        { t in let v = amplitude * Float(sin(2 * Double.pi * hz * t)); return (v, v) }
    }

    func testSilenceKeepsEveryFeatureAtZeroAndTheClockStopped() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var clock = 0
        let frames = run(source, ring, seconds: 1, clock: &clock) { _ in (0, 0) }
        let f = frames.last?.features ?? .silent
        XCTAssertEqual(f, AudioFeatures.silent)
        XCTAssertTrue(f.isSilent)
    }

    func testMusicThenSilenceSettlesToAStaticFeatureSet() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var clock = 0
        let loud = run(source, ring, seconds: 1.5, clock: &clock, sine(220, 0.5))
        let playing = loud.last?.features ?? .silent
        XCTAssertGreaterThan(playing.activity, 0.95)
        XCTAssertGreaterThan(playing.level, 0.5)
        XCTAssertGreaterThan(playing.time, 1.0)
        let quiet = run(source, ring, seconds: 3, clock: &clock) { _ in (0, 0) }
        let settled = quiet.last?.features ?? .silent
        XCTAssertTrue(settled.isSilent)
        XCTAssertEqual(settled.level, 0)
        XCTAssertEqual(settled.bass, 0)
        XCTAssertEqual(settled.mid, 0)
        XCTAssertEqual(settled.treble, 0)
        XCTAssertEqual(settled.energy, 0)
        XCTAssertEqual(settled.flux, 0)
        XCTAssertEqual(settled.onsetEnvelope, 0)
        XCTAssertEqual(settled.stereoWidth, 0)
        XCTAssertEqual(settled.balance, 0)
        // 靜止：再跑一秒，整組特徵（含 time 與 centroid）一模一樣。
        let later = run(source, ring, seconds: 1, clock: &clock) { _ in (0, 0) }.last?.features
        XCTAssertEqual(later, settled)
    }

    func testCentroidAndBandsFollowTheTone() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var clock = 0
        let low = run(source, ring, seconds: 1, clock: &clock, sine(80, 0.5)).last?.features ?? .silent
        let ring2 = SampleRingBuffer()
        let source2 = LiveSpectrumSource(ring: ring2, sampleRate: sampleRate)
        var clock2 = 0
        let high = run(source2, ring2, seconds: 1, clock: &clock2, sine(6000, 0.5)).last?.features ?? .silent
        XCTAssertLessThan(low.centroid, 0.3, "80 Hz 的重心應該很低")
        XCTAssertGreaterThan(high.centroid, 0.75, "6 kHz 的重心應該很高")
        XCTAssertGreaterThan(low.bass, low.treble + 0.2)
        XCTAssertGreaterThan(high.treble, high.bass + 0.2)
    }

    func testStereoWidthAndBalance() {
        func features(_ generator: @escaping (Double) -> (Float, Float)) -> AudioFeatures {
            let ring = SampleRingBuffer()
            let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
            var clock = 0
            return run(source, ring, seconds: 1.5, clock: &clock, generator).last?.features ?? .silent
        }
        let mono = features(sine(440, 0.4))
        XCTAssertLessThan(mono.stereoWidth, 0.02)
        XCTAssertEqual(mono.balance, 0, accuracy: 0.02)
        let left = features { t in (0.4 * Float(sin(2 * Double.pi * 440 * t)), 0) }
        XCTAssertLessThan(left.balance, -0.95)
        let right = features { t in (0, 0.4 * Float(sin(2 * Double.pi * 440 * t))) }
        XCTAssertGreaterThan(right.balance, 0.95)
        let wide = features { t in (0.4 * Float(sin(2 * Double.pi * 440 * t)), 0.4 * Float(sin(2 * Double.pi * 1250 * t))) }
        XCTAssertGreaterThan(wide.stereoWidth, 0.9, "左右不相關")
        let half = features { t in let a = 0.4 * Float(sin(2 * Double.pi * 440 * t)); return (a, 0.6 * a + 0.2 * Float(sin(2 * Double.pi * 1250 * t))) }
        XCTAssertTrue(half.stereoWidth > 0.05 && half.stereoWidth < 0.6, "部分相關：\(half.stereoWidth)")
    }

    func testOnsetsAreDetectedForBurstsButNotForASteadyTone() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var clock = 0
        // 每 0.5 秒一個 60 ms 的噪音鼓點，其餘時間是很小的底噪（仍算有聲音）。
        var seed: UInt32 = 12345
        let frames = run(source, ring, seconds: 4, clock: &clock) { t in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let inBurst = t.truncatingRemainder(dividingBy: 0.5) < 0.06
            let v = noise * (inBurst ? 0.6 : 0.002)
            return (v, v)
        }
        let onsets = frames.filter { $0.features.onset }.count
        XCTAssertGreaterThanOrEqual(onsets, 6, "8 個鼓點至少要抓到 6 個")
        XCTAssertLessThanOrEqual(onsets, 10, "不能把每一幀都當成起音")
        XCTAssertEqual(frames.last?.features.onsetCount, onsets)

        let ring2 = SampleRingBuffer()
        let source2 = LiveSpectrumSource(ring: ring2, sampleRate: sampleRate)
        var clock2 = 0
        let steady = run(source2, ring2, seconds: 3, clock: &clock2, sine(330, 0.4))
        let late = steady.dropFirst(60).filter { $0.features.onset }.count
        XCTAssertEqual(late, 0, "穩定的長音在開頭之後不應該再有起音")
    }

    func testFeaturesStayFiniteAndInRange() {
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(ring: ring, sampleRate: sampleRate)
        var clock = 0
        let frames = run(source, ring, seconds: 2, clock: &clock) { t in
            (Float(sin(t * 900)) * 0.9 + Float(sin(t * 77)) * 0.3, Float(sin(t * 1500)) * 0.7)
        }
        for frame in frames {
            let f = frame.features
            for v in [f.level, f.peak, f.bass, f.mid, f.treble, f.centroid, f.flux, f.onsetEnvelope, f.stereoWidth, f.energy, f.activity] {
                XCTAssertTrue(v.isFinite && v >= 0 && v <= 1, "\(f)")
            }
            XCTAssertTrue(f.balance >= -1 && f.balance <= 1)
        }
    }

    func testExtractorIgnoresZeroAndNonFiniteDt() {
        let extractor = AudioFeatureExtractor()
        let before = extractor.features
        extractor.update(dt: 0, audible: true, binDb: nil, binHz: 11.7, mid: nil, side: nil, bands: [1, 1], bandCenters: [100, 5000])
        extractor.update(dt: .nan, audible: true, binDb: nil, binHz: 11.7, mid: nil, side: nil, bands: [1, 1], bandCenters: [100, 5000])
        XCTAssertEqual(extractor.features, before)
    }

    func testRingSideChannelCarriesLeftMinusRight() {
        let ring = SampleRingBuffer(capacity: 1024)
        let stereo: [Float] = [1, 0, 0.5, 0.5, 0, 1, -1, 1]
        stereo.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 4, channelCount: 2) }
        var mid = [Float](repeating: 9, count: 4)
        var side = [Float](repeating: 9, count: 4)
        mid.withUnsafeMutableBufferPointer { m in
            side.withUnsafeMutableBufferPointer { s in
                _ = ring.copyLatest(into: m.baseAddress!, side: s.baseAddress, count: 4)
            }
        }
        XCTAssertEqual(mid, [0.5, 0.5, 0.5, 0])
        XCTAssertEqual(side, [0.5, 0, -0.5, -1])
        let mono: [Float] = [0.25, 0.25]
        mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 2) }
        side.withUnsafeMutableBufferPointer { s in
            mid.withUnsafeMutableBufferPointer { m in _ = ring.copyLatest(into: m.baseAddress!, side: s.baseAddress, count: 2) }
        }
        XCTAssertEqual(Array(side.prefix(2)), [0, 0], "單聲道寫入時 side 為 0")
    }
}
