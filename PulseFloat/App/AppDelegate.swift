import AppKit
import PulseFloatCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var floatingPanelController: FloatingPanelController?
    private var frameClock: FrameClock?
    private var audioTap: SystemAudioTap?

    /// UserDefaults key：是否在 Dock 顯示圖示（預設顯示；可從選單列關閉，變成純選單列 App）。
    private static let dockIconKey = "showDockIcon"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.dockIconKey: true])
        NSApp.mainMenu = makeMainMenu()
        applyDockIconPreference()
        // 先讀使用者上次的設定；沒有的話用 App 預設（透明視窗）。VisualizerConfig.default 維持原型參數。
        var appDefault = VisualizerConfig.default
        appDefault.look.windowMode = .bare
        let floatingPanel = FloatingPanelController(config: ConfigStore.load() ?? appDefault)
        floatingPanel.onConfigChange = { ConfigStore.save($0) }
        let ring = SampleRingBuffer()
        let source = LiveSpectrumSource(config: floatingPanel.config, ring: ring)
        let tap = SystemAudioTap(ring: ring)
        tap.onFormatChange = { [weak source] sampleRate in source?.setSampleRate(sampleRate) }
        let statusItem = StatusItemController(
            panelController: floatingPanel,
            audioStatus: { [weak source, weak tap] in
                Self.audioStatusTitle(mode: source?.mode, tapState: tap?.state)
            },
            isDockIconVisible: { UserDefaults.standard.bool(forKey: Self.dockIconKey) },
            setDockIconVisible: { [weak self] visible in self?.setDockIconVisible(visible) }
        )
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

    /// 點 Dock 圖示、或在 Finder／Launchpad 再次打開時，把浮動視窗叫回來。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingPanelController?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameClock?.stop()
        audioTap?.stop()
    }

    private func setDockIconVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.dockIconKey)
        applyDockIconPreference()
    }

    /// Info.plist 仍是 LSUIElement（啟動時不會先閃出 Dock 圖示），執行時再依偏好切換。
    private func applyDockIconPreference() {
        let visible = UserDefaults.standard.bool(forKey: Self.dockIconKey)
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    @objc private func showFloatingPanel() {
        floatingPanelController?.show()
    }

    /// 顯示 Dock 圖示時，App 變成前景 App 會有自己的選單列；提供最小的標準選單。
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "PulseFloat")
        appMenu.addItem(withTitle: "關於 PulseFloat", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隱藏 PulseFloat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 PulseFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowMenu = NSMenu(title: "視窗")
        let showItem = windowMenu.addItem(withTitle: "顯示浮動視窗", action: #selector(showFloatingPanel), keyEquivalent: "1")
        showItem.target = self
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        return mainMenu
    }

    private static func audioStatusTitle(mode: LiveSpectrumSource.Mode?, tapState: SystemAudioTap.State?) -> String {
        if case .failed = tapState { return "音訊來源：無法擷取系統音訊" }
        switch mode {
        case .live: return "音訊來源：系統音訊（播放中）"
        case .silent, nil: return "音訊來源：目前沒有聲音（若播放中仍沒反應，請檢查錄音權限）"
        }
    }
}
