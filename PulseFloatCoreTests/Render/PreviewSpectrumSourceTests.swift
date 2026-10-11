import PulseFloatCore
import XCTest

@MainActor
final class PreviewSpectrumSourceTests: XCTestCase {
    func testDeterministicSequenceAndFrameInvariants() async {
        let first = PreviewSpectrumSource()
        let second = PreviewSpectrumSource()
        let steps: [Double] = [0, 1.0 / 60, 1.0 / 120, 0.025, 0.05, 0.01]
        var minimumBass: Float = 1
        var maximumBass: Float = 0
        for index in 0..<600 {
            let frame = first.nextFrame(dt: steps[index % steps.count])
            XCTAssertEqual(frame, second.nextFrame(dt: steps[index % steps.count]))
            XCTAssertEqual(frame.bandCount, 64)
            XCTAssertEqual(frame.peaks.count, frame.values.count)
            XCTAssertTrue(frame.bass.isFinite && (0...1).contains(frame.bass))
            minimumBass = min(minimumBass, frame.bass)
            maximumBass = max(maximumBass, frame.bass)
            for band in 0..<frame.bandCount {
                XCTAssertTrue(frame.values[band].isFinite && (0...1).contains(frame.values[band]))
                XCTAssertTrue(frame.peaks[band].isFinite && (0...1).contains(frame.peaks[band]))
                XCTAssertGreaterThanOrEqual(frame.peaks[band] + 1e-6, frame.values[band])
            }
        }
        XCTAssertGreaterThan(maximumBass - minimumBass, 0.25)
    }

    func testZeroNegativeAndNonfiniteStepsPreserveState() async {
        let source = PreviewSpectrumSource()
        let frame = source.nextFrame(dt: 1.0 / 60)
        for step in [0.0, -0.1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(source.nextFrame(dt: step), frame)
        }
    }

    func testZeroNegativeAndSingleBandCounts() async {
        for count in [0, -10] {
            XCTAssertEqual(PreviewSpectrumSource(bandCount: count).nextFrame(dt: 0.05), .silent(bandCount: 0))
        }
        let frame = PreviewSpectrumSource(bandCount: 1).nextFrame(dt: 0.05)
        XCTAssertEqual(frame.bandCount, 1)
        XCTAssertGreaterThan(frame.values[0], 0)
        XCTAssertGreaterThanOrEqual(frame.peaks[0], frame.values[0])
    }

    func testLargeTimeStepMatchesClockMaximum() async {
        let source = PreviewSpectrumSource()
        let reference = PreviewSpectrumSource()
        for _ in 0..<20 {
            XCTAssertEqual(source.nextFrame(dt: 100), reference.nextFrame(dt: 0.05))
        }
    }

    func testBassPulseRunsAt128BPM() async {
        let source = PreviewSpectrumSource()
        let dt = 1.0 / 120
        var samples: [Float] = []
        for _ in 0..<600 { samples.append(source.nextFrame(dt: dt).bass) }
        var peakTimes: [Double] = []
        for index in 1..<(samples.count - 1) {
            if samples[index] > samples[index - 1], samples[index] >= samples[index + 1] {
                peakTimes.append(Double(index + 1) * dt)
            }
        }
        XCTAssertGreaterThanOrEqual(peakTimes.count, 8)
        guard peakTimes.count >= 2 else { return }
        var totalInterval = 0.0
        for index in 1..<peakTimes.count { totalInterval += peakTimes[index] - peakTimes[index - 1] }
        XCTAssertEqual(totalInterval / Double(peakTimes.count - 1), 60.0 / 128, accuracy: 0.01)
    }
}
