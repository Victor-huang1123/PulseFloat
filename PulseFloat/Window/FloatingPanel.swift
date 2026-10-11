import AppKit

/// 不取得鍵盤焦點的浮動視窗；只在主執行緒使用，尺寸單位為 pt。
@MainActor
final class FloatingPanel: NSPanel {
    init() {
        let size = NSSize(width: 520, height: 200)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // 明確設為 false，讓 bare 模式的透明區域也接受拖曳與滑過。
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        minSize = NSSize(width: 182, height: 70)
        contentAspectRatio = NSSize(width: 2.6, height: 1)
        isReleasedWhenClosed = false
        setInitialPosition(size: size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func setInitialPosition(size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visibleFrame.minX + 0.08 * visibleFrame.width,
            y: visibleFrame.maxY - 0.40 * visibleFrame.height - size.height
        ))
    }
}
