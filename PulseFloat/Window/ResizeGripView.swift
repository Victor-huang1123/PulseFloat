import AppKit
import PulseFloatCore

/// 16 × 16 pt 的縮放抓把；以螢幕座標拖曳並固定視窗左上角。
@MainActor
final class ResizeGripView: NSView {
    private var startLocation: NSPoint?
    private var startFrame = NSRect.zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 12, y: 4))
        context.addLine(to: CGPoint(x: 12, y: 9))
        context.addQuadCurve(to: CGPoint(x: 9, y: 12), control: CGPoint(x: 12, y: 12))
        context.addLine(to: CGPoint(x: 4, y: 12))
        context.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startLocation = NSEvent.mouseLocation
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation, let window else { return }
        var width = max(WindowGeometry.minWidth, startFrame.width + NSEvent.mouseLocation.x - startLocation.x)
        // 不超過螢幕上限，並讓右緣與下緣留在可用範圍內（左上角固定）。
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            width = min(width, WindowGeometry.maxWidth(in: visible),
                        max(WindowGeometry.minWidth, visible.maxX - startFrame.minX),
                        max(WindowGeometry.minWidth, (startFrame.maxY - visible.minY) * WindowGeometry.aspect))
        }
        let height = width / WindowGeometry.aspect
        window.setFrame(NSRect(
            x: startFrame.minX,
            y: startFrame.maxY - height,
            width: width,
            height: height
        ), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        startLocation = nil
        window?.invalidateShadow()
    }
}
