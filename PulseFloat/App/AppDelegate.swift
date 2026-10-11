import AppKit
import PulseFloatCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var floatingPanelController: FloatingPanelController?
    private var frameClock: FrameClock?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let floatingPanel = FloatingPanelController()
        let statusItem = StatusItemController(panelController: floatingPanel)
        let source = PreviewSpectrumSource(bandCount: floatingPanel.config.bands.count)
        let clock = FrameClock(
            source: source,
            visualizerView: floatingPanel.visualizerView,
            statusItemController: statusItem
        )
        floatingPanelController = floatingPanel
        statusItemController = statusItem
        frameClock = clock
        floatingPanel.show()
        clock.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameClock?.stop()
    }
}
