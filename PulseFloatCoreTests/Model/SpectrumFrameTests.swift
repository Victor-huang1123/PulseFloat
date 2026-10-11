import PulseFloatCore
import XCTest

final class SpectrumFrameTests: XCTestCase {
    func testSilent64Bands() {
        let frame = SpectrumFrame.silent(bandCount: 64)
        XCTAssertEqual(frame.bandCount, 64)
        XCTAssertEqual(frame.values, [Float](repeating: 0, count: 64))
        XCTAssertEqual(frame.peaks, [Float](repeating: 0, count: 64))
        XCTAssertEqual(frame.bass, 0)
    }

    func testSilentZeroBands() {
        let frame = SpectrumFrame.silent(bandCount: 0)
        XCTAssertEqual(frame.bandCount, 0)
        XCTAssertEqual(frame.values, [])
        XCTAssertEqual(frame.peaks, [])
        XCTAssertEqual(frame.bass, 0)
    }

    func testSilentNegativeBandsReturnsEmptyFrame() {
        let frame = SpectrumFrame.silent(bandCount: -1)
        XCTAssertEqual(frame.bandCount, 0)
        XCTAssertEqual(frame.values, [])
        XCTAssertEqual(frame.peaks, [])
        XCTAssertEqual(frame.bass, 0)
    }

    func testInitializerPreservesMismatchedArrayLengths() {
        let frame = SpectrumFrame(values: [0.5, 0.5], peaks: [0.5], bass: 0)
        XCTAssertEqual(frame.values, [0.5, 0.5])
        XCTAssertEqual(frame.peaks, [0.5])
        XCTAssertEqual(frame.bass, 0)
        XCTAssertEqual(frame.bandCount, 2)
    }

    func testInitializerPreservesValuesAndValueSemantics() {
        let frame = SpectrumFrame(values: [0.1, 0.4], peaks: [0.7, 1], bass: 0.3)
        XCTAssertEqual(frame.values, [0.1, 0.4])
        XCTAssertEqual(frame.peaks, [0.7, 1])
        XCTAssertEqual(frame.bass, 0.3)
        XCTAssertEqual(frame.bandCount, 2)
        var copy = frame
        copy.values[0] = 0.9
        XCTAssertNotEqual(frame, copy)
        XCTAssertEqual(frame.values[0], 0.1)
    }
}
