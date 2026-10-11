import PulseFloatCore
import XCTest

final class SimulatedSpectrumTests: XCTestCase {
    private let layout = BandLayout(count: 64, fMinHz: 30, fMaxHz: 16000)

    func testNoiseIsAnInjectedSevenDbMultiplier() {
        let clean = SimulatedSpectrum(layout: layout, noise: { 0 })
        let noisy = SimulatedSpectrum(layout: layout, noise: { 0.5 })
        var cleanDb = [Float](repeating: 0, count: layout.count)
        var noisyDb = cleanDb
        for time in [0.0, 0.5, 2.0, 4.0, 6.0, 8.0] {
            cleanDb.withUnsafeMutableBufferPointer { clean.fill($0, time: time) }
            noisyDb.withUnsafeMutableBufferPointer { noisy.fill($0, time: time) }
            for index in 0..<layout.count {
                XCTAssertTrue(cleanDb[index].isFinite)
                XCTAssertEqual(noisyDb[index] - cleanDb[index], 3.5, accuracy: 1e-5)
            }
        }
    }

    func testSameTimeAndZeroNoiseProduceIdenticalOutput() {
        let simulated = SimulatedSpectrum(layout: layout, noise: { 0 })
        var first = [Float](repeating: 0, count: layout.count)
        var second = first
        first.withUnsafeMutableBufferPointer { simulated.fill($0, time: 2.3) }
        second.withUnsafeMutableBufferPointer { simulated.fill($0, time: 2.3) }
        XCTAssertEqual(first, second)
        second.withUnsafeMutableBufferPointer { simulated.fill($0, time: 2.8) }
        XCTAssertNotEqual(first, second)
    }

    func testChordIndicesTwoAndThreeMatchAbsolutePrototypeLevels() {
        assertPrototypeLevels(time: 4, expected: [-24.0187, -24.3949, -27.3678, -30.5770])
        assertPrototypeLevels(time: 6, expected: [-24.3214, -27.4875, -29.9605, -31.5015])
    }

    func testNegativeTimeWrapsToChordIndexTwo() {
        // floor(-3 / (4 * 60 / 128)) == -2; positive modulo 4 selects chord 2 (261.6 Hz).
        assertPrototypeLevels(time: -3, expected: [-12.8188, -16.6299, -22.7451, -28.4784])
    }

    func testOutputLengthAndEmptyLayoutAreSafe() {
        let simulated = SimulatedSpectrum(layout: layout, noise: { 0 })
        var full = [Float](repeating: 123, count: layout.count + 2)
        var short = [Float](repeating: 123, count: 3)
        var empty: [Float] = []
        full.withUnsafeMutableBufferPointer { simulated.fill($0, time: 0.5) }
        short.withUnsafeMutableBufferPointer { simulated.fill($0, time: 0.5) }
        empty.withUnsafeMutableBufferPointer { simulated.fill($0, time: 0.5) }
        XCTAssertEqual(short, Array(full.prefix(3)))
        XCTAssertEqual(Array(full.suffix(2)), [123, 123])
        let emptySimulator = SimulatedSpectrum(layout: BandLayout(count: 0, fMinHz: 30, fMaxHz: 16000))
        let original = full
        full.withUnsafeMutableBufferPointer { emptySimulator.fill($0, time: 0.5) }
        XCTAssertEqual(full, original)
    }

    func testNonfiniteTimeAndNoiseProduceFiniteSilence() {
        var output = [Float](repeating: 0, count: layout.count)
        let simulated = SimulatedSpectrum(layout: layout, noise: { 0 })
        for time in [Double.nan, .infinity, -.infinity] {
            output.withUnsafeMutableBufferPointer { simulated.fill($0, time: time) }
            XCTAssertTrue(output.allSatisfy { $0 == -160 })
        }
        let invalidNoise = SimulatedSpectrum(layout: layout, noise: { .nan })
        output.withUnsafeMutableBufferPointer { invalidNoise.fill($0, time: 0.5) }
        XCTAssertTrue(output.allSatisfy { $0 == -160 })
    }

    private func assertPrototypeLevels(
        time: Double, expected: [Float], file: StaticString = #filePath, line: UInt = #line
    ) {
        let simulated = SimulatedSpectrum(layout: layout, noise: { 0 })
        var output = [Float](repeating: 0, count: layout.count)
        output.withUnsafeMutableBufferPointer { simulated.fill($0, time: time) }
        let bands = [20, 22, 24, 26]
        // Constants come from the unmodified prototype golden generator with noise = 0.
        // A 1e-3 dB tolerance covers the four-decimal reference rounding and Float storage.
        for index in bands.indices {
            XCTAssertEqual(output[bands[index]], expected[index], accuracy: 1e-3,
                           "time \(time), band \(bands[index])", file: file, line: line)
        }
    }
}
