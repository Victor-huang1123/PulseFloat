import Foundation
import PulseFloatCore
import XCTest

final class BandLayoutTests: XCTestCase {
    func testLogarithmicEdgesAndGeometricCentersUseDoublePrecision() {
        for (count, low, high) in [(64, 30.0, 16000.0), (32, 40.0, 12000.0), (1, 20.0, 20000.0)] {
            let layout = BandLayout(count: count, fMinHz: low, fMaxHz: high)
            XCTAssertEqual(layout.count, count)
            XCTAssertEqual(layout.lo.count, count)
            XCTAssertEqual(layout.hi.count, count)
            // The endpoints must be accurate to a relative 1e-9, without Float rounding.
            XCTAssertEqual(layout.lo[0], low, accuracy: low * 1e-9)
            XCTAssertEqual(layout.hi[count - 1], high, accuracy: high * 1e-9)
            for index in 0..<count {
                XCTAssertEqual(layout.center[index], sqrt(layout.lo[index] * layout.hi[index]), accuracy: 1e-12)
                XCTAssertEqual(layout.hi[index] / layout.lo[index], pow(high / low, 1 / Double(count)), accuracy: 1e-12)
                if index + 1 < count {
                    XCTAssertEqual(layout.hi[index], layout.lo[index + 1])
                }
            }
        }
    }

    func testEveryGoldenScenarioBandLayoutMatches() throws {
        let fixture = try DSPTestSupport.goldenFixture(testClass: Self.self)
        for scenario in fixture.scenarios {
            let bands = scenario.config.bands
            let layout = BandLayout(count: bands.count, fMinHz: bands.fMinHz, fMaxHz: bands.fMaxHz)
            for (actual, expected) in [
                (layout.lo, scenario.bandLowHz), (layout.hi, scenario.bandHighHz),
                (layout.center, scenario.bandCenterHz)
            ] {
                XCTAssertEqual(actual.count, expected.count)
                for index in 0..<min(actual.count, expected.count) {
                    // The prototype fixture stores Float32 edges, then rounds to six decimals.
                    XCTAssertEqual(actual[index], expected[index], accuracy: abs(expected[index]) * 1e-5,
                                   "\(scenario.name), band \(index)")
                }
            }
        }
    }

    func testInvalidInputsProduceAnEmptyLayout() {
        for (count, low, high) in [
            (0, 30.0, 16000.0), (-1, 30.0, 16000.0), (64, 0.0, 16000.0),
            (64, 100.0, 30.0), (64, Double.nan, 16000.0), (64, 30.0, Double.infinity)
        ] {
            let layout = BandLayout(count: count, fMinHz: low, fMaxHz: high)
            XCTAssertEqual(layout.count, 0)
            XCTAssertTrue(layout.lo.isEmpty)
            XCTAssertTrue(layout.hi.isEmpty)
        }
    }

    func testBandLayoutIsSendable() {
        requireSendable(BandLayout.self)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}
}
