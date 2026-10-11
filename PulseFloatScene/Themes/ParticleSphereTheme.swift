import PulseFloatCore
import SceneKit
import simd

/// 粒子球：數千顆粒子組成的分層能量球（核心光團、內殼、雙主殼、星座節點與連線、外圍光暈）。
/// 粒子位置完全決定性（費氏晶格＋雜湊抖動）；所有動作都在頂點著色器裡由音訊驅動：
/// 低頻 → 整體膨脹，中頻 → l ≤ 4 球諧的平滑局部變形（頻率區段對應球面不同區域），
/// 高頻 → 表面細振動，起音 → 由核心往外、沿球面擴散的波前。靜音時所有狀態收斂後畫面逐像素靜止。
@MainActor
final class ParticleSphereTheme: SceneTheme {
    let stage = SceneStage()
    private let cloud = SCNNode()
    private let material = SCNMaterial()
    private let floor = ParticleSphereFloor()
    private static let floorY: Float = -1.62
    private(set) var dynamics = ParticleSphereDynamics()
    private(set) var recipe: ParticleSphereRecipe?
    private(set) var mesh: ParticleSphereMesh?
    private(set) var palette: ParticleSpherePalette?
    private var atRest = true
    /// 指向主光的方向（世界座標）與畫面參數（連線強度等），隨設定更新、每幀跟著動態 uniform 一起送出。
    private var keyDirection = SIMD4<Float>(0, 0.7, 0.7, 0)
    private var viewParams = SIMD4<Float>(1, 1, 1, 0)

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    var isAtRest: Bool { atRest }

    init() {
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.transparencyMode = .singleLayer
        material.transparency = 0.999   // 進入透明繪製階段（才會開混合）；著色器輸出 premultiplied 顏色
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: ParticleSphereShader.geometry, .fragment: ParticleSphereShader.fragment]
        cloud.castsShadow = false
        cloud.renderingOrder = 10
        stage.content.addChildNode(cloud)
        stage.content.addChildNode(floor.node)
        pushDynamics()
    }

    func apply(_ settings: SceneSettings) {
        // 精簡：球置中、光暈剛好碰到上下緣；雕塑：略俯視、球往上移，下方留出地面光池
        let compact = CameraPose(target: .zero, distance: 6.4, elevation: 6, azimuth: 0, fov: 28)
        let sculpture = CameraPose(target: SIMD3(0, -0.36, 0), distance: 6.8, elevation: 13, azimuth: -8, fov: 30)
        stage.apply(settings, compact: compact, sculpture: sculpture, floorY: Self.floorY, pedestalRadius: nil, orbitSpeed: 3)
        // 粒子不投射陰影（發光體），地面的接觸陰影由自己的光池負責：關掉陰影貼圖與只收陰影的地面，省一個繪製階段
        stage.keyLight.light?.castsShadow = false
        stage.shadowFloor.isHidden = true

        let next = ParticleSphereRecipe.make(quality: settings.quality, presentation: settings.presentation)
        if next != recipe {
            recipe = next
            let built = ParticleSphereLayout.build(next)
            built.geometry.materials = [material]
            cloud.geometry = built.geometry
            mesh = built
        }

        let colors = ParticleSpherePalette.make(style: settings.style, look: stage.look)
        palette = colors
        // 著色器輸出直接寫進 BGRA8（沒有 gamma 轉換），所以顏色用 sRGB 0...1
        func srgb(_ c: RGB, _ w: Float = 0) -> SIMD4<Float> { SIMD4(Float(c.red) / 255, Float(c.green) / 255, Float(c.blue) / 255, w) }
        set("u_glow", srgb(colors.glow[0]), srgb(colors.glow[1]), srgb(colors.glow[2]), srgb(colors.hot, colors.hotMix))
        set("u_body", srgb(colors.body[0]), srgb(colors.body[1]), srgb(colors.body[2]),
            SIMD4(colors.bodyOpacity, colors.glowGain, colors.haloOpacity, 0))
        keyDirection = SIMD4(simd_normalize(-stage.keyLight.simdWorldFront), 0)
        viewParams = SIMD4(1, settings.presentation == .compact ? 0.7 : 1, 1, 0)
        let shadow = SculptureStyleColors.mix(colors.body[1], RGB(red: 6, green: 7, blue: 12), 0.55)
        floor.apply(visible: settings.presentation == .sculpture, floorY: Self.floorY, glow: colors.glow[1],
                    shade: shadow, shadeOpacity: stage.look.isLight ? 0.46 : 0.4)

        // bloom 只在 HIGH，而且很淡（bloom 是 alpha 0 的加法光，淺色桌布上本來就看不到）
        let camera = stage.camera
        if settings.quality == .high {
            camera.wantsHDR = true
            camera.bloomIntensity = 0.18
            camera.bloomThreshold = 0.9
            camera.bloomBlurRadius = 5
        } else {
            camera.wantsHDR = false
            camera.bloomIntensity = 0
        }
        pushDynamics()
        floor.update(intensity: floorIntensity)
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let wasSettled = dynamics.isSettled
        dynamics.update(frame: frame, dt: dt)
        // 已經靜止而且這一幀仍然靜止：uniform 都沒變，不必重設
        if !(wasSettled && dynamics.isSettled) { pushDynamics() }
        floor.update(intensity: floorIntensity)
        atRest = dynamics.isSettled
        stage.update(features: frame.features)
    }

    /// 地面光池亮度：球的核心亮度與膨脹照亮地面（靜音時是固定的 0.03）。
    private var floorIntensity: Float { 0.03 + 0.12 * dynamics.coreGlow + 0.35 * dynamics.expansion }

    /// 把音訊狀態寫進 shader uniform（4 個 float4x4；每行 = SCNMatrix4 的一列）。
    private func pushDynamics() {
        let c = dynamics.coefficients
        set("u_sh0", SIMD4(c[0], c[1], c[2], c[3]), SIMD4(c[4], c[5], c[6], c[7]),
            SIMD4(c[8], c[9], c[10], c[11]), SIMD4(c[12], c[13], c[14], c[15]))
        var amps = SIMD4<Float>(repeating: 0)
        var i = 0
        while i < ParticleSphereDynamics.pulseCapacity {
            amps[i] = dynamics.pulses[i].amplitude
            i += 1
        }
        set("u_sh1", SIMD4(c[16], c[17], c[18], c[19]), SIMD4(c[20], c[21], c[22], c[23]),
            SIMD4(dynamics.expansion, dynamics.trebleAmplitude, dynamics.treblePhase, dynamics.coreGlow), amps)
        // 晶格自轉：傳 Lᵀ 的三行（= L 的三列），著色器算 p = L · base（L = latticeRotation；方向不影響畫面）
        let lattice = ParticleSphereDynamics.latticeRotation(dynamics.spin).transpose
        set("u_lat", SIMD4(lattice.columns.0, 0), SIMD4(lattice.columns.1, 0), SIMD4(lattice.columns.2, 0), keyDirection)
        // 世界 → 變形場座標（f = R · d）
        let field = ParticleSphereDynamics.fieldRotation(dynamics.fieldSpin).transpose
        set("u_fld", SIMD4(field.columns.0, 0), SIMD4(field.columns.1, 0), SIMD4(field.columns.2, 0), viewParams)
        let p = dynamics.pulses
        set("u_pulse", pulseVector(p[0]), pulseVector(p[1]), pulseVector(p[2]), pulseVector(p[3]))
    }

    private func pulseVector(_ pulse: ParticleSphereDynamics.Pulse) -> SIMD4<Float> {
        SIMD4(pulse.origin, pulse.alive ? pulse.front : -10)
    }

    private func set(_ key: String, _ r0: SIMD4<Float>, _ r1: SIMD4<Float>, _ r2: SIMD4<Float>, _ r3: SIMD4<Float>) {
        func g(_ v: Float) -> CGFloat { CGFloat(v) }
        let m = SCNMatrix4(m11: g(r0.x), m12: g(r0.y), m13: g(r0.z), m14: g(r0.w),
                           m21: g(r1.x), m22: g(r1.y), m23: g(r1.z), m24: g(r1.w),
                           m31: g(r2.x), m32: g(r2.y), m33: g(r2.z), m34: g(r2.w),
                           m41: g(r3.x), m42: g(r3.y), m43: g(r3.z), m44: g(r3.w))
        material.setValue(NSValue(scnMatrix4: m), forKey: key)
    }
}
