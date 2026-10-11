import Foundation
import PulseFloatCore
import XCTest

enum DSPTestSupport {
    struct GoldenFixture: Decodable {
        let scenarios: [Scenario]
    }

    struct Scenario: Decodable {
        let name: String
        let config: VisualizerConfig
        let frames: Int
        let recordEvery: Int
        let bandCenterHz: [Double]
        let bandLowHz: [Double]
        let bandHighHz: [Double]
        let snapshots: [Snapshot]
    }

    struct Snapshot: Decodable {
        let frame: Int
        let ceilDb: Double
        let bass: Double
        let values: [Double]
        let peaks: [Double]
    }

    static func goldenFixture(testClass: AnyClass) throws -> GoldenFixture {
        let url = try XCTUnwrap(Bundle(for: testClass).url(forResource: "pipeline_golden", withExtension: "json"))
        return try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
    }
}
