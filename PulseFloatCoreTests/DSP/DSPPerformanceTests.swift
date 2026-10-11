import Foundation
import PulseFloatCore
import XCTest

final class DSPPerformanceTests: XCTestCase {
    func testAnalyzerAndPipelineAverageUnderOneMillisecondForOneThousandFrames() {
        let pipeline = SpectrumPipeline(config: .default)
        let analyzer = SpectrumAnalyzer(sampleRate: 48000, layout: pipeline.bandLayout)
        var samples = [Float](repeating: 0, count: 4096)
        for index in samples.indices {
            samples[index] = Float(sin(2 * Double.pi * 100 * Double(index) / 4096))
        }
        var checksum: Float = 0
        let iterations = 1000
        samples.withUnsafeBufferPointer { input in
            var iteration = 0
            while iteration < 10 {
                pipeline.withRawDb { analyzer.analyze(samples: input, into: $0) }
                checksum += pipeline.process(dt: 1.0 / 60).bass
                iteration += 1
            }
            let start = ProcessInfo.processInfo.systemUptime
            iteration = 0
            while iteration < iterations {
                pipeline.withRawDb { analyzer.analyze(samples: input, into: $0) }
                let frame = pipeline.process(dt: 1.0 / 60)
                checksum += frame.values[37]
                iteration += 1
            }
            let average = (ProcessInfo.processInfo.systemUptime - start) / Double(iterations)
            XCTAssertLessThan(average, 0.001, "Debug analyze + process averaged \(average * 1000) ms/frame")
        }
        XCTAssertTrue(checksum.isFinite)
        XCTAssertGreaterThan(checksum, 0)
    }
}
