import AppKit
import PulseFloatCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var floatingPanelController: FloatingPanelController?
    private var frameClock: FrameClock?
    private var audioTap: SystemAudioTap?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let floatingPanel = FloatingPanelController()
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(config: floatingPanel.config, ring: ring)
        let tap = SystemAudioTap(ring: ring)
        tap.onFormatChange = { [weak source] sampleRate in source?.setSampleRate(sampleRate) }
        let statusItem = StatusItemController(panelController: floatingPanel) { [weak source, weak tap] in
            Self.audioStatusTitle(mode: source?.mode, tapState: tap?.state)
        }
        let clock = FrameClock(
            source: source,
            visualizerView: floatingPanel.visualizerView,
            statusItemController: statusItem
        )
        floatingPanelController = floatingPanel
        statusItemController = statusItem
        frameClock = clock
        audioTap = tap
        floatingPanel.show()
        clock.start()
        tap.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameClock?.stop()
        audioTap?.stop()
    }

    private static func audioStatusTitle(mode: LiveSpectrumSource.Mode?, tapState: SystemAudioTap.State?) -> String {
        if case .failed = tapState { return "音訊來源：模擬訊號（無法擷取系統音訊）" }
        switch mode {
        case .live: return "音訊來源：系統音訊"
        case .simulated, nil: return "音訊來源：模擬訊號（沒有聲音或尚未授權）"
        }
    }
}
