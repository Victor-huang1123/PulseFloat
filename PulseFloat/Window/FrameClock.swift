import AppKit
import QuartzCore
import PulseFloatCore

/// App 唯一的畫面時鐘；在主執行緒產生一次頻譜，再分送同一幀給兩個呈現端。
@MainActor
final class FrameClock {
    private let source: any SpectrumSource
    private let visualizerView: VisualizerView
    private let statusItemController: StatusItemController
    private let target = FrameClockTarget()
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var displayID: CGDirectDisplayID?
    private var screenObserver: (any NSObjectProtocol)?

    init(
        source: any SpectrumSource,
        visualizerView: VisualizerView,
        statusItemController: StatusItemController
    ) {
        self.source = source
        self.visualizerView = visualizerView
        self.statusItemController = statusItemController
        target.clock = self
    }

    func start() {
        guard displayLink == nil else { return }
        // 即使暫時沒有螢幕也保留觀察者，之後接上螢幕即可恢復唯一的 tick 來源。
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // NotificationCenter 已明確指定 main queue，可同步進入 MainActor。
                MainActor.assumeIsolated {
                    self?.screenParametersDidChange()
                }
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        previousTimestamp = nil
        displayID = Self.displayID(for: screen)
        let link = screen.displayLink(target: target, selector: #selector(FrameClockTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// App 結束時由擁有者呼叫；隱藏浮動視窗不停止時鐘，選單列仍需更新。
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        displayID = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private func screenParametersDidChange() {
        let sourceDisplayExists = displayID.map { currentID in
            NSScreen.screens.contains { Self.displayID(for: $0) == currentID }
        } ?? false
        guard displayLink == nil || !sourceDisplayExists else { return }
        stop()
        start()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let timestamp = link.targetTimestamp
        let elapsed = previousTimestamp.map { timestamp - $0 } ?? 0
        previousTimestamp = timestamp
        let dt = elapsed.isFinite ? min(0.05, max(0, elapsed)) : 0
        let frame = source.nextFrame(dt: dt)
        visualizerView.show(frame: frame, dt: dt)
        statusItemController.show(frame: frame, dt: dt)
    }
}

/// CADisplayLink 會保留 target；以弱參照轉送，避免 link 與時鐘形成 retain cycle。
@MainActor
private final class FrameClockTarget: NSObject {
    weak var clock: FrameClock?

    @objc func tick(_ link: CADisplayLink) {
        clock?.tick(link)
    }
}
