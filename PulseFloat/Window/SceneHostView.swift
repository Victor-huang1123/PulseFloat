import AppKit
import PulseFloatCore
import PulseFloatScene
import QuartzCore

/// SceneKit 主題的宿主：CAMetalLayer 背板＋`SceneRenderer`，由唯一的 FrameClock 經 VisualizerView 驅動。
/// 主題靜止時不重繪（GPU 也不工作）。雕塑模式可以 ⌥ 拖曳旋轉、捲動縮放、雙擊重設鏡頭（明確的使用者操作，靜音時也有效）。
/// 只在主執行緒使用。
@MainActor
final class SceneHostView: NSView {
    private let renderer = SceneRenderer()
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var themeID: ThemeID?
    private var look = VisualizerConfig.Look()
    private var yaw: Float = 0, pitch: Float = 0, zoom: Float = 1
    private var dragStart: NSPoint?
    private var dragStartAngles: (Float, Float) = (0, 0)

    /// 沒有 Metal 裝置時為 false（VisualizerView 改用 Core Graphics 備援）。
    var isAvailable: Bool { renderer != nil }
    /// 最近一幀的 CPU／GPU 時間（選單顯示用）。
    var timing: SceneTiming? { renderer?.timing }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer?.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.backgroundColor = CGColor(gray: 0, alpha: 0)
        return layer
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// 按住 ⌥ 時把拖曳留給鏡頭旋轉，其他時候照常拖動視窗。
    override var mouseDownCanMoveWindow: Bool {
        !(look.presentation == .sculpture && NSEvent.modifierFlags.contains(.option))
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            applySettings()
            renderer?.invalidate()
        }
    }

    /// 切換主題或外觀設定。
    func configure(theme: ThemeID, look: VisualizerConfig.Look) {
        self.look = look
        if themeID != theme {
            themeID = theme
            renderer?.setTheme(theme, settings: settings())
        } else {
            applySettings()
        }
        renderer?.invalidate()
    }

    private func settings() -> SceneSettings {
        let aspect = bounds.height > 0 ? Double(bounds.width / bounds.height) : 2.6
        return SceneSettings(look: look, aspect: aspect)
    }

    private func applySettings() {
        renderer?.apply(settings())
    }

    /// 前進一幀並繪製（靜止時略過）。
    func show(frame: SpectrumFrame, dt: TimeInterval) {
        guard let metalLayer, window?.isVisible == true, !isHidden else { return }
        renderer?.render(frame: frame, dt: dt, into: metalLayer)
    }

    /// 正在播放的封面（黑洞會放進事件視界；其他 3D 主題忽略）。
    func setArtwork(_ image: CGImage?) { renderer?.setArtwork(image) }

    /// 下一幀一定重繪（視窗重新顯示時）。
    func invalidate() { renderer?.invalidate() }

    // MARK: - 雕塑模式的鏡頭操作

    override func scrollWheel(with event: NSEvent) {
        guard look.presentation == .sculpture else { return super.scrollWheel(with: event) }
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04)
        zoom = min(1.8, max(0.6, zoom * (1 - delta)))
        renderer?.setUserCamera(yaw: yaw, pitch: pitch, zoom: zoom)
    }

    override func mouseDown(with event: NSEvent) {
        if look.presentation == .sculpture && event.clickCount == 2 {
            yaw = 0; pitch = 0; zoom = 1
            renderer?.setUserCamera(yaw: yaw, pitch: pitch, zoom: zoom)
            return
        }
        guard look.presentation == .sculpture, event.modifierFlags.contains(.option) else { return super.mouseDown(with: event) }
        dragStart = NSEvent.mouseLocation
        dragStartAngles = (yaw, pitch)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return super.mouseDragged(with: event) }
        let location = NSEvent.mouseLocation
        yaw = dragStartAngles.0 - Float(location.x - dragStart.x) * 0.5
        pitch = min(60, max(-30, dragStartAngles.1 - Float(location.y - dragStart.y) * 0.3))
        renderer?.setUserCamera(yaw: yaw, pitch: pitch, zoom: zoom)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart == nil { super.mouseUp(with: event) }
        dragStart = nil
    }
}
