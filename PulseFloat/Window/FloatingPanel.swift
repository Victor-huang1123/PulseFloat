import AppKit
import PulseFloatCore

/// 不取得鍵盤焦點的浮動視窗；只在主執行緒使用，尺寸單位為 pt。
@MainActor
final class FloatingPanel: NSPanel {
    init() {
        let size = NSSize(width: WindowGeometry.defaultWidth, height: WindowGeometry.defaultWidth / WindowGeometry.aspect)
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
        minSize = NSSize(width: WindowGeometry.minWidth, height: WindowGeometry.minWidth / WindowGeometry.aspect)
        contentAspectRatio = NSSize(width: WindowGeometry.aspect, height: 1)
        isReleasedWhenClosed = false
        restoreFrame(ConfigStore.loadWindowFrame())
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 放回上次的位置與大小（沒有存過就用預設），並夾在所在螢幕的可用範圍內；
    /// 原本的螢幕已經不在時，保留大小、移到主螢幕。
    func restoreFrame(_ saved: NSRect?) {
        let visibles = NSScreen.screens.map(\.visibleFrame)
        guard let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        guard let saved else {
            setFrame(WindowGeometry.defaultFrame(in: main), display: false)
            return
        }
        let visible = WindowGeometry.bestVisibleFrame(for: saved, among: visibles) ?? main
        setFrame(WindowGeometry.fit(saved, in: visible), display: true)
    }
}
