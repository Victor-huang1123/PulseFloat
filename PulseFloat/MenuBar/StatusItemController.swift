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
    private var paletteItems: [NSMenuItem] = []
    private var coloredIconItem: NSMenuItem?
    private let audioStatus: () -> String
    private let audioStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let isDockIconVisible: () -> Bool
    private let setDockIconVisible: (Bool) -> Void
    private var dockIconItem: NSMenuItem?

    /// audioStatus 在每次打開選單時呼叫，回傳目前音訊來源的說明文字；Dock 圖示的顯示狀態由 App 層保存。
    init(
        panelController: FloatingPanelController,
        audioStatus: @escaping () -> String,
        isDockIconVisible: @escaping () -> Bool,
        setDockIconVisible: @escaping (Bool) -> Void
    ) {
        self.panelController = panelController
        self.audioStatus = audioStatus
        self.isDockIconVisible = isDockIconVisible
        self.setDockIconVisible = setDockIconVisible
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

        let palettes = NSMenu()
        palettes.autoenablesItems = false
        for palette in PaletteID.allCases {
            let item = makeItem(title: Self.title(for: palette), action: #selector(selectPalette(_:)))
            item.representedObject = palette.rawValue
            item.image = Self.swatch(for: palette)
            palettes.addItem(item)
            paletteItems.append(item)
        }
        palettes.addItem(.separator())
        let colored = makeItem(title: "選單列圖示也用配色", action: #selector(toggleColoredIcon))
        coloredIconItem = colored
        palettes.addItem(colored)
        let paletteItem = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        paletteItem.submenu = palettes
        menu.addItem(paletteItem)

        let lock = makeItem(title: "鎖定並點擊穿透", action: #selector(toggleLock))
        lockItem = lock
        menu.addItem(lock)
        let dockIcon = makeItem(title: "在 Dock 顯示圖示", action: #selector(toggleDockIcon))
        dockIconItem = dockIcon
        menu.addItem(dockIcon)
        menu.addItem(.separator())
        audioStatusItem.isEnabled = false
        menu.addItem(audioStatusItem)
        menu.addItem(makeItem(title: "開啟「螢幕與系統錄音」設定…", action: #selector(openAudioCaptureSettings)))
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
        audioStatusItem.title = audioStatus()
        dockIconItem?.state = isDockIconVisible() ? .on : .off
        visibilityItem?.state = panelController.isVisible ? .on : .off
        lockItem?.state = panelController.isLocked ? .on : .off
        for item in themeItems {
            item.state = (item.representedObject as? String) == panelController.config.look.theme.rawValue ? .on : .off
        }
        for item in paletteItems {
            item.state = (item.representedObject as? String) == panelController.config.look.palette.rawValue ? .on : .off
        }
        coloredIconItem?.state = panelController.config.menubar.colored ? .on : .off
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

    private static func title(for palette: PaletteID) -> String {
        switch palette {
        case .aurora: "極光 Aurora"
        case .ember: "餘燼 Ember"
        case .glacier: "冰川 Glacier"
        case .mono: "單色 Mono"
        case .lab: "實驗室 Lab"
        case .sakura: "櫻花 Sakura"
        case .sunset: "夕陽 Sunset"
        case .matcha: "抹茶 Matcha"
        case .neotokyo: "新東京 Neo Tokyo"
        case .graphite: "石墨 Graphite"
        }
    }

    /// 選單裡的三色漸層色票（28×12 pt 圓角矩形）。
    private static func swatch(for palette: PaletteID) -> NSImage {
        let colors = Palette(palette)
        let image = NSImage(size: NSSize(width: 28, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            let stops = [0.0, 0.5, 1.0].map { colors.color(at: $0) }
            let gradient = NSGradient(colors: stops.map {
                NSColor(srgbRed: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1)
            })
            gradient?.draw(in: path, angle: 0)
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        return image
    }

    private static func title(for theme: ThemeID) -> String {
        switch theme {
        case .bars: "經典直條"
        case .radial: "圓環放射"
        case .neon: "霓虹光暈"
        case .led: "極簡點陣"
        case .orbit: "軌道 Orbit"
        case .hud: "儀表 HUD"
        case .constellation: "星圖 Constellation"
        case .mobius: "無限 Möbius（3D）"
        case .analysis: "解析 Analysis OS（3D）"
        }
    }

    @objc private func toggleVisibility() {
        panelController.toggleVisibility()
    }

    @objc private func toggleDockIcon() {
        setDockIconVisible(!isDockIconVisible())
    }

    @objc private func toggleLock() {
        panelController.toggleLock()
    }

    @objc private func selectTheme(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let theme = ThemeID(rawValue: rawValue) else { return }
        panelController.setTheme(theme)
    }

    @objc private func selectPalette(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let palette = PaletteID(rawValue: rawValue) else { return }
        panelController.setPalette(palette)
    }

    @objc private func toggleColoredIcon() {
        panelController.setMenuBarColored(!panelController.config.menubar.colored)
    }

    @objc private func selectWindowMode(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let mode = WindowMode(rawValue: rawValue) else { return }
        panelController.setWindowMode(mode)
    }

    /// 系統錄音權限沒有公開 API 可查詢或請求，只能帶使用者到系統設定（授權後可能需要重新啟動 App）。
    @objc private func openAudioCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
