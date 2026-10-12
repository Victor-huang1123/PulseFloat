import PulseFloatCore
import XCTest

/// 沒有聲音時要放開輸出裝置（AirPods 自動切換才不會被卡住），有聲音時立刻接上。
final class CaptureGateTests: XCTestCase {
    func testStartsAsSoonAsSomethingPlays() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: false, now: 0, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: true, isCapturing: false, now: 0.5, lastFailure: nil), .start)
        XCTAssertEqual(gate.evaluate(othersOutputting: true, isCapturing: true, now: 1, lastFailure: nil), .none)
    }

    func testReleasesOnlyAfterContinuousSilence() {
        var gate = CaptureGate(releaseDelay: 3)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 10, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 12, lastFailure: nil), .none)
        // 中間又有聲音：重新計時
        XCTAssertEqual(gate.evaluate(othersOutputting: true, isCapturing: true, now: 12.5, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 13, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 15.9, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 16, lastFailure: nil), .release)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: false, now: 17, lastFailure: nil), .none)
    }

    func testDoesNotRetryTooSoonAfterAFailure() {
        var gate = CaptureGate(retryDelay: 5)
        XCTAssertEqual(gate.evaluate(othersOutputting: true, isCapturing: false, now: 2, lastFailure: 0), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: true, isCapturing: false, now: 5.1, lastFailure: 0), .start)
    }

    func testResetForgetsTheIdleTimer() {
        var gate = CaptureGate(releaseDelay: 3)
        _ = gate.evaluate(othersOutputting: false, isCapturing: true, now: 0, lastFailure: nil)
        gate.reset()
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 3.5, lastFailure: nil), .none)
        XCTAssertEqual(gate.evaluate(othersOutputting: false, isCapturing: true, now: 6.5, lastFailure: nil), .release)
    }
}
