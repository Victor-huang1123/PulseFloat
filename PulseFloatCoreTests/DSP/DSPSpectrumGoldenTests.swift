import Foundation
import PulseFloatCore
import XCTest

final class DSPSpectrumGoldenTests: XCTestCase {
    func testAllFourScenariosMatchEveryRecordedSnapshot() throws {
        let fixture = try DSPTestSupport.goldenFixture(testClass: Self.self)
        let expectedNames: Set<String> = [
            "simulated_defaults", "step_gate_release", "fixed_ceiling_no_smoothing", "zero_dt_frames"
        ]
        XCTAssertEqual(fixture.scenarios.count, expectedNames.count)
        XCTAssertEqual(Set(fixture.scenarios.map(\.name)), expectedNames)
        for scenario in fixture.scenarios {
            // Decode config as VisualizerConfig directly from the fixture; do not recreate overrides.
            let pipeline = SpectrumPipeline(config: scenario.config)
            let simulated = SimulatedSpectrum(layout: pipeline.bandLayout, noise: { 0 })
            var snapshotIndex = 0
            var previousFrame: SpectrumFrame?
            var previousCeiling = pipeline.ceilingDb
            for frameIndex in 0..<scenario.frames {
                var dt = 1.0 / 60
                switch scenario.name {
                case "simulated_defaults":
                    pipeline.withRawDb { simulated.fill($0, time: Double(frameIndex + 1) * dt) }
                case "step_gate_release":
                    pipeline.withRawDb { raw in
                        for index in raw.indices { raw[index] = frameIndex >= 10 && frameIndex < 70 ? -20 : -160 }
                    }
                case "fixed_ceiling_no_smoothing":
                    pipeline.withRawDb { raw in
                        for index in raw.indices {
                            raw[index] = Float(-30 + 20 * sin(0.37 * Double(index) + 0.21 * Double(frameIndex)))
                        }
                    }
                    if frameIndex % 2 == 1 { dt /= 2 }
                case "zero_dt_frames":
                    pipeline.withRawDb { simulated.fill($0, time: 0.5) }
                    if frameIndex % 4 == 3 { dt = 0 }
                default:
                    XCTFail("Unimplemented golden scenario: \(scenario.name)")
                    return
                }
                let frame = pipeline.process(dt: dt)
                if dt == 0 {
                    XCTAssertEqual(frame, previousFrame)
                    XCTAssertEqual(pipeline.ceilingDb, previousCeiling)
                }
                previousFrame = frame
                previousCeiling = pipeline.ceilingDb
                guard (frameIndex + 1) % scenario.recordEvery == 0 || frameIndex == scenario.frames - 1 else {
                    continue
                }
                XCTAssertLessThan(snapshotIndex, scenario.snapshots.count)
                guard snapshotIndex < scenario.snapshots.count else { return }
                let snapshot = scenario.snapshots[snapshotIndex]
                XCTAssertEqual(snapshot.frame, frameIndex)
                assertSnapshot(frame, ceilingDb: pipeline.ceilingDb, equals: snapshot, scenario: scenario.name)
                snapshotIndex += 1
            }
            XCTAssertEqual(snapshotIndex, scenario.snapshots.count, "Must check every \(scenario.name) snapshot")
        }
    }

    private func assertSnapshot(
        _ frame: SpectrumFrame,
        ceilingDb: Double,
        equals snapshot: DSPTestSupport.Snapshot,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = "\(scenario) frame \(snapshot.frame)"
        // All four outputs use the fixture's required absolute tolerance of 1e-4.
        XCTAssertEqual(ceilingDb, snapshot.ceilDb, accuracy: 1e-4, context, file: file, line: line)
        XCTAssertEqual(Double(frame.bass), snapshot.bass, accuracy: 1e-4, context, file: file, line: line)
        XCTAssertEqual(frame.values.count, snapshot.values.count, context, file: file, line: line)
        XCTAssertEqual(frame.peaks.count, snapshot.peaks.count, context, file: file, line: line)
        for index in 0..<min(frame.values.count, snapshot.values.count) {
            XCTAssertEqual(Double(frame.values[index]), snapshot.values[index], accuracy: 1e-4,
                           "\(context), value \(index)", file: file, line: line)
        }
        for index in 0..<min(frame.peaks.count, snapshot.peaks.count) {
            XCTAssertEqual(Double(frame.peaks[index]), snapshot.peaks[index], accuracy: 1e-4,
                           "\(context), peak \(index)", file: file, line: line)
        }
    }
}
