import Foundation
import XCTest
@testable import PulseFloatCore

final class SpectrumPipelineTests: XCTestCase {
    func testAttackAtOneTimeConstantMatchesExponentialResponse() {
        let pipeline = SpectrumPipeline(config: fixedConfig())
        fill(pipeline, with: -20)

        let frame = pipeline.process(dt: 0.012)
        let expected = Float((46.0 / 54.0) * (1 - exp(-1.0)))
        for value in frame.values {
            // 任務單容許 1%；使用更緊的 1e-6，保留 Float 寫回誤差。
            XCTAssertEqual(value, expected, accuracy: 1e-6)
        }
    }

    func testGateUsesUncompensatedInputEvenWhenItIsAboveNormalizationFloor() {
        var config = fixedConfig()
        config.level.ceilingDb = -40
        config.level.rangeDb = 84
        config.bands.tiltDbPerOct = 6
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -100)

        // floor 是 −124 dB，raw −100 仍因 gate −90 而全部歸零。
        XCTAssertEqual(pipeline.process(dt: 1), .silent(bandCount: 64))
    }

    func testInputExactlyAtGateIsNotSilenced() {
        var config = fixedConfig()
        config.level.ceilingDb = -40
        config.level.rangeDb = 84
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -90)

        let frame = pipeline.process(dt: 1)
        // raw == gate，仍以 (−90 − (−124)) / 84 正規化；1 秒後 attack 已收斂。
        XCTAssertEqual(frame.bandCount, 64)
        for value in frame.values {
            XCTAssertEqual(value, Float(34.0 / 84.0), accuracy: 1e-6)
        }
    }

    func testNonAdvancingTimePreservesFrameAndAGCTracking() {
        let pipeline = SpectrumPipeline(config: .default)
        fill(pipeline, with: -20)
        let previous = pipeline.process(dt: 0.1)
        let previousCeiling = pipeline.ceilingDb
        fill(pipeline, with: 20)

        for dt in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(pipeline.process(dt: dt), previous)
            XCTAssertEqual(pipeline.ceilingDb, previousCeiling)
        }

        var config = VisualizerConfig.default
        config.level.agc = false
        config.level.ceilingDb = -30
        pipeline.setConfig(config)
        // 即使有新的固定 ceiling，非有限 dt 仍然完全不改狀態。
        for dt in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(pipeline.process(dt: dt), previous)
            XCTAssertEqual(pipeline.ceilingDb, previousCeiling)
        }
        XCTAssertEqual(pipeline.process(dt: 0), previous)
        XCTAssertEqual(pipeline.ceilingDb, -30)
        _ = pipeline.process(dt: 1.0 / 60)
        XCTAssertEqual(pipeline.ceilingDb, -30)
    }

    func testFixedCeilingIsAppliedAtZeroOrNegativeDeltaTime() {
        var config = fixedConfig()
        config.level.ceilingDb = -30
        let pipeline = SpectrumPipeline(config: config)
        XCTAssertEqual(pipeline.process(dt: 0), .silent(bandCount: 64))
        XCTAssertEqual(pipeline.ceilingDb, -30)

        config.level.ceilingDb = -35
        pipeline.setConfig(config)
        XCTAssertEqual(pipeline.process(dt: -1), .silent(bandCount: 64))
        XCTAssertEqual(pipeline.ceilingDb, -35)
    }

    func testPeakHoldsThenFallsAndNeverDropsBelowValue() {
        var config = fixedConfig()
        config.motion.releaseMs = 40
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -20)
        let raised = pipeline.process(dt: 0.2)
        fill(pipeline, with: -160)

        for _ in 0..<3 {
            let frame = pipeline.process(dt: 0.05)
            XCTAssertEqual(frame.peaks, raised.peaks)
            XCTAssertLessThan(frame.values[0], raised.values[0])
        }
        let falling = pipeline.process(dt: 0.05)
        XCTAssertLessThan(falling.peaks[0], raised.peaks[0])
        for _ in 0..<100 {
            let frame = pipeline.process(dt: 1.0 / 60)
            for index in 0..<frame.bandCount {
                XCTAssertGreaterThanOrEqual(frame.peaks[index], frame.values[index])
            }
        }
    }

    func testPeakDoesNotFallAtExactHoldDuration() {
        var config = fixedConfig()
        config.motion.peakHoldMs = 125
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -20)
        let raised = pipeline.process(dt: 1)
        fill(pipeline, with: -160)

        // 0.125 可由 Float 精確表示，直接區分 > 與 >= 的邊界行為。
        let held = pipeline.process(dt: 0.125)
        XCTAssertEqual(held.peaks, raised.peaks)
        for index in 0..<held.bandCount {
            XCTAssertGreaterThan(raised.peaks[index], 0)
            XCTAssertLessThan(held.values[index], raised.values[index])
        }
    }

    func testBandCenteredExactlyAt150HzDoesNotContributeToBass() throws {
        var config = fixedConfig()
        config.bands.count = 16
        config.bands.fMinHz = 30
        config.bands.fMaxHz = 30 * pow(5, 32.0 / 9.0)
        let pipeline = SpectrumPipeline(config: config)
        let center = try XCTUnwrap(pipeline.bandLayout.center.dropFirst(4).first)
        XCTAssertEqual(Float(center), 150)
        pipeline.withRawDb { raw in
            for index in raw.indices { raw[index] = index == 4 ? -12 : -160 }
        }

        let frame = pipeline.process(dt: 1)
        XCTAssertEqual(frame.bandCount, 16)
        XCTAssertEqual(try XCTUnwrap(frame.values.dropFirst(4).first), 1, accuracy: 1e-6)
        XCTAssertEqual(frame.bass, 0)
    }

    func testFixedCeilingUsesConfiguredValue() {
        var config = fixedConfig()
        config.level.ceilingDb = -22
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -20)
        _ = pipeline.process(dt: 1.0 / 60)
        XCTAssertEqual(pipeline.ceilingDb, -22)
    }

    func testAGCClampsAtBothLimits() {
        let pipeline = SpectrumPipeline(config: .default)
        fill(pipeline, with: -160)
        for _ in 0..<400 { _ = pipeline.process(dt: 1.0 / 60) }
        XCTAssertEqual(pipeline.ceilingDb, -45)

        fill(pipeline, with: 20)
        for _ in 0..<60 { _ = pipeline.process(dt: 1.0 / 60) }
        XCTAssertEqual(pipeline.ceilingDb, 6)
    }

    func testEachBandGeometrySettingResetsStateAndRawInput() {
        for parameter in 0..<3 {
            let pipeline = SpectrumPipeline(config: .default)
            fill(pipeline, with: 20)
            _ = pipeline.process(dt: 0.2)
            fill(pipeline, with: -160)
            _ = pipeline.process(dt: 0.3)
            fill(pipeline, with: -25)

            var config = VisualizerConfig.default
            switch parameter {
            case 0: config.bands.count = 32
            case 1: config.bands.fMinHz = 60
            default: config.bands.fMaxHz = 12000
            }
            pipeline.setConfig(config)
            XCTAssertEqual(pipeline.bandLayout.count, config.bands.count)
            XCTAssertEqual(pipeline.process(dt: 0), .silent(bandCount: config.bands.count))
            XCTAssertEqual(pipeline.ceilingDb, -12)
            pipeline.withRawDb { raw in
                XCTAssertEqual(raw.count, config.bands.count)
                for value in raw { XCTAssertEqual(value, -160) }
            }

            // 和全新管線重播相同訊號；連峰值計時、速度等隱藏狀態也應重置。
            let fresh = SpectrumPipeline(config: config)
            for index in 0..<30 {
                let raw: Float = index < 5 ? -20 : -160
                fill(pipeline, with: raw)
                fill(fresh, with: raw)
                XCTAssertEqual(pipeline.process(dt: 0.05), fresh.process(dt: 0.05))
                XCTAssertEqual(pipeline.ceilingDb, fresh.ceilingDb)
            }
        }
    }

    func testReleaseSettingPreservesExistingStateAndRawInput() {
        let pipeline = SpectrumPipeline(config: .default)
        fill(pipeline, with: -20)
        let previous = pipeline.process(dt: 0.1)
        let previousCeiling = pipeline.ceilingDb
        var config = VisualizerConfig.default
        config.motion.releaseMs = 300
        pipeline.setConfig(config)

        XCTAssertEqual(pipeline.process(dt: 0), previous)
        XCTAssertEqual(pipeline.ceilingDb, previousCeiling)
        pipeline.withRawDb { raw in
            for value in raw { XCTAssertEqual(value, -20) }
        }
    }

    func testOtherNonGeometrySettingsPreserveState() {
        let pipeline = SpectrumPipeline(config: .default)
        fill(pipeline, with: -20)
        let previous = pipeline.process(dt: 0.1)
        let previousCeiling = pipeline.ceilingDb
        var config = VisualizerConfig.default
        config.bands.tiltDbPerOct = 6
        config.level.gamma = 2
        config.motion.spatial = 0.6
        config.look.theme = .radial
        config.menubar.colored = true
        pipeline.setConfig(config)

        XCTAssertEqual(pipeline.process(dt: 0), previous)
        XCTAssertEqual(pipeline.ceilingDb, previousCeiling)
    }

    func testClampsInvalidConfigAtInitializationAndUpdate() throws {
        var invalid = fixedConfig()
        invalid.bands.count = -1
        invalid.bands.fMinHz = 0
        invalid.bands.fMaxHz = .nan
        invalid.level.rangeDb = 0
        invalid.level.gamma = .infinity
        invalid.motion.attackMs = 0
        invalid.motion.releaseMs = .nan
        let pipeline = SpectrumPipeline(config: invalid)
        XCTAssertEqual(pipeline.bandLayout.count, 16)
        XCTAssertEqual(try XCTUnwrap(pipeline.bandLayout.lo.first), 20)
        fill(pipeline, with: -20)
        assertFiniteFrame(pipeline.process(dt: 1.0 / 60))

        invalid.bands.count = 1000
        invalid.bands.fMinHz = .infinity
        invalid.level.rangeDb = .nan
        pipeline.setConfig(invalid)
        XCTAssertEqual(pipeline.bandLayout.count, 128)
        XCTAssertEqual(try XCTUnwrap(pipeline.bandLayout.lo.first), 120)
        fill(pipeline, with: -20)
        assertFiniteFrame(pipeline.process(dt: 1.0 / 60))
    }

    func testNonfiniteRawIsSilenceAndExtremeDeltaTimeStaysFinite() {
        let pipeline = SpectrumPipeline(config: .default)
        pipeline.withRawDb { raw in
            for index in raw.indices {
                raw[index] = index % 3 == 0 ? .nan : index % 3 == 1 ? .infinity : -.infinity
            }
        }
        XCTAssertEqual(pipeline.process(dt: 0.1), .silent(bandCount: 64))
        fill(pipeline, with: 20)
        assertFiniteFrame(pipeline.process(dt: 0.1))
        fill(pipeline, with: -160)
        assertFiniteFrame(pipeline.process(dt: Double.greatestFiniteMagnitude))
        XCTAssertEqual(pipeline.ceilingDb, -45)
        assertFiniteFrame(pipeline.process(dt: 1.0 / 60))
    }

    func testSpatialSmoothingUsesOriginalNeighborsAndClampsEdges() {
        var config = fixedConfig()
        config.motion.spatial = 0.4
        let pipeline = SpectrumPipeline(config: config)
        fill(pipeline, with: -66)
        pipeline.withRawDb { raw in
            raw[0] = -12
            raw[3] = -12
            raw[raw.count - 1] = -12
        }
        let frame = pipeline.process(dt: 1)
        // attack 的指數項在此精度下為 0：只有相鄰柱平滑，且不可重複使用已平滑的值。
        XCTAssertEqual(frame.values[0], 0.8, accuracy: 1e-6)
        XCTAssertEqual(frame.values[1], 0.2, accuracy: 1e-6)
        XCTAssertEqual(frame.values[2], 0.2, accuracy: 1e-6)
        XCTAssertEqual(frame.values[3], 0.6, accuracy: 1e-6)
        XCTAssertEqual(frame.values[4], 0.2, accuracy: 1e-6)
        XCTAssertEqual(frame.values[5], 0, accuracy: 1e-6)
        XCTAssertEqual(frame.values[frame.bandCount - 2], 0.2, accuracy: 1e-6)
        XCTAssertEqual(frame.values[frame.bandCount - 1], 0.8, accuracy: 1e-6)
    }

    func testReturnedFramesRemainIndependentAcrossProcessingAndCallerMutation() {
        let pipeline = SpectrumPipeline(config: fixedConfig())
        fill(pipeline, with: -20)
        let first = pipeline.process(dt: 0.1)
        let retained = first
        var modified = first
        modified.values[0] = 0
        modified.peaks[0] = 0
        XCTAssertNotEqual(modified, first)
        XCTAssertEqual(pipeline.process(dt: 0), retained)
        fill(pipeline, with: -160)
        let next = pipeline.process(dt: 0.1)
        XCTAssertEqual(first, retained)
        XCTAssertLessThan(next.values[0], first.values[0])
    }

    private func fixedConfig() -> VisualizerConfig {
        var config = VisualizerConfig.default
        config.level.agc = false
        config.level.gamma = 1
        config.bands.tiltDbPerOct = 0
        config.motion.spatial = 0
        return config
    }

    private func fill(_ pipeline: SpectrumPipeline, with value: Float) {
        pipeline.withRawDb { raw in
            for index in raw.indices { raw[index] = value }
        }
    }

    private func assertFiniteFrame(_ frame: SpectrumFrame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(frame.bass.isFinite, file: file, line: line)
        XCTAssertTrue((0...1).contains(frame.bass), file: file, line: line)
        for value in frame.values + frame.peaks {
            XCTAssertTrue(value.isFinite, file: file, line: line)
            XCTAssertTrue((0...1).contains(value), file: file, line: line)
        }
    }
}
