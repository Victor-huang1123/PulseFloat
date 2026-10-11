import CoreGraphics
import PulseFloatCore
import XCTest

final class WindowGeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)

    func testDefaultFrameIsCompactAndOnScreen() {
        let frame = WindowGeometry.defaultFrame(in: laptop)
        XCTAssertEqual(frame.width, 390, accuracy: 0.001)
        XCTAssertEqual(frame.width / frame.height, 2.6, accuracy: 0.001)
        XCTAssertTrue(laptop.contains(frame))
    }

    func testOversizedFrameIsShrunkToTheScreenLimitKeepingTopLeft() {
        let fitted = WindowGeometry.fit(CGRect(x: 100, y: 0, width: 3000, height: 1154), in: laptop)
        XCTAssertEqual(fitted.width, WindowGeometry.maxWidth(in: laptop), accuracy: 0.001)
        XCTAssertLessThanOrEqual(fitted.width, laptop.width * 0.6 + 0.001)
        XCTAssertEqual(fitted.width / fitted.height, 2.6, accuracy: 0.001)
        XCTAssertTrue(laptop.contains(fitted))
    }

    func testTinyAndWrongAspectFramesAreCorrected() {
        let fitted = WindowGeometry.fit(CGRect(x: 10, y: 10, width: 50, height: 400), in: laptop)
        XCTAssertEqual(fitted.width, 182, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 70, accuracy: 0.001)
    }

    func testOffscreenFrameIsMovedBackInside() {
        let fitted = WindowGeometry.fit(CGRect(x: 5000, y: -900, width: 390, height: 150), in: laptop)
        XCTAssertTrue(laptop.contains(fitted))
        XCTAssertEqual(fitted.width, 390, accuracy: 0.001)
    }

    func testNonFiniteFrameFallsBackToDefault() {
        let fitted = WindowGeometry.fit(CGRect(x: CGFloat.nan, y: 0, width: 390, height: 150), in: laptop)
        XCTAssertEqual(fitted, WindowGeometry.defaultFrame(in: laptop))
    }

    func testBestVisibleFramePicksLargestOverlapOrNil() {
        let onExternal = CGRect(x: 2000, y: 300, width: 390, height: 150)
        XCTAssertEqual(WindowGeometry.bestVisibleFrame(for: onExternal, among: [laptop, external]), external)
        XCTAssertNil(WindowGeometry.bestVisibleFrame(for: CGRect(x: -5000, y: 0, width: 10, height: 10), among: [laptop, external]))
    }
}
