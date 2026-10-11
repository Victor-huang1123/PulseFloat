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

    /// 圓環中央的封面或 App 圖示（只有圓環放射會畫）；nil 時畫面與原本相同。
    var artwork: CenterArtwork? {
        didSet { if artwork != oldValue { needsDisplay = true } }
    }
    /// 浮動視窗看得到（可見且沒有被遮住、螢幕沒睡）且主題是圓環放射時為 true。
    private(set) var isShowingRadial = false
    /// isShowingRadial 改變時呼叫（App 層用來啟停「正在播放」偵測）。
    var onRadialVisibilityChange: ((Bool) -> Void)?
    private var occlusionObserver: (any NSObjectProtocol)?

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

    /// 螢幕睡眠、視窗在別的桌面空間或被完全遮住時 FrameClock 不一定還有 tick，所以另外跟著遮蔽狀態更新。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRadialVisibility() }
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    /// 接收秒為單位的 dt；隱藏時不儲存 frame，也不要求重畫。
    func show(frame: SpectrumFrame, dt: TimeInterval) {
        refreshRadialVisibility()
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
        refreshRadialVisibility()
    }

    /// 隱藏時丟棄殘影；恢復顯示後由下一個共用 tick 提供最新資料。
    func resetRendering() {
        renderer = RendererFactory.make(theme: look.theme)
        latestFrame = .silent(bandCount: latestFrame.bandCount)
        latestDT = 0
        sceneHost.invalidate()
        needsDisplay = true
        refreshRadialVisibility()
    }

    /// 每個 tick 都會呼叫，只比較兩個值；狀態真的改變才通知。
    /// 切換視窗樣式時 view 會短暫離開視窗，但那發生在兩個 tick 之間，不會誤判成隱藏。
    private func refreshRadialVisibility() {
        let showing = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && look.theme == .radial
        guard showing != isShowingRadial else { return }
        isShowingRadial = showing
        onRadialVisibilityChange?(showing)
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
                sculptureStyle: look.sculptureStyle,
                artwork: artwork
            )
        )
    }
}
