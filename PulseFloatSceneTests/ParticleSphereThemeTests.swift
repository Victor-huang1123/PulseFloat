import PulseFloatCore
@testable import PulseFloatScene
import simd
import XCTest

/// 粒子球主題自己的檢查：粒子配置（數量、決定性）、音訊對應（低頻膨脹、中／高頻的球諧區段、
/// 高頻細振動、起音脈衝）、靜音時所有狀態凍結並精確收斂。
@MainActor
final class ParticleSphereThemeTests: XCTestCase {
    private let dt = 1.0 / 60

    // MARK: - 配置

    func testParticleCountsScaleWithQualityAndPresentation() {
        func count(_ q: RenderQuality, _ p: ScenePresentation) -> Int {
            ParticleSphereRecipe.make(quality: q, presentation: p).particleCount
        }
        for p in ScenePresentation.allCases {
            XCTAssertLessThan(count(.low, p), count(.medium, p), "\(p)")
            XCTAssertLessThan(count(.medium, p), count(.high, p), "\(p)")
        }
        for q in RenderQuality.allCases {
            XCTAssertLessThan(count(q, .compact), count(q, .sculpture), "精簡模式粒子較少（\(q)）")
        }
        // 美術指示：雕塑 LOW 約 2–3k、MEDIUM 約 8–12k、HIGH 約 25–40k
        XCTAssertTrue((2_000...3_800).contains(count(.low, .sculpture)), "\(count(.low, .sculpture))")
        XCTAssertTrue((8_000...13_000).contains(count(.medium, .sculpture)), "\(count(.medium, .sculpture))")
        XCTAssertTrue((25_000...40_000).contains(count(.high, .sculpture)), "\(count(.high, .sculpture))")
    }

    func testMeshMatchesRecipeAndHasLinks() {
        let recipe = ParticleSphereRecipe.make(quality: .medium, presentation: .sculpture)
        let mesh = ParticleSphereLayout.build(recipe)
        XCTAssertEqual(mesh.particleCount, recipe.particleCount)
        XCTAssertGreaterThan(mesh.linkCount, recipe.nodes.count, "節點之間應該有連線")
        XCTAssertLessThan(mesh.linkCount, recipe.nodes.count * 4, "連線要稀疏")
        let vertices = mesh.geometry.sources(for: .vertex).first
        XCTAssertEqual(vertices?.vectorCount, recipe.particleCount * 4 + recipe.nodes.count)
        XCTAssertEqual(mesh.geometry.elements.count, 2, "圓點三角形＋連線")
    }

    func testLayoutIsDeterministic() {
        let recipe = ParticleSphereRecipe.make(quality: .low, presentation: .compact)
        let a = ParticleSphereLayout.build(recipe).geometry
        let b = ParticleSphereLayout.build(recipe).geometry
        XCTAssertEqual(a.sources(for: .vertex).first?.data, b.sources(for: .vertex).first?.data, "同一組參數必須得到同一個結構")
        XCTAssertEqual(a.sources(for: .color).first?.data, b.sources(for: .color).first?.data)
    }

    func testShellsSitOnTheirRadii() {
        let recipe = ParticleSphereRecipe.make(quality: .low, presentation: .sculpture)
        let mesh = ParticleSphereLayout.build(recipe)
        guard let source = mesh.geometry.sources(for: .vertex).first else { return XCTFail("沒有頂點") }
        var maxRadius: Float = 0
        source.data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var i = 0
            while i < source.vectorCount {
                let p = SIMD3(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2])
                maxRadius = max(maxRadius, simd_length(p))
                i += 1
            }
        }
        XCTAssertGreaterThan(maxRadius, 1.3, "外殼與光暈在主殼外")
        XCTAssertLessThan(maxRadius, 1.8, "靜止時整個結構在 1.8 以內（相機構圖以此為準）")
    }

    func testHarmonicBasisIsNormalizedLikeTheShader() {
        // 每個基底函數在球面上的最大絕對值約為 1（著色器用同一組係數尺度）
        var j = 0
        while j < ParticleSphereDynamics.coefficientCount {
            var c = [Float](repeating: 0, count: ParticleSphereDynamics.coefficientCount)
            c[j] = 1
            var peak: Float = 0
            var i = 0
            while i < 4_000 {
                let d = ParticleSphereLayout.fibonacci(i, 4_000, offset: 0.3)
                peak = max(peak, abs(ParticleSphereDynamics.evaluate(c, d)))
                i += 1
            }
            XCTAssertEqual(peak, 1, accuracy: 0.08, "基底 \(j)")
            j += 1
        }
    }

    // MARK: - 音訊對應

    private func frame(values: [Float] = [Float](repeating: 0, count: 64), bass: Float = 0, mid: Float = 0,
                       treble: Float = 0, level: Float = 0.5, energy: Float = 0.4, onset: Bool = false,
                       envelope: Float = 0, activity: Float = 1) -> SpectrumFrame {
        var f = AudioFeatures()
        f.bass = bass
        f.mid = mid
        f.treble = treble
        f.level = activity > 0 ? level : 0
        f.energy = activity > 0 ? energy : 0
        f.onset = onset
        f.onsetEnvelope = envelope
        f.activity = activity
        return SpectrumFrame(values: values, peaks: values, bass: bass, features: f)
    }

    private func run(_ d: inout ParticleSphereDynamics, _ f: SpectrumFrame, seconds: Double) {
        var t = 0.0
        while t < seconds {
            d.update(frame: f, dt: dt)
            t += dt
        }
    }

    /// 只有頻率位置 lo...hi（0...1）有能量的 64 頻段。
    private func band(_ lo: Float, _ hi: Float, level: Float = 0.8) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        var i = 0
        while i < 64 {
            let p = (Float(i) + 0.5) / 64
            if p >= lo && p <= hi { v[i] = level }
            i += 1
        }
        return v
    }

    func testBassExpandsTheWholeSphere() {
        var loud = ParticleSphereDynamics()
        run(&loud, frame(bass: 0.9), seconds: 0.5)
        var quiet = ParticleSphereDynamics()
        run(&quiet, frame(bass: 0), seconds: 0.5)
        XCTAssertGreaterThan(loud.expansion, 0.1, "低頻讓整顆球膨脹")
        XCTAssertGreaterThan(loud.expansion, quiet.expansion + 0.08)
    }

    func testFrequencyRegionsDriveDifferentHarmonicOrders() {
        var mids = ParticleSphereDynamics()
        run(&mids, frame(values: band(0.22, 0.47)), seconds: 0.4)
        var highs = ParticleSphereDynamics()
        run(&highs, frame(values: band(0.72, 1.0)), seconds: 0.4)
        func magnitude(_ d: ParticleSphereDynamics, _ range: Range<Int>) -> Float {
            var s: Float = 0
            var j = range.lowerBound
            while j < range.upperBound { s += abs(d.coefficients[j]); j += 1 }
            return s
        }
        // 中低頻 → l = 2（大區塊）；中高頻 → l = 4（細紋）
        XCTAssertGreaterThan(magnitude(mids, 3..<8), 0.05)
        XCTAssertLessThan(magnitude(mids, 15..<24), 1e-6)
        XCTAssertGreaterThan(magnitude(highs, 15..<24), 0.05)
        XCTAssertLessThan(magnitude(highs, 3..<8), 1e-6)
    }

    func testDeformationStaysSubtle() {
        // 全頻段都很大聲時，球諧變形仍在半徑的 ±35% 以內（不會變成刺球）
        var d = ParticleSphereDynamics()
        run(&d, frame(values: [Float](repeating: 1, count: 64), bass: 1, treble: 1), seconds: 1)
        var peak: Float = 0
        var i = 0
        while i < 2_000 {
            peak = max(peak, abs(ParticleSphereDynamics.evaluate(d.coefficients, ParticleSphereLayout.fibonacci(i, 2_000, offset: 0))))
            i += 1
        }
        XCTAssertGreaterThan(peak, 0.01)
        XCTAssertLessThan(peak, 0.35)
    }

    func testTrebleDrivesFineVibration() {
        var bright = ParticleSphereDynamics()
        run(&bright, frame(treble: 0.9), seconds: 0.5)
        var dull = ParticleSphereDynamics()
        run(&dull, frame(treble: 0), seconds: 0.5)
        XCTAssertGreaterThan(bright.trebleAmplitude, 0.015)
        XCTAssertEqual(dull.trebleAmplitude, 0)
        XCTAssertGreaterThan(bright.treblePhase, dull.treblePhase, "高頻越多，細振動相位前進越快")
    }

    func testOnsetSendsAPulseThatFinishesBeforeRest() {
        var d = ParticleSphereDynamics()
        run(&d, frame(values: band(0.3, 0.4)), seconds: 0.3)
        d.update(frame: frame(values: band(0.3, 0.4), onset: true, envelope: 0.9), dt: dt)
        XCTAssertTrue(d.hasLivePulse)
        XCTAssertEqual(simd_length(d.pulses.first { $0.alive }?.origin ?? .zero), 1, accuracy: 1e-3, "起點是單位方向")
        XCTAssertFalse(d.isSettled)
        let before = d.pulses.first { $0.alive }?.front ?? 0
        d.update(frame: frame(values: band(0.3, 0.4)), dt: dt)
        XCTAssertGreaterThan(d.pulses.first { $0.alive }?.front ?? 0, before, "波前往外移動")
        run(&d, frame(activity: 0), seconds: Double(ParticleSphereDynamics.pulseLife) + 0.1)
        XCTAssertFalse(d.hasLivePulse)
    }

    func testDemoChorusHasMoreTrebleAndPulsesThanVerse() {
        let audio = DemoAudio(seed: 3)
        var d = ParticleSphereDynamics()
        var verseTreble: Float = 0, chorusTreble: Float = 0
        var versePulses = 0, chorusPulses = 0
        while audio.seconds < 16 {
            let f = audio.next(dt: dt)
            let serial = d.pulseSerial
            d.update(frame: f, dt: dt)
            let inChorus = audio.seconds > 8.5
            if audio.seconds > 1 {
                if inChorus { chorusTreble += d.trebleAmplitude } else { verseTreble += d.trebleAmplitude }
                if d.pulseSerial != serial { if inChorus { chorusPulses += 1 } else { versePulses += 1 } }
            }
        }
        XCTAssertGreaterThan(chorusTreble, verseTreble * 1.2, "副歌有 hi-hat，表面細振動更多")
        XCTAssertGreaterThan(versePulses + chorusPulses, 6, "鼓點會產生起音脈衝")
    }

    func testMalformedValuesStayFinite() {
        var d = ParticleSphereDynamics()
        let bad = SpectrumFrame(values: [Float](repeating: .nan, count: 64), peaks: [], bass: .nan,
                                features: frame(bass: .infinity, treble: .nan).features)
        run(&d, bad, seconds: 0.2)
        d.update(frame: SpectrumFrame(values: [], peaks: [], bass: 0), dt: dt)
        d.update(frame: frame(values: [1]), dt: dt)
        XCTAssertTrue(d.coefficients.allSatisfy(\.isFinite))
        XCTAssertTrue(d.expansion.isFinite && d.trebleAmplitude.isFinite && d.spin.isFinite)
    }

    // MARK: - 靜音

    func testSilenceFreezesAndSettlesAllState() {
        let audio = DemoAudio(seed: 11)
        var d = ParticleSphereDynamics()
        audio.program = .music
        while audio.seconds < 3 { d.update(frame: audio.next(dt: dt), dt: dt) }
        XCTAssertFalse(d.isSettled)
        audio.program = .silence
        while audio.seconds < 6.5 { d.update(frame: audio.next(dt: dt), dt: dt) }
        XCTAssertTrue(d.isSettled, "靜音 3.5 秒內所有狀態收斂")
        XCTAssertTrue(d.coefficients.allSatisfy { $0 == 0 })
        XCTAssertEqual(d.expansion, 0)
        XCTAssertEqual(d.trebleAmplitude, 0)
        XCTAssertEqual(d.coreGlow, 0)
        XCTAssertFalse(d.hasLivePulse)
        let spin = d.spin, field = d.fieldSpin, phase = d.treblePhase
        while audio.seconds < 8 { d.update(frame: audio.next(dt: dt), dt: dt) }
        XCTAssertEqual(d.spin, spin, "靜音時不自轉")
        XCTAssertEqual(d.fieldSpin, field)
        XCTAssertEqual(d.treblePhase, phase, "靜音時細振動相位不前進")
        XCTAssertTrue(d.isSettled)
    }

    func testThemeKeepsGeometryWhenOnlyStyleChanges() {
        let theme = ParticleSphereTheme()
        theme.apply(SceneSettings(style: .aurora, quality: .medium))
        let first = theme.mesh?.geometry
        theme.apply(SceneSettings(style: .porcelain, quality: .medium))
        XCTAssertTrue(first === theme.mesh?.geometry, "換風格只換顏色，不重建幾何")
        XCTAssertNotEqual(theme.palette?.glow, ParticleSpherePalette.make(style: .aurora, look: SceneMaterials.look(style: .aurora, palette: .aurora)).glow)
        theme.apply(SceneSettings(style: .porcelain, quality: .high))
        XCTAssertFalse(first === theme.mesh?.geometry, "換畫質重建粒子配置")
        XCTAssertTrue(theme.isAtRest, "還沒有聲音時是靜止的")
    }

    func testEveryStyleHasDarkBodiesForLightDesktops() {
        for style in SculptureStyle.allCases {
            let colors = ParticleSpherePalette.make(style: style, look: SceneMaterials.look(style: style, palette: .aurora))
            XCTAssertEqual(colors.glow.count, 3)
            XCTAssertEqual(colors.body.count, 3)
            for body in colors.body {
                XCTAssertLessThanOrEqual(ParticleSpherePalette.luminance(body), 100, "\(style) 的本體色要夠深，淺色桌布上才看得到")
            }
            XCTAssertGreaterThan(colors.bodyOpacity, 0.6, "\(style)")
        }
    }
}
