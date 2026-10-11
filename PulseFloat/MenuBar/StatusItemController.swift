import AppKit
import PulseFloatCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let panelController: FloatingPanelController
    private let renderer = MenuBarRenderer()
    private var accumulatedTime: TimeInterval = 0
    private var visibilityItem: NSMenuItem?
    private var lockItem: NSMenuItem?
    private var themeItems: [NSMenuItem] = []
    private var windowModeItems: [NSMenuItem] = []

    init(panelController: FloatingPanelController) {
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        super.init()

        statusItem.button?.setAccessibilityLabel("PulseFloat")
        updateImage(frame: .silent(bandCount: panelController.config.bands.count))

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let visibility = makeItem(title: "顯示浮動視窗", action: #selector(toggleVisibility))
        visibilityItem = visibility
        menu.addItem(visibility)

        let themes = NSMenu()
        themes.autoenablesItems = false
        for theme in ThemeID.allCases {
            let item = makeItem(title: Self.title(for: theme), action: #selector(selectTheme(_:)))
            item.representedObject = theme.rawValue
            themes.addItem(item)
            themeItems.append(item)
        }
        let themeItem = NSMenuItem(title: "主題", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)

        let modes = NSMenu()
        modes.autoenablesItems = false
        for mode in WindowMode.allCases {
            let item = makeItem(
                title: mode == .card ? "毛玻璃卡片" : "透明",
                action: #selector(selectWindowMode(_:))
            )
            item.representedObject = mode.rawValue
            modes.addItem(item)
            windowModeItems.append(item)
        }
        let modeItem = NSMenuItem(title: "視窗樣式", action: nil, keyEquivalent: "")
        modeItem.submenu = modes
        menu.addItem(modeItem)

        let lock = makeItem(title: "鎖定並點擊穿透", action: #selector(toggleLock))
        lockItem = lock
        menu.addItem(lock)
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "關於 PulseFloat", action: #selector(showAbout)))
        let quitItem = NSMenuItem(title: "結束 PulseFloat", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    /// 只接收 FrameClock 的幀；以約 30 fps 更新，容許 timestamp 的 2 ms 抖動。
    func show(frame: SpectrumFrame, dt: TimeInterval) {
        accumulatedTime += dt.isFinite ? max(0, dt) : 0
        guard accumulatedTime >= 1.0 / 30 - 0.002 else { return }
        // 不補畫漏掉的幀；60 Hz 下每兩次 callback 更新一次。
        accumulatedTime = 0
        updateImage(frame: frame)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        visibilityItem?.state = panelController.isVisible ? .on : .off
        lockItem?.state = panelController.isLocked ? .on : .off
        for item in themeItems {
            item.state = (item.representedObject as? String) == panelController.config.look.theme.rawValue ? .on : .off
        }
        for item in windowModeItems {
            item.state = (item.representedObject as? String) == panelController.config.look.windowMode.rawValue ? .on : .off
        }
    }

    private func updateImage(frame: SpectrumFrame) {
        guard let button = statusItem.button else { return }
        let size = CGSize(width: 26, height: 16)
        let scale = button.window?.backingScaleFactor ?? 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(ceil(size.width * scale)),
                height: Int(ceil(size.height * scale)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        let config = panelController.config
        renderer.draw(in: context, size: size, frame: frame, config: config.menubar, palette: config.look.palette)
        guard let bitmap = context.makeImage() else { return }
        let image = NSImage(cgImage: bitmap, size: size)
        image.isTemplate = !config.menubar.colored
        button.image = image
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func title(for theme: ThemeID) -> String {
        switch theme {
        case .bars: "經典直條"
        case .radial: "圓環放射"
        case .neon: "霓虹光暈"
        case .led: "極簡點陣"
        }
    }

    @objc private func toggleVisibility() {
        panelController.toggleVisibility()
    }

    @objc private func toggleLock() {
        panelController.toggleLock()
    }

    @objc private func selectTheme(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let theme = ThemeID(rawValue: rawValue) else { return }
        panelController.setTheme(theme)
    }

    @objc private func selectWindowMode(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let mode = WindowMode(rawValue: rawValue) else { return }
        panelController.setWindowMode(mode)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
