import Foundation
import PulseFloatCore
import XCTest

final class SpectrumAnalyzerTests: XCTestCase {
    private let fftSize = 4096
    private let sampleRate = 48_000.0

    private var defaultLayout: BandLayout {
        BandLayout(count: 64, fMinHz: 30, fMaxHz: 16_000)
    }

    private func sine(bin: Int, amplitude: Float = 1, count: Int = 4096) -> [Float] {
        (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * Double(bin * index) / Double(fftSize)))
        }
    }

    private func analyze(_ samples: [Float], using analyzer: SpectrumAnalyzer, count: Int = 64) -> [Float] {
        var output = [Float](repeating: 123, count: count)
        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { bands in
                analyzer.analyze(samples: input, into: bands)
            }
        }
        return output
    }

    func testBinCenteredSineHasCalibratedDbFS() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let fullScale = analyze(sine(bin: 100), using: analyzer)
        let tenthScale = analyze(sine(bin: 100, amplitude: 0.1), using: analyzer)
        // 1171.875 Hz lies in default band 37. SPEC allows 0.5 dB calibration error.
        XCTAssertEqual(fullScale[37], 0, accuracy: 0.5)
        XCTAssertEqual(tenthScale[37], -20, accuracy: 0.5)
    }

    func testSilenceAndEmptyInputProduceFiniteSilence() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        _ = analyze(sine(bin: 100), using: analyzer)
        for samples in [[Float](repeating: 0, count: fftSize), []] {
            let output = analyze(samples, using: analyzer)
            for value in output {
                XCTAssertTrue(value.isFinite)
                XCTAssertLessThanOrEqual(value, -150)
            }
        }
    }

    func testNarrowBandsInterpolateOnlyWhenTheyContainNoBinCenter() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let output = analyze(sine(bin: 3), using: analyzer)
        // Band 0 interpolates bins 2/3 in dB; band 1 includes bin 3 and takes its maximum.
        XCTAssertEqual(output[0], -1.40, accuracy: 0.05)
        XCTAssertEqual(output[1], 0, accuracy: 0.05)
        XCTAssertEqual(output[2], -1.224, accuracy: 0.05)
        XCTAssertEqual(output[3], -2.744, accuracy: 0.05)
    }

    func testDefaultInterpolationSetHasObservableBinCenteredAttenuation() {
        let layout = defaultLayout
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: layout)
        let binHz = sampleRate / Double(fftSize)
        var attenuatedBands: [Int] = []
        for band in 0..<layout.count {
            let probeBin = Int((layout.center[band] / binHz).rounded())
            let level = analyze(sine(bin: probeBin), using: analyzer)[band]
            // A band containing the probe bin peaks at 0 dBFS. Only interpolation
            // attenuates these full-scale probes; classification comes from PCM output.
            if level < -0.5 {
                attenuatedBands.append(band)
            } else {
                XCTAssertEqual(level, 0, accuracy: 0.05, "Band \(band), probe bin \(probeBin)")
            }
        }
        XCTAssertEqual(attenuatedBands, [0, 2, 3, 5, 7, 9])
    }

    func testShortInputMatchesExplicitLeftZeroPadding() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let short = sine(bin: 100, count: 1000)
        let padded = [Float](repeating: 0, count: fftSize - short.count) + short
        XCTAssertEqual(analyze(short, using: analyzer), analyze(padded, using: analyzer))
    }

    func testLongInputUsesOnlyTheNewestFFTWindow() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let tail = sine(bin: 100)
        let prefix = (0..<904).map { Float(($0 * 13) % 17) / 8 - 1 }
        XCTAssertEqual(analyze(prefix + tail, using: analyzer), analyze(tail, using: analyzer))
    }

    func testOutputLengthIsRespectedAndTrailingElementsStayUntouched() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let samples = sine(bin: 100)
        let full = analyze(samples, using: analyzer)
        XCTAssertEqual(analyze(samples, using: analyzer, count: 8), Array(full.prefix(8)))
        let oversized = analyze(samples, using: analyzer, count: 70)
        XCTAssertEqual(Array(oversized.prefix(64)), full)
        XCTAssertEqual(Array(oversized.suffix(6)), [Float](repeating: 123, count: 6))
        XCTAssertEqual(analyze(samples, using: analyzer, count: 0), [])
    }

    func testUpdateRebuildsSampleRateAndBandCountMapping() {
        let layout = BandLayout(count: 1, fMinHz: 1100, fMaxHz: 1200)
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: layout)
        let samples = sine(bin: 100)
        XCTAssertEqual(analyze(samples, using: analyzer, count: 1)[0], 0, accuracy: 0.5)
        analyzer.update(sampleRate: 96_000, layout: layout)
        XCTAssertLessThan(analyze(samples, using: analyzer, count: 1)[0], -100)

        let changedLayout = BandLayout(count: 2, fMinHz: 2200, fMaxHz: 4800)
        analyzer.update(sampleRate: 96_000, layout: changedLayout)
        let updated = analyze(samples, using: analyzer, count: 3)
        XCTAssertEqual(updated[0], 0, accuracy: 0.5)
        XCTAssertLessThan(updated[1], -100)
        XCTAssertEqual(updated[2], 123)
    }

    func testInvalidSampleRateOutputsSilenceAndCanRecover() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        let samples = sine(bin: 100)
        for invalidRate in [0, -48_000, Double.nan, Double.infinity] {
            analyzer.update(sampleRate: invalidRate, layout: defaultLayout)
            XCTAssertEqual(analyze(samples, using: analyzer), [Float](repeating: -160, count: 64))
        }
        analyzer.update(sampleRate: sampleRate, layout: defaultLayout)
        XCTAssertEqual(analyze(samples, using: analyzer)[37], 0, accuracy: 0.5)
    }

    func testNonfinitePCMProducesFiniteOutput() {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: defaultLayout)
        for value in [Float.nan, Float.infinity, -Float.infinity] {
            let samples = [Float](repeating: value, count: fftSize)
            XCTAssertEqual(analyze(samples, using: analyzer), [Float](repeating: -160, count: 64))
        }
    }

    func testEmptyLayoutLeavesOutputUntouched() {
        let analyzer = SpectrumAnalyzer(
            sampleRate: sampleRate, layout: BandLayout(count: 0, fMinHz: 30, fMaxHz: 16_000)
        )
        XCTAssertEqual(analyze(sine(bin: 100), using: analyzer, count: 3), [123, 123, 123])
    }

    func testBandsAboveNyquistClampWithoutInvalidIndices() {
        let layout = BandLayout(count: 4, fMinHz: 30_000, fMaxHz: 60_000)
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: layout)
        let output = analyze(sine(bin: 100), using: analyzer, count: 4)
        XCTAssertEqual(output.count, 4)
        for value in output {
            XCTAssertTrue(value.isFinite)
            XCTAssertLessThan(value, -100)
        }
        XCTAssertEqual(output, [Float](repeating: output[0], count: 4))
    }

    func testHighestBandClampsAtLastAvailableBinAt32kHz() {
        let analyzer = SpectrumAnalyzer(sampleRate: 32_000, layout: defaultLayout)
        let output = analyze(sine(bin: 2047), using: analyzer)
        // Blackman's reflected lobe near Nyquist gives 20 log10(0.38 / 0.42) dBFS.
        XCTAssertEqual(output[63], -0.87, accuracy: 0.05)
    }

    func testNyquistPackingDoesNotAppearAsDCEnergy() {
        let layout = BandLayout(count: 1, fMinHz: 0.1, fMaxHz: 0.2)
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, layout: layout)
        let nyquist = (0..<fftSize).map { $0.isMultiple(of: 2) ? Float(1) : Float(-1) }
        let output = analyze(nyquist, using: analyzer, count: 1)
        // The Nyquist value stored in imagp[0] must not contribute to DC magnitude.
        XCTAssertTrue(output[0].isFinite)
        XCTAssertLessThan(output[0], -100)
    }

    func testSupportedCustomFFTSizeRetainsAmplitudeCalibration() {
        let size = 1024
        let layout = BandLayout(count: 1, fMinHz: 4600, fMaxHz: 4700)
        let analyzer = SpectrumAnalyzer(fftSize: size, sampleRate: sampleRate, layout: layout)
        let samples = (0..<size).map { Float(sin(2 * Double.pi * 100 * Double($0) / Double(size))) }
        XCTAssertEqual(analyze(samples, using: analyzer, count: 1)[0], 0, accuracy: 0.5)
    }

    func testUnsupportedFFTSizeUsesDefaultWindowSize() {
        let analyzer = SpectrumAnalyzer(fftSize: 1000, sampleRate: sampleRate, layout: defaultLayout)
        XCTAssertEqual(analyze(sine(bin: 100), using: analyzer)[37], 0, accuracy: 0.5)
    }
}
