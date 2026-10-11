import AppKit

/// 右上角的三個 24 pt 控制項；只在主執行緒處理操作。
@MainActor
final class FloatingHUDView: NSView {
    var onCycleTheme: (() -> Void)?
    var onToggleLock: (() -> Void)?
    var onHide: (() -> Void)?

    private let themeButton = FloatingHUDButton(title: "◐", label: "切換主題")
    private let lockButton = FloatingHUDButton(title: "⌖", label: "鎖定並點擊穿透")
    private let hideButton = FloatingHUDButton(title: "✕", label: "隱藏浮動視窗")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let buttons = [themeButton, lockButton, hideButton]
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: index * 28, y: 0, width: 24, height: 24)
            button.target = self
            addSubview(button)
        }
        themeButton.action = #selector(cycleTheme)
        lockButton.action = #selector(toggleLock)
        hideButton.action = #selector(hidePanel)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func setLocked(_ locked: Bool) {
        lockButton.showsLockedState = locked
        lockButton.state = locked ? .on : .off
        lockButton.needsDisplay = true
    }

    @objc private func cycleTheme() { onCycleTheme?() }
    @objc private func toggleLock() { onToggleLock?() }
    @objc private func hidePanel() { onHide?() }
}

@MainActor
private final class FloatingHUDButton: NSButton {
    var showsLockedState = false

    init(title: String, label: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let locked = showsLockedState
        let accent = NSColor(srgbRed: 1, green: 181.0 / 255, blue: 71.0 / 255, alpha: 1)
        let fill = locked ? accent : NSColor.black.withAlphaComponent(0.45)
        let outline = locked ? accent : NSColor.white.withAlphaComponent(0.14)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        outline.setStroke()
        path.lineWidth = 1
        path.stroke()
        let foreground = locked
            ? NSColor(srgbRed: 26.0 / 255, green: 18.0 / 255, blue: 6.0 / 255, alpha: 1)
            : NSColor.white
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: foreground
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
