import AppKit
import PulseFloatCore
import PulseFloatScene

/// 顯示 FrameClock 分送的最新頻譜；所有狀態與繪圖均在主執行緒。
@MainActor
final class VisualizerView: NSView {
    private var renderer: any SpectrumRenderer
    private var look: VisualizerConfig.Look
    private var latestFrame: SpectrumFrame
    private var latestDT: TimeInterval = 0
    /// SceneKit 主題（黑洞、粒子球、音訊地形）的 Metal 宿主；2D 主題時隱藏。
    private let sceneHost = SceneHostView(frame: .zero)
    private var sceneActive: Bool { look.theme.isScene && sceneHost.isAvailable }
    /// 3D 主題最近一幀的 CPU／GPU 時間（2D 主題時為 nil）。
    var sceneTiming: SceneTiming? { sceneActive ? sceneHost.timing : nil }

    init(config: VisualizerConfig) {
        let config = config.clamped()
        look = config.look
        renderer = RendererFactory.make(theme: config.look.theme)
        latestFrame = .silent(bandCount: config.bands.count)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        addSubview(sceneHost)
        updateSceneHost()
    }

    override func layout() {
        super.layout()
        sceneHost.frame = bounds
    }

    private func updateSceneHost() {
        sceneHost.isHidden = !sceneActive
        if sceneActive { sceneHost.configure(theme: look.theme, look: look) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    /// 接收秒為單位的 dt；隱藏時不儲存 frame，也不要求重畫。
    func show(frame: SpectrumFrame, dt: TimeInterval) {
        guard window?.isVisible == true else { return }
        latestFrame = frame
        latestDT = dt.isFinite ? min(max(dt, 0), 0.05) : 0
        if sceneActive {
            sceneHost.show(frame: frame, dt: latestDT)
            return
        }
        needsDisplay = true
    }

    func update(config: VisualizerConfig) {
        let nextLook = config.clamped().look
        if look.theme != nextLook.theme {
            // 每次切換建立新 renderer，丟棄 neon 的 offscreen 殘影。
            renderer = RendererFactory.make(theme: nextLook.theme)
        }
        look = nextLook
        updateSceneHost()
        needsDisplay = true
    }

    /// 隱藏時丟棄殘影；恢復顯示後由下一個共用 tick 提供最新資料。
    func resetRendering() {
        renderer = RendererFactory.make(theme: look.theme)
        latestFrame = .silent(bandCount: latestFrame.bandCount)
        latestDT = 0
        sceneHost.invalidate()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        guard !sceneActive else { return }
        renderer.draw(
            in: context,
            size: bounds.size,
            frame: latestFrame,
            look: look,
            options: RenderOptions(
                fade: 1 - exp(-latestDT / 0.07),
                scale: window?.backingScaleFactor ?? 2,
                dt: latestDT,
                sculptureStyle: look.sculptureStyle
            )
        )
    }
}
