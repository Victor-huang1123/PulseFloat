import PulseFloatCore
@testable import PulseFloatScene
import XCTest

/// 黑洞主題自己的檢查：音訊對應（低頻／起音／高頻／中頻／立體聲各自驅動對的東西）、靜音凍結、
/// 畫質改變粒子數、事件視界在任何桌布上都是不透明的黑色。
@MainActor
final class BlackHoleThemeTests: XCTestCase {
    private let dt = 1.0 / 60

    private func features(activity: Float = 1, bass: Float = 0, mid: Float = 0, treble: Float = 0, energy: Float = 0,
                          level: Float = 0, onset: Bool = false, envelope: Float = 0, balance: Float = 0,
                          time: Double = 0) -> AudioFeatures {
        var f = AudioFeatures()
        f.activity = activity
        f.bass = bass
        f.mid = mid
        f.treble = treble
        f.energy = energy
        f.level = level
        f.onset = onset
        f.onsetEnvelope = envelope
        f.balance = balance
        f.time = time
        return f
    }

    private func run(_ state: inout BlackHoleAudioState, _ f: AudioFeatures, seconds: Double, values: [Float] = []) {
        var t = 0.0
        while t < seconds {
            state.advance(features: f, values: values, dt: dt)
            t += dt
        }
    }

    // MARK: - 音訊對應

    func testBassThickensDiskPulsesCoreAndSpeedsInflow() {
        var quiet = BlackHoleAudioState(), loud = BlackHoleAudioState()
        run(&quiet, features(bass: 0), seconds: 1)
        // 低頻突然變大：核心脈動（瞬變），厚度跟上
        run(&loud, features(bass: 0), seconds: 0.5)
        run(&loud, features(bass: 0.9), seconds: 0.12)
        XCTAssertGreaterThan(loud.core, 0.3, "低頻瞬變讓黑色核心脈動")
        XCTAssertGreaterThan(loud.coreScale, 1.01)
        run(&loud, features(bass: 0.9), seconds: 1)
        XCTAssertGreaterThan(loud.thickness, 0.8, "低頻撐開盤面厚度")
        XCTAssertEqual(quiet.thickness, 0)
        XCTAssertLessThan(loud.core, 0.2, "持續的低頻不再脈動（只有瞬變會）")
        // 螺旋密度波（往內的能量流）在低頻大時前進得比較快
        var a = BlackHoleAudioState(), b = BlackHoleAudioState()
        run(&a, features(bass: 0), seconds: 1)
        run(&b, features(bass: 1), seconds: 1)
        XCTAssertGreaterThan(b.spiralPhase, a.spiralPhase * 2)
    }

    func testOnsetLaunchesOutwardPulseThatFadesCompletely() {
        var state = BlackHoleAudioState()
        let layout = BlackHoleLayout()
        state.advance(features: features(bass: 0.8, onset: true, envelope: 1), values: [], dt: dt)
        XCTAssertTrue(state.hasActivePulse)
        run(&state, features(bass: 0.8), seconds: 0.1)
        let early = state.pulse(0, inner: layout.inner, outer: layout.outer)
        run(&state, features(bass: 0.8), seconds: 0.4)
        let later = state.pulse(0, inner: layout.inner, outer: layout.outer)
        XCTAssertGreaterThan(early.amplitude, 0.3)
        XCTAssertGreaterThan(later.radius, early.radius + 0.3, "脈衝往外傳")
        XCTAssertLessThan(later.amplitude, early.amplitude, "脈衝一邊傳一邊變淡")
        run(&state, features(bass: 0.8), seconds: Double(BlackHoleAudioState.pulseLife))
        XCTAssertFalse(state.hasActivePulse, "壽命結束後完全歸零")
        XCTAssertEqual(state.pulse(0, inner: layout.inner, outer: layout.outer).amplitude, 0)
    }

    func testTrebleTransientsTriggerBriefSparksAndLightUpDust() {
        var state = BlackHoleAudioState()
        run(&state, features(treble: 0), seconds: 0.5)
        run(&state, features(treble: 0.8), seconds: 0.08)
        XCTAssertGreaterThan(state.spark, 0.5, "高頻瞬變觸發火花")
        XCTAssertGreaterThan(state.trebleGlow, 0.4, "高頻提高細塵亮度")
        run(&state, features(treble: 0.8), seconds: 2)
        XCTAssertLessThan(state.spark, 0.05, "持續的高頻不會一直有火花（火花很短暫）")
        XCTAssertGreaterThan(state.trebleGlow, 0.75)
    }

    func testMidDeformsStreamsAndRings() {
        var state = BlackHoleAudioState()
        var values = [Float](repeating: 0, count: 64)
        var i = 16
        while i < 43 { values[i] = 0.8; i += 1 }
        run(&state, features(mid: 0.8), seconds: 1, values: values)
        XCTAssertGreaterThan(state.mid, 0.7, "中頻 → 粒子流變形量")
        XCTAssertGreaterThan(state.harmonics.min(), 0.6, "中頻三段 → 細環的 2、3、5 次諧波")
        var flat = BlackHoleAudioState()
        run(&flat, features(mid: 0), seconds: 1, values: [Float](repeating: 0, count: 64))
        XCTAssertEqual(flat.harmonics, SIMD3<Float>(repeating: 0))
        XCTAssertGreaterThan(state.midPhase, flat.midPhase, "中頻讓環的變形相位前進得比較快")
    }

    func testStereoBalanceIntroducesAsymmetry() {
        var state = BlackHoleAudioState()
        run(&state, features(balance: 0.8), seconds: 2)
        XCTAssertGreaterThan(state.balance, 0.7)
        run(&state, features(balance: -0.8), seconds: 2)
        XCTAssertLessThan(state.balance, -0.7)
    }

    func testMotionOnlyAdvancesWithAudioActivity() {
        var state = BlackHoleAudioState()
        run(&state, features(activity: 0, bass: 0.9, energy: 0.9), seconds: 2)
        XCTAssertEqual(state.flowPhase, 0)
        XCTAssertEqual(state.orbitPhase, 0)
        XCTAssertEqual(state.spiralPhase, 0)
        XCTAssertEqual(state.midPhase, 0)
        var soft = BlackHoleAudioState(), loud = BlackHoleAudioState()
        run(&soft, features(energy: 0.1), seconds: 1)
        run(&loud, features(energy: 0.9), seconds: 1)
        XCTAssertGreaterThan(loud.flowPhase, soft.flowPhase * 1.4, "盤面轉速跟著音量，不是固定速度")
        XCTAssertGreaterThan(loud.orbitPhase, soft.orbitPhase * 1.4)
    }

    func testPhaseWrapsAreSeamless() {
        // 平均角速度量化到 1/8：軌道相位在 16π 折回時每顆粒子剛好轉了整數圈
        let n = BlackHoleMeshes.meanMotion(semiMajor: 0.83, inner: BlackHoleLayout().inner)
        let turns = Double(n) * BlackHoleMeshes.orbitWrap / (2 * Double.pi)
        XCTAssertEqual(turns, turns.rounded(), accuracy: 1e-9)
        // flow map 週期 6、種子 64 個一輪
        XCTAssertEqual(BlackHoleAudioState.flowWrap.truncatingRemainder(dividingBy: 6 * 64), 0)
        XCTAssertEqual(BlackHoleAudioState.wrap(16 * Double.pi + 0.25, BlackHoleMeshes.orbitWrap), 0.25, accuracy: 1e-12)
    }

    func testMalformedFeaturesDoNotPoisonState() {
        var state = BlackHoleAudioState()
        var f = features(bass: .nan, mid: .infinity, treble: -3, energy: .nan, balance: .nan, time: .nan)
        f.activity = .nan
        run(&state, f, seconds: 0.5, values: [Float](repeating: .nan, count: 64))
        XCTAssertTrue(state.thickness.isFinite && state.mid.isFinite && state.spark.isFinite)
        XCTAssertTrue(state.flowPhase.isFinite && state.orbitPhase.isFinite)
        XCTAssertTrue(state.harmonics.x.isFinite)
    }

    // MARK: - 靜音

    func testSilenceSettlesEverythingAndFreezes() throws {
        let theme = BlackHoleTheme()
        theme.apply(SceneSettings(style: .amber, presentation: .compact, quality: .high))
        let audio = DemoAudio(seed: 11)
        audio.program = .music
        var t = 0.0
        while t < 3 { theme.update(frame: audio.next(dt: dt), dt: dt); t += dt }
        XCTAssertFalse(theme.isAtRest)
        audio.program = .silence
        t = 0
        while t < 3.5 { theme.update(frame: audio.next(dt: dt), dt: dt); t += dt }
        XCTAssertTrue(theme.isAtRest, "靜音 3.5 秒內所有平滑值與脈衝都要收斂")
        let frozen = theme.state
        let scale = theme.horizonScale
        t = 0
        while t < 2 { theme.update(frame: audio.next(dt: dt), dt: dt); t += dt }
        XCTAssertEqual(theme.state, frozen, "靜音時狀態完全不變（相位、脈衝、平滑值）")
        XCTAssertEqual(theme.horizonScale, scale)
        XCTAssertEqual(scale, 1, "核心脈動歸位")
        XCTAssertFalse(frozen.hasActivePulse)
    }

    // MARK: - 畫質與呈現

    func testQualityAndPresentationChangeDetail() {
        let theme = BlackHoleTheme()
        var counts: [Int] = []
        for quality in RenderQuality.allCases {
            theme.apply(SceneSettings(presentation: .compact, quality: quality))
            counts.append(theme.particleCount)
        }
        XCTAssertLessThan(counts[0], counts[1])
        XCTAssertLessThan(counts[1], counts[2])
        theme.apply(SceneSettings(presentation: .compact, quality: .medium))
        let compact = theme.particleCount
        let compactRings = theme.layout.rings.count
        theme.apply(SceneSettings(presentation: .sculpture, quality: .medium))
        XCTAssertGreaterThan(theme.particleCount, compact, "雕塑模式的粒子流更豐富")
        XCTAssertGreaterThan(theme.layout.rings.count, compactRings)
        XCTAssertLessThan(BlackHoleLayout.make(quality: .low, presentation: .compact).diskAngular,
                          BlackHoleLayout.make(quality: .high, presentation: .compact).diskAngular)
    }

    func testEveryStyleHasItsOwnPalette() {
        var hot: [RGB] = []
        for style in SculptureStyle.allCases where style != .palette {
            hot.append(BlackHolePalette.make(style: style, palette: .aurora).hot)
        }
        XCTAssertEqual(Set(hot.map { "\($0.red),\($0.green),\($0.blue)" }).count, hot.count, "每種風格的內緣顏色不同")
        XCTAssertNotEqual(BlackHolePalette.make(style: .palette, palette: .ember).mid,
                          BlackHolePalette.make(style: .palette, palette: .glacier).mid, "palette 風格跟隨配色")
    }

    // MARK: - 畫面

    func testEventHorizonIsOpaqueBlackAndDiskIsVisible() throws {
        for presentation in ScenePresentation.allCases {
            let renderer = try XCTUnwrap(SceneRenderer())
            renderer.setTheme(.blackHole, settings: SceneSettings(style: .amber, presentation: presentation, quality: .medium))
            let audio = DemoAudio(seed: 3)
            audio.program = .music
            var t = 0.0
            while t < 2 { renderer.advance(frame: audio.next(dt: dt), dt: dt); t += dt }
            let image = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 520, height: 200))
            // 找出畫面中央附近最暗、完全不透明的區域：事件視界（在淺色桌布上也必須是黑的）
            var opaqueBlack = 0, bright = 0
            var y = 60
            while y < 140 {
                var x = 230
                while x < 290 {
                    let i = (y * image.width + x) * 4
                    if image.pixels[i + 3] == 255 && image.pixels[i] < 8 && image.pixels[i + 1] < 8 && image.pixels[i + 2] < 8 { opaqueBlack += 1 }
                    x += 1
                }
                y += 1
            }
            var i = 0
            while i < image.pixels.count {
                if image.pixels[i + 2] > 200 && image.pixels[i + 3] > 200 { bright += 1 }
                i += 4
            }
            XCTAssertGreaterThan(opaqueBlack, 600, "\(presentation)：中央要有不透明的黑色陰影")
            XCTAssertGreaterThan(bright, 1500, "\(presentation)：吸積盤要有明亮、不透明的部分（淺色桌布上也看得到）")
        }
    }
}
