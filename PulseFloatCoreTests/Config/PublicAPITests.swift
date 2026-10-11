import PulseFloatCore
import XCTest

final class PublicAPITests: XCTestCase {
    func testPublicInitializersAndMutableFields() {
        var bands = VisualizerConfig.Bands()
        bands.count = 80
        bands.fMinHz = 40
        bands.fMaxHz = 18000
        bands.tiltDbPerOct = 4
        XCTAssertEqual(bands, VisualizerConfig.Bands(count: 80, fMinHz: 40, fMaxHz: 18000, tiltDbPerOct: 4))

        var level = VisualizerConfig.Level()
        level.agc = false
        level.rangeDb = 60
        level.ceilingDb = -20
        level.agcReleaseDbPerSec = 8
        level.gamma = 2
        level.gateDb = -100
        XCTAssertEqual(level, VisualizerConfig.Level(agc: false, rangeDb: 60, ceilingDb: -20, agcReleaseDbPerSec: 8, gamma: 2, gateDb: -100))

        var motion = VisualizerConfig.Motion()
        motion.attackMs = 20
        motion.releaseMs = 200
        motion.spatial = 0.5
        motion.peakHoldMs = 300
        motion.peakGravity = 5
        XCTAssertEqual(motion, VisualizerConfig.Motion(attackMs: 20, releaseMs: 200, spatial: 0.5, peakHoldMs: 300, peakGravity: 5))

        var look = VisualizerConfig.Look()
        look.theme = .led
        look.palette = .glacier
        look.mirror = true
        look.reflection = false
        look.barGap = 0.5
        look.windowMode = .bare
        look.opacity = 0.8
        XCTAssertEqual(look, VisualizerConfig.Look(theme: .led, palette: .glacier, mirror: true, reflection: false, barGap: 0.5, windowMode: .bare, opacity: 0.8))

        var menubar = VisualizerConfig.MenuBar()
        menubar.style = .dots
        menubar.count = 5
        menubar.colored = true
        XCTAssertEqual(menubar, VisualizerConfig.MenuBar(style: .dots, count: 5, colored: true))

        var config = VisualizerConfig()
        config.bands = bands
        config.level = level
        config.motion = motion
        config.look = look
        config.menubar = menubar
        XCTAssertEqual(config, VisualizerConfig(bands: bands, level: level, motion: motion, look: look, menubar: menubar))

        var frame = SpectrumFrame(values: [0.1, 0.3], peaks: [0.5, 0.7], bass: 0.2)
        frame.values = [0.2, 0.4]
        frame.peaks = [0.6, 0.8]
        frame.bass = 0.3
        XCTAssertEqual(frame, SpectrumFrame(values: [0.2, 0.4], peaks: [0.6, 0.8], bass: 0.3))
        XCTAssertEqual(frame.bandCount, 2)
    }

    @MainActor
    func testSourceIsUsableThroughPublicProtocol() {
        let source: any SpectrumSource = TestSpectrumSource()
        XCTAssertEqual(source.nextFrame(dt: 1.0 / 60), .silent(bandCount: 4))
    }

    func testPublicValueTypesAreSendable() {
        requireSendable(SpectrumFrame.self)
        requireSendable(VisualizerConfig.self)
        requireSendable(VisualizerConfig.Bands.self)
        requireSendable(VisualizerConfig.Level.self)
        requireSendable(VisualizerConfig.Motion.self)
        requireSendable(VisualizerConfig.Look.self)
        requireSendable(VisualizerConfig.MenuBar.self)
        requireSendable(ThemeID.self)
        requireSendable(PaletteID.self)
        requireSendable(WindowMode.self)
        requireSendable(MenuBarStyle.self)
    }

    @MainActor
    func testSourceSupportsWeakReferences() {
        let box = WeakSpectrumSourceBox()
        do {
            let source: any SpectrumSource = TestSpectrumSource()
            box.source = source
            withExtendedLifetime(source) {
                XCTAssertNotNil(box.source)
            }
        }
        XCTAssertNil(box.source)
    }
}

private func requireSendable<T: Sendable>(_: T.Type) {}

@MainActor
private final class WeakSpectrumSourceBox {
    weak var source: (any SpectrumSource)?
}

@MainActor
private final class TestSpectrumSource: SpectrumSource {
    func nextFrame(dt: TimeInterval) -> SpectrumFrame {
        .silent(bandCount: 4)
    }
}
