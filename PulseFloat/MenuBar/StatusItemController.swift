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
    private var styleItems: [NSMenuItem] = []
    private var presentationItems: [NSMenuItem] = []
    private var qualityItems: [NSMenuItem] = []
    private var surfaceItems: [NSMenuItem] = []
    // 只和部分主題有關的項目：打開選單時依目前主題顯示或隱藏，避免誤導。
    private var paletteMenuItem: NSMenuItem?
    private var styleMenuItem: NSMenuItem?
    private var cameraMenuItem: NSMenuItem?
    private var qualityMenuItem: NSMenuItem?
    private var surfaceMenuItem: NSMenuItem?
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let sceneTimingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var thumbnailLook: VisualizerConfig.Look?
    private let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "透明度")
    private let audioStatus: () -> String
    private let audioStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let isDockIconVisible: () -> Bool
    private let setDockIconVisible: (Bool) -> Void
    private var dockIconItem: NSMenuItem?
    private let isNowPlayingArtworkEnabled: () -> Bool
    private let setNowPlayingArtworkEnabled: (Bool) -> Void
    private let nowPlayingSummary: () -> String?
    private var nowPlayingArtworkItem: NSMenuItem?
    private let nowPlayingInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// audioStatus 在每次打開選單時呼叫，回傳目前音訊來源的說明文字；Dock 圖示的顯示狀態由 App 層保存。
    /// 「圓環中央顯示封面」的開關同樣由 App 層保存；nowPlayingSummary 回傳「App — 歌名 · 歌手」，不知道時回傳 nil。
    init(
        panelController: FloatingPanelController,
        audioStatus: @escaping () -> String,
        isDockIconVisible: @escaping () -> Bool,
        setDockIconVisible: @escaping (Bool) -> Void,
        isNowPlayingArtworkEnabled: @escaping () -> Bool,
        setNowPlayingArtworkEnabled: @escaping (Bool) -> Void,
        nowPlayingSummary: @escaping () -> String?
    ) {
        self.panelController = panelController
        self.audioStatus = audioStatus
        self.isDockIconVisible = isDockIconVisible
        self.setDockIconVisible = setDockIconVisible
        self.isNowPlayingArtworkEnabled = isNowPlayingArtworkEnabled
        self.setNowPlayingArtworkEnabled = setNowPlayingArtworkEnabled
        self.nowPlayingSummary = nowPlayingSummary
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        super.init()

        statusItem.button?.setAccessibilityLabel("PulseFloat")
        updateImage(frame: .silent(bandCount: panelController.config.bands.count))
        // 主題縮圖要跑一小段示範音樂與幾個 renderer，啟動後稍等再產生，避免拖慢啟動或第一次打開選單。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshThumbnails() }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let visibility = makeItem(title: "隱藏浮動視窗", action: #selector(toggleVisibility))
        visibilityItem = visibility
        menu.addItem(visibility)

        let themes = NSMenu()
        themes.autoenablesItems = false
        for theme in ThemeID.selectable {
            let item = makeItem(title: Self.title(for: theme), action: #selector(selectTheme(_:)))
            item.representedObject = theme.rawValue
            themes.addItem(item)
            themeItems.append(item)
        }
        let themeItem = NSMenuItem(title: "主題", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)

        // 目前主題才用得到的設定（menuNeedsUpdate 依主題顯示／隱藏）。
        let artwork = makeItem(title: "中央顯示封面", action: #selector(toggleNowPlayingArtwork))
        artwork.toolTip = "圓環放射與黑洞：在中央顯示正在播放的歌曲封面。"
        nowPlayingArtworkItem = artwork
        menu.addItem(artwork)

        let palettes = NSMenu()
        palettes.autoenablesItems = false
        for palette in PaletteID.allCases {
            let item = makeItem(title: Self.title(for: palette), action: #selector(selectPalette(_:)))
            item.representedObject = palette.rawValue
            item.image = Self.swatch(for: palette)
            palettes.addItem(item)
            paletteItems.append(item)
        }
        let paletteItem = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        paletteItem.submenu = palettes
        paletteMenuItem = paletteItem
        menu.addItem(paletteItem)

        let styles = NSMenu()
        styles.autoenablesItems = false
        for style in SculptureStyle.allCases {
            let item = makeItem(title: Self.title(for: style), action: #selector(selectSculptureStyle(_:)))
            item.representedObject = style.rawValue
            item.image = Self.swatch(for: style)
            styles.addItem(item)
            styleItems.append(item)
        }
        let styleItem = NSMenuItem(title: "材質色彩", action: nil, keyEquivalent: "")
        styleItem.submenu = styles
        styleMenuItem = styleItem
        menu.addItem(styleItem)

        cameraMenuItem = makeChoiceMenu(title: "鏡頭", choices: [
            (ScenePresentation.compact.rawValue, "填滿視窗"),
            (ScenePresentation.sculpture.rawValue, "立體展示（⌥ 拖曳旋轉）"),
        ], action: #selector(selectPresentation(_:)), into: &presentationItems, in: menu)
        qualityMenuItem = makeChoiceMenu(title: "畫質", choices: [
            (RenderQuality.low.rawValue, "低"), (RenderQuality.medium.rawValue, "中"), (RenderQuality.high.rawValue, "高"),
        ], action: #selector(selectQuality(_:)), into: &qualityItems, in: menu)
        if let qualityMenu = qualityMenuItem?.submenu {
            qualityMenu.addItem(.separator())
            sceneTimingItem.isEnabled = false
            qualityMenu.addItem(sceneTimingItem)
        }
        surfaceMenuItem = makeChoiceMenu(title: "地形外觀", choices: [
            (TerrainSurface.wireframe.rawValue, "線框"), (TerrainSurface.surface.rawValue, "半透明曲面"),
        ], action: #selector(selectTerrainSurface(_:)), into: &surfaceItems, in: menu)

        menu.addItem(.separator())
        menu.addItem(makeOpacityItem())
        let modes = NSMenu()
        modes.autoenablesItems = false
        for mode in WindowMode.allCases {
            let item = makeItem(title: mode == .card ? "毛玻璃卡片" : "透明", action: #selector(selectWindowMode(_:)))
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
        audioStatusItem.isEnabled = false
        audioStatusItem.toolTip = "若播放中仍沒反應，請在「更多」打開「螢幕與系統錄音」設定檢查權限。"
        menu.addItem(audioStatusItem)
        nowPlayingInfoItem.isEnabled = false
        nowPlayingInfoItem.isHidden = true
        menu.addItem(nowPlayingInfoItem)
        menu.addItem(.separator())

        let more = NSMenu()
        more.autoenablesItems = false
        let dockIcon = makeItem(title: "在 Dock 顯示圖示", action: #selector(toggleDockIcon))
        dockIconItem = dockIcon
        more.addItem(dockIcon)
        let colored = makeItem(title: "選單列圖示也用配色", action: #selector(toggleColoredIcon))
        coloredIconItem = colored
        more.addItem(colored)
        more.addItem(makeItem(title: "螢幕與系統錄音設定…", action: #selector(openAudioCaptureSettings)))
        more.addItem(.separator())
        more.addItem(makeItem(title: "關於 PulseFloat", action: #selector(showAbout)))
        let moreItem = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)
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
        let artworkEnabled = isNowPlayingArtworkEnabled()
        nowPlayingArtworkItem?.state = artworkEnabled ? .on : .off
        let summary = artworkEnabled ? nowPlayingSummary() : nil
        nowPlayingInfoItem.title = summary.map { "♪ " + Self.truncated($0, to: 22) } ?? ""
        nowPlayingInfoItem.toolTip = summary
        nowPlayingInfoItem.isHidden = summary == nil
        visibilityItem?.title = panelController.isVisible ? "隱藏浮動視窗" : "顯示浮動視窗"
        let current = panelController.config.look
        nowPlayingArtworkItem?.isHidden = !current.theme.showsCenterArtwork
        styleMenuItem?.isHidden = !current.theme.usesSculptureStyle
        paletteMenuItem?.isHidden = current.theme.usesSculptureStyle && current.sculptureStyle != .palette
        cameraMenuItem?.isHidden = !current.theme.isScene
        qualityMenuItem?.isHidden = !current.theme.isScene
        surfaceMenuItem?.isHidden = current.theme != .terrain
        lockItem?.state = panelController.isLocked ? .on : .off
        for item in themeItems {
            item.state = (item.representedObject as? String) == panelController.config.look.theme.rawValue ? .on : .off
        }
        for item in paletteItems {
            item.state = (item.representedObject as? String) == panelController.config.look.palette.rawValue ? .on : .off
        }
        for item in styleItems {
            item.state = (item.representedObject as? String) == panelController.config.look.sculptureStyle.rawValue ? .on : .off
        }
        let look = panelController.config.look
        for item in presentationItems { item.state = (item.representedObject as? String) == look.presentation.rawValue ? .on : .off }
        for item in qualityItems { item.state = (item.representedObject as? String) == look.quality.rawValue ? .on : .off }
        for item in surfaceItems { item.state = (item.representedObject as? String) == look.terrainSurface.rawValue ? .on : .off }
        if let timing = panelController.visualizerView.sceneTiming {
            sceneTimingItem.title = String(format: "CPU %.2f ms・GPU %.2f ms", timing.cpuMs, timing.gpuMs)
            sceneTimingItem.toolTip = String(format: "每幀 CPU：更新 %.2f ms＋繪製指令 %.2f ms；GPU 另外量。", timing.cpuUpdateMs, timing.cpuEncodeMs)
            sceneTimingItem.isHidden = false
        } else {
            sceneTimingItem.isHidden = true
        }
        refreshThumbnails()
        coloredIconItem?.state = panelController.config.menubar.colored ? .on : .off
        opacitySlider.doubleValue = panelController.config.look.opacity
        updateOpacityLabel()
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

    /// 一個單選子選單（例如鏡頭、畫質）；選項加進 items 供 menuNeedsUpdate 打勾。
    private func makeChoiceMenu(title: String, choices: [(String, String)], action: Selector,
                                into items: inout [NSMenuItem], in menu: NSMenu) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (raw, label) in choices {
            let item = makeItem(title: label, action: action)
            item.representedObject = raw
            submenu.addItem(item)
            items.append(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        return item
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// 主題縮圖跟著配色與雕塑色彩；設定沒變就沿用。
    private func refreshThumbnails() {
        let look = panelController.config.look
        guard thumbnailLook?.palette != look.palette || thumbnailLook?.sculptureStyle != look.sculptureStyle
                || thumbnailLook?.terrainSurface != look.terrainSurface else { return }
        thumbnailLook = look
        let images = ThemeThumbnails.make(look: look)
        for item in themeItems {
            if let raw = item.representedObject as? String, let theme = ThemeID(rawValue: raw) { item.image = images[theme] }
        }
    }

    @objc private func selectPresentation(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = ScenePresentation(rawValue: raw) else { return }
        panelController.setPresentation(value)
    }

    @objc private func selectQuality(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = RenderQuality(rawValue: raw) else { return }
        panelController.setQuality(value)
    }

    @objc private func selectTerrainSurface(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = TerrainSurface(rawValue: raw) else { return }
        panelController.setTerrainSurface(value)
    }

    private static func title(for style: SculptureStyle) -> String {
        switch style {
        case .porcelain: "白瓷 Porcelain"
        case .graphite: "石墨 Graphite"
        case .aurora: "極光 Aurora"
        case .sakura: "櫻花 Sakura"
        case .amber: "琥珀 Amber"
        case .jade: "翡翠 Jade"
        case .neon: "霓虹 Neon"
        case .palette: "跟隨配色"
        }
    }

    /// 雕塑色彩的色票：材質底色的三段漸層，中間點綴強調色。
    private static func swatch(for style: SculptureStyle) -> NSImage {
        let colors = SculptureStyleColors.of(style)
        func ns(_ c: RGB) -> NSColor {
            NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
        }
        return NSImage(size: NSSize(width: 28, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            let stops = [0.0, 0.5, 1.0].map { ns(colors.baseColor(at: $0, palette: .lab)) }
            NSGradient(colors: stops)?.draw(in: path, angle: 0)
            ns(colors.accent).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    private static func title(for theme: ThemeID) -> String {
        switch theme {
        case .bars: "經典直條"
        case .radial: "圓環放射"
        case .neon: "霓虹光暈"
        case .led: "極簡點陣"
        case .orbit: "軌道"
        case .hud: "儀表"
        case .constellation: "星圖"
        case .mobius, .analysis: "無限 Möbius"
        case .blackHole: "黑洞・3D"
        case .particleSphere: "粒子球・3D"
        case .terrain: "音訊地形・3D"
        }
    }

    @objc private func toggleVisibility() {
        panelController.toggleVisibility()
    }

    @objc private func toggleDockIcon() {
        setDockIconVisible(!isDockIconVisible())
    }

    @objc private func toggleNowPlayingArtwork() {
        setNowPlayingArtworkEnabled(!isNowPlayingArtworkEnabled())
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

    @objc private func selectSculptureStyle(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String,
              let style = SculptureStyle(rawValue: rawValue) else { return }
        panelController.setSculptureStyle(style)
    }

    /// 選單裡的「透明度」：一列，滑桿跟著選單寬度伸長；拖曳時即時套用，選單保持開啟。
    private func makeOpacityItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        container.autoresizingMask = [.width]
        opacityLabel.font = NSFont.menuFont(ofSize: 0)
        opacityLabel.stringValue = "透明度"
        opacityLabel.frame = NSRect(x: 20, y: 5, width: 48, height: 18)
        opacitySlider.frame = NSRect(x: 70, y: 4, width: 96, height: 20)
        opacitySlider.autoresizingMask = [.width]
        opacitySlider.controlSize = .small
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.setAccessibilityLabel("浮動視窗透明度")
        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        opacityValueLabel.textColor = .secondaryLabelColor
        opacityValueLabel.alignment = .right
        opacityValueLabel.frame = NSRect(x: 168, y: 6, width: 38, height: 16)
        opacityValueLabel.autoresizingMask = [.minXMargin]
        container.addSubview(opacityLabel)
        container.addSubview(opacitySlider)
        container.addSubview(opacityValueLabel)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func updateOpacityLabel() {
        opacityValueLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        panelController.setOpacity(sender.doubleValue)
        updateOpacityLabel()
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
