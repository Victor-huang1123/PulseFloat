import AppKit
import PulseFloatCore

/// 卡片色層、內框與滑過控制項的容器；座標與尺寸以左上角及 pt 表示。
@MainActor
final class FloatingChromeView: NSView {
    let hud = FloatingHUDView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    let grip = ResizeGripView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let visualizerView: VisualizerView
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isLocked = false
    var mode: WindowMode {
        didSet { needsDisplay = true }
    }

    init(visualizerView: VisualizerView, mode: WindowMode) {
        self.visualizerView = visualizerView
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        addSubview(visualizerView)
        addSubview(hud)
        addSubview(grip)
        hud.alphaValue = 0
        grip.alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        visualizerView.frame = bounds
        hud.frame.origin = NSPoint(x: bounds.width - 88, y: 8)
        grip.frame.origin = NSPoint(x: bounds.width - 18, y: bounds.height - 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        if mode == .card {
            context.setFillColor(NSColor(srgbRed: 14.0 / 255, green: 16.0 / 255, blue: 24.0 / 255, alpha: 0.42).cgColor)
            context.fill(bounds)
        }
        guard mode == .card || isHovered else { return }
        let width: CGFloat = mode == .card ? 0.5 : 1
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
            cornerWidth: 14 - width / 2,
            cornerHeight: 14 - width / 2,
            transform: nil
        )
        context.addPath(path)
        context.setLineWidth(width)
        context.setStrokeColor(NSColor.white.withAlphaComponent(mode == .card ? 0.18 : 0.22).cgColor)
        context.strokePath()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHovered(false, animated: true) }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        grip.isHidden = locked
        hud.setLocked(locked)
        if locked {
            setHovered(false, animated: true)
        } else {
            refreshHover()
        }
    }

    func refreshHover() {
        guard let window, window.isVisible else {
            setHovered(false, animated: false)
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setHovered(bounds.contains(point), animated: false)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        isHovered = hovered && !isLocked
        needsDisplay = true
        let hudAlpha: CGFloat = isHovered ? 1 : 0
        let gripAlpha: CGFloat = isHovered ? 0.7 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                hud.animator().alphaValue = hudAlpha
                grip.animator().alphaValue = gripAlpha
            }
        } else {
            hud.alphaValue = hudAlpha
            grip.alphaValue = gripAlpha
        }
    }
}
