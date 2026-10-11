import AppKit
import PulseFloatCore

/// 管理浮動視窗與記憶體內設定；HUD、選單與 FrameClock 均在主執行緒操作。
@MainActor
final class FloatingPanelController {
    private(set) var config: VisualizerConfig
    private(set) var isLocked = false
    var isVisible: Bool { panel.isVisible }
    let visualizerView: VisualizerView

    private let panel = FloatingPanel()
    private let chromeView: FloatingChromeView

    init(config: VisualizerConfig = VisualizerConfig()) {
        self.config = config.clamped()
        visualizerView = VisualizerView(config: self.config)
        chromeView = FloatingChromeView(visualizerView: visualizerView, mode: self.config.look.windowMode)
        chromeView.hud.onCycleTheme = { [weak self] in self?.cycleTheme() }
        chromeView.hud.onToggleLock = { [weak self] in self?.toggleLock() }
        chromeView.hud.onHide = { [weak self] in self?.hide() }
        panel.alphaValue = self.config.look.opacity
        installContentView()
        observeFrame()
    }

    /// 移動或縮放後記住位置與大小；螢幕配置改變（接上／拔掉外接螢幕、改解析度）時夾回可用範圍。
    private func observeFrame() {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map { ConfigStore.saveWindowFrame($0.panel.frame) } }
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.panel.restoreFrame($0.panel.frame) } }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        chromeView.refreshHover()
    }

    func hide() {
        chromeView.setHovered(false, animated: false)
        panel.orderOut(nil)
        visualizerView.resetRendering()
    }

    func toggleVisibility() {
        if isVisible { hide() } else { show() }
    }

    func toggleLock() {
        isLocked.toggle()
        panel.isMovableByWindowBackground = !isLocked
        panel.ignoresMouseEvents = isLocked
        chromeView.setLocked(isLocked)
    }

    func cycleTheme() {
        let themes = ThemeID.allCases
        guard let index = themes.firstIndex(of: config.look.theme) else { return }
        setTheme(themes[(index + 1) % themes.count])
    }

    /// 設定改變時通知 App 層（用來存檔）；只在主執行緒呼叫。
    var onConfigChange: ((VisualizerConfig) -> Void)?

    func setTheme(_ theme: ThemeID) {
        config.look.theme = theme
        config = config.clamped()
        visualizerView.update(config: config)
        onConfigChange?(config)
    }

    func setPalette(_ palette: PaletteID) {
        guard config.look.palette != palette else { return }
        config.look.palette = palette
        visualizerView.update(config: config)
        onConfigChange?(config)
    }

    /// 3D 雕塑主題（無限、解析）的材質色彩；其他主題不受影響。
    func setSculptureStyle(_ style: SculptureStyle) {
        guard config.look.sculptureStyle != style else { return }
        config.look.sculptureStyle = style
        visualizerView.update(config: config)
        onConfigChange?(config)
    }

    /// 浮動視窗整體不透明度（0.3...1，超出會被夾住）；即時套用並存檔。
    func setOpacity(_ opacity: Double) {
        var next = config
        next.look.opacity = opacity
        next = next.clamped()
        guard next.look.opacity != config.look.opacity else { return }
        config = next
        panel.alphaValue = config.look.opacity
        onConfigChange?(config)
    }

    /// 選單列圖示是否使用配色（關閉時是跟隨系統的單色 template 圖示）。
    func setMenuBarColored(_ colored: Bool) {
        guard config.menubar.colored != colored else { return }
        config.menubar.colored = colored
        onConfigChange?(config)
    }

    func setWindowMode(_ mode: WindowMode) {
        guard config.look.windowMode != mode else { return }
        config.look.windowMode = mode
        config = config.clamped()
        chromeView.mode = config.look.windowMode
        installContentView()
        visualizerView.update(config: config)
        chromeView.refreshHover()
        onConfigChange?(config)
    }

    private func installContentView() {
        // 先解除舊 contentView，避免 AppKit 在換 root 時再把已搬移的 chrome 移走。
        panel.contentView = nil
        chromeView.removeFromSuperview()
        chromeView.frame = NSRect(origin: .zero, size: panel.frame.size)
        chromeView.autoresizingMask = [.width, .height]
        switch config.look.windowMode {
        case .card:
            let effectView = NSVisualEffectView(frame: chromeView.frame)
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.maskImage = Self.roundedMaskImage()
            effectView.addSubview(chromeView)
            panel.contentView = effectView
            panel.hasShadow = true
        case .bare:
            panel.contentView = chromeView
            panel.hasShadow = false
        }
        chromeView.needsLayout = true
        panel.invalidateShadow()
    }

    private static func roundedMaskImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 29, height: 29), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        image.resizingMode = .stretch
        return image
    }
}
