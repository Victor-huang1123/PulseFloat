import PulseFloatCore
import SceneKit

/// 黑洞主題的幾何配置（依畫質與呈現方式）。
struct BlackHoleLayout: Equatable {
    /// 黑色陰影（事件視界）半徑。
    var shadow: Float = 0.30
    /// 吸積盤內、外半徑。
    var inner: Float = 0.46
    var outer: Float = 1.55
    /// 透鏡的愛因斯坦半徑（黑洞距離處的世界單位）與深度衰減距離。
    var einstein: Float = 0.33
    var lensFalloff: Float = 0.16
    var diskRadial = 34
    var diskAngular = 256
    var octaves = 3
    var streamCount = 4
    var perStream = 320
    var dustCount = 600
    /// 每幾顆粒子流粒子挑一顆當高頻火花。
    var sparkEvery = 6
    var rings: [BlackHoleRing] = []
    var ringSegments = 220
    var ringWidth: Float = 0.0065

    static func make(quality: RenderQuality, presentation: ScenePresentation) -> BlackHoleLayout {
        var layout = BlackHoleLayout()
        let sculpture = presentation == .sculpture
        switch quality {
        case .low:
            layout.diskRadial = sculpture ? 28 : 22
            layout.diskAngular = sculpture ? 200 : 160
            layout.octaves = 2
            layout.streamCount = sculpture ? 4 : 2
            layout.perStream = sculpture ? 420 : 300
            layout.dustCount = sculpture ? 500 : 260
            layout.ringSegments = 160
        case .medium:
            layout.diskRadial = sculpture ? 40 : 34
            layout.diskAngular = sculpture ? 300 : 256
            layout.octaves = 3
            layout.streamCount = sculpture ? 6 : 3
            layout.perStream = sculpture ? 700 : 480
            layout.dustCount = sculpture ? 1300 : 600
            layout.ringSegments = 220
        case .high:
            layout.diskRadial = sculpture ? 56 : 48
            layout.diskAngular = sculpture ? 420 : 360
            layout.octaves = 4
            layout.streamCount = sculpture ? 7 : 3
            layout.perStream = sculpture ? 1000 : 640
            layout.dustCount = sculpture ? 2200 : 1000
            layout.ringSegments = 300
        }
        var rings = [BlackHoleRing(radius: 1.64, inclination: 0, node: 0),
                     BlackHoleRing(radius: 1.06, inclination: 0.24, node: 0.5)]
        if quality != .low || sculpture { rings.append(BlackHoleRing(radius: 1.32, inclination: -0.15, node: 2.1)) }
        if sculpture && quality != .low { rings.append(BlackHoleRing(radius: 1.86, inclination: 0.05, node: 4.0)) }
        layout.rings = rings
        return layout
    }

    /// 粒子總數（粒子流 + 細塵 + 火花）。
    var particleCount: Int {
        let streamParticles = streamCount * perStream
        return streamParticles + dustCount + streamParticles / max(1, sparkEvery)
    }
}

/// 黑洞：黑色事件視界、差速旋轉的吸積盤（遠側經透鏡近似彎過陰影上下）、光子環、
/// 克卜勒軌道上的粒子流、會隨中頻變形的同心細環。
///
/// 所有動作只來自音訊：相位以 `dt × activity` 前進、起音脈衝以 dt 老化，靜音後幾秒內完全固定並回報 `isAtRest`。
/// CPU 每幀只更新兩個 4×4 uniform（所有材質共用同一個 NSValue）、黑洞縮放與傾斜；幾何、軌道與透鏡都在 shader 計算。
@MainActor
final class BlackHoleTheme: SceneTheme {
    let stage = SceneStage()

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    private(set) var isAtRest = true

    /// 整個黑洞系統（立體聲平衡讓它微微傾斜）。
    private let system = SCNNode()
    private let horizon = SCNNode()
    // 細環與粒子分成盤後（先畫，被半透明盤面蓋住）與盤前（最後畫）兩個圖層。
    private let ringsBehind = BlackHoleLayer(geometry: BlackHoleShaders.ringGeometry, fragment: BlackHoleShaders.ringFragment, order: 2)
    private let dustBehind = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 3)
    private let streamsBehind = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 4)
    private let sparksBehind = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 5)
    private let disk = BlackHoleLayer(geometry: BlackHoleShaders.diskGeometry, fragment: BlackHoleShaders.diskFragment, order: 6, writesDepth: true)
    private let secondary = BlackHoleLayer(geometry: BlackHoleShaders.diskGeometry, fragment: BlackHoleShaders.diskFragment, order: 7)
    private let photon = BlackHoleLayer(geometry: BlackHoleShaders.photonGeometry, fragment: BlackHoleShaders.photonFragment, order: 8)
    private let ringsFront = BlackHoleLayer(geometry: BlackHoleShaders.ringGeometry, fragment: BlackHoleShaders.ringFragment, order: 9)
    private let dustFront = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 10)
    private let streamsFront = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 11)
    private let sparksFront = BlackHoleLayer(geometry: BlackHoleShaders.particleGeometry, fragment: BlackHoleShaders.particleFragment, order: 12)
    private let layers: [BlackHoleLayer]
    private let shaderMaterials: [SCNMaterial]

    private(set) var state = BlackHoleAudioState()
    private(set) var layout = BlackHoleLayout()
    private var builtLayout: BlackHoleLayout?
    private var lastDynamic: (SCNMatrix4, SCNMatrix4)?
    /// 盤面節點的偏航角（弧度）。
    private var diskYaw: Float = 0

    init() {
        layers = [ringsBehind, dustBehind, streamsBehind, sparksBehind, disk, secondary, photon,
                  ringsFront, dustFront, streamsFront, sparksFront]
        shaderMaterials = layers.map(\.material)
        stage.content.addChildNode(system)

        let sphere = SCNSphere(radius: 0.30)
        sphere.segmentCount = 96
        let black = SCNMaterial()
        black.lightingModel = .constant
        black.diffuse.contents = CGColor(gray: 0, alpha: 1)
        black.writesToDepthBuffer = true
        sphere.firstMaterial = black
        horizon.geometry = sphere
        horizon.renderingOrder = 0
        system.addChildNode(horizon)
        for layer in layers { system.addChildNode(layer.node) }
    }

    /// 目前畫面使用的粒子數（測試用）。
    var particleCount: Int { builtLayout?.particleCount ?? 0 }
    /// 黑色核心目前的縮放（測試用）。
    var horizonScale: Float { Float(horizon.scale.x) }

    func apply(_ settings: SceneSettings) {
        stage.apply(settings,
                    compact: CameraPose(target: SIMD3(0, 0.05, 0), distance: 4.4, elevation: 10, azimuth: 0, fov: 18),
                    sculpture: CameraPose(target: SIMD3(0, -0.04, 0), distance: 4.4, elevation: 21, azimuth: 0, fov: 22),
                    floorY: -0.78, pedestalRadius: nil, orbitSpeed: 3, shadows: false)
        let next = BlackHoleLayout.make(quality: settings.quality, presentation: settings.presentation)
        layout = next
        if builtLayout != next {
            build(next)
            builtLayout = next
        }
        applyLook(BlackHolePalette.make(style: settings.style, palette: settings.palette))

        // HIGH 才開 HDR bloom，而且很節制（bloom 是加法光，只在深色桌布上看得到）
        let camera = stage.camera
        let high = settings.quality == .high
        camera.wantsHDR = high
        camera.bloomIntensity = high ? 0.32 : 0
        camera.bloomThreshold = 0.92
        camera.bloomBlurRadius = 7
        // 自己發光的主體底下出現主光的陰影會很怪：雕塑模式維持漂浮、不投影（舞台的陰影地面因此是空的）
        horizon.castsShadow = false
        lastDynamic = nil
        pushDynamic()
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let features = frame.features
        state.advance(features: features, values: frame.values, dt: dt)
        stage.update(features: features)

        let scale = CGFloat(state.coreScale)
        horizon.scale = SCNVector3(scale, scale, scale)
        system.eulerAngles = SCNVector3(0, 0, CGFloat(-0.035 * state.balance))
        // 盤面轉向鏡頭的方位角：網格的近側半圈永遠在後面才畫（雕塑模式鏡頭會環繞）
        let eye = system.simdConvertPosition(stage.cameraNode.simdWorldPosition, from: nil)
        diskYaw = eye.x * eye.x + eye.z * eye.z > 1e-8 ? atan2f(eye.x, eye.z) : 0
        disk.node.simdEulerAngles = SIMD3(0, diskYaw, 0)
        secondary.node.simdEulerAngles = SIMD3(0, diskYaw, 0)
        pushDynamic()
        isAtRest = state.isSettled(silent: features.isSilent || !features.activity.isFinite)
    }

    // MARK: - 建構

    private func build(_ layout: BlackHoleLayout) {
        let diskMesh = BlackHoleMeshes.disk(radial: layout.diskRadial, angular: layout.diskAngular,
                                            inner: layout.inner, outer: layout.outer)
        disk.setGeometry(diskMesh)
        secondary.setGeometry(diskMesh)
        photon.setGeometry(BlackHoleMeshes.screenRing(segments: 256))

        let ribbon = BlackHoleMeshes.ribbons(layout.rings, segments: layout.ringSegments, extent: 2.4)
        ringsBehind.setGeometry(ribbon)
        ringsFront.setGeometry(ribbon)

        let orbits = BlackHoleMeshes.streams(count: layout.streamCount, inner: layout.inner, seed: 0xB1AC_401E)
        let streamParticles = BlackHoleMeshes.streamParticles(orbits, perStream: layout.perStream, seed: 0x5EED_0001)
        let streamMesh = BlackHoleMeshes.quads(streamParticles, extent: 2.4)
        streamsBehind.setGeometry(streamMesh)
        streamsFront.setGeometry(streamMesh)

        let dustMesh = BlackHoleMeshes.quads(BlackHoleMeshes.dustParticles(count: layout.dustCount, inner: layout.inner,
                                                                           outer: layout.outer, seed: 0x5EED_0002), extent: 2.4)
        dustBehind.setGeometry(dustMesh)
        dustFront.setGeometry(dustMesh)

        let sparkMesh = BlackHoleMeshes.quads(BlackHoleMeshes.sparks(from: streamParticles, every: layout.sparkEvery), extent: 2.4)
        sparksBehind.setGeometry(sparkMesh)
        sparksFront.setGeometry(sparkMesh)
    }

    private func applyLook(_ palette: BlackHolePalette) {
        let shape = SCNVector4(CGFloat(layout.inner), CGFloat(layout.outer), CGFloat(layout.shadow), CGFloat(layout.einstein))
        let style = SCNVector4(CGFloat(palette.emission), CGFloat(palette.opacity), CGFloat(palette.dustStrength), 0.42)
        let octaves = CGFloat(layout.octaves)
        let falloff = CGFloat(layout.lensFalloff)
        let hot = Self.color(palette.hot, palette.whiteHot), mid = Self.color(palette.mid)
        let cool = Self.color(palette.cool), dust = Self.color(palette.dust)
        for layer in layers {
            layer.set("u_shape", NSValue(scnVector4: shape))
            layer.set("u_style", NSValue(scnVector4: style))
            layer.set("u_hot", NSValue(scnVector4: hot))
            layer.set("u_mid", NSValue(scnVector4: mid))
            layer.set("u_cool", NSValue(scnVector4: cool))
            layer.set("u_dust", NSValue(scnVector4: dust))
        }
        // 各圖層的模式參數（意義見 BlackHoleShaders 各段的說明）
        disk.set("u_mode", NSValue(scnVector4: SCNVector4(0, 0.6, falloff, octaves)))
        secondary.set("u_mode", NSValue(scnVector4: SCNVector4(2, 0, falloff, octaves)))
        photon.set("u_mode", NSValue(scnVector4: SCNVector4(0, 1.045, 0.016, 1.15)))
        let width = CGFloat(layout.ringWidth)
        ringsBehind.set("u_mode", NSValue(scnVector4: SCNVector4(0, falloff, width, 1)))
        ringsFront.set("u_mode", NSValue(scnVector4: SCNVector4(1, falloff, width, 1)))
        for layer in [ringsBehind, ringsFront] { layer.set("u_mid", NSValue(scnVector4: Self.color(palette.ring))) }
        for (layer, spark, front) in [(dustBehind, 0, 0), (streamsBehind, 0, 0), (sparksBehind, 1, 0),
                                      (dustFront, 0, 1), (streamsFront, 0, 1), (sparksFront, 1, 1)] {
            layer.set("u_mode", NSValue(scnVector4: SCNVector4(CGFloat(spark), falloff, CGFloat(front), 0)))
            layer.set("u_mid", NSValue(scnVector4: Self.color(palette.stream)))
            layer.set("u_cool", NSValue(scnVector4: Self.color(palette.streamAlt)))
            layer.set("u_hot", NSValue(scnVector4: Self.color(palette.spark, palette.whiteHot)))
            layer.set("u_dust", NSValue(scnVector4: mid))
        }
    }

    private static func color(_ c: RGB, _ extra: Float = 0) -> SCNVector4 {
        let v = SceneMaterials.linear(c)
        return SCNVector4(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z), CGFloat(extra))
    }

    // MARK: - 每幀參數

    /// 把音訊狀態打包成兩個 4×4 uniform；沒有變化就不設定（靜止時 CPU 幾乎不做事）。
    private func pushDynamic() {
        let s = state
        let p0 = s.pulse(0, inner: layout.inner, outer: layout.outer)
        let p1 = s.pulse(1, inner: layout.inner, outer: layout.outer)
        let p2 = s.pulse(2, inner: layout.inner, outer: layout.outer)
        let p3 = s.pulse(3, inner: layout.inner, outer: layout.outer)
        let m0 = SCNMatrix4(m11: CGFloat(s.flowPhase), m12: CGFloat(s.spiralPhase), m13: CGFloat(s.orbitPhase), m14: CGFloat(s.midPhase),
                            m21: CGFloat(s.thickness), m22: CGFloat(s.gain), m23: CGFloat(s.trebleGlow), m24: CGFloat(s.spark),
                            m31: CGFloat(s.mid), m32: CGFloat(s.core), m33: CGFloat(s.balance), m34: CGFloat(s.width),
                            m41: CGFloat(p0.radius), m42: CGFloat(p1.radius), m43: CGFloat(p2.radius), m44: CGFloat(p3.radius))
        let m1 = SCNMatrix4(m11: CGFloat(p0.amplitude), m12: CGFloat(p1.amplitude), m13: CGFloat(p2.amplitude), m14: CGFloat(p3.amplitude),
                            m21: CGFloat(s.harmonics.x), m22: CGFloat(s.harmonics.y), m23: CGFloat(s.harmonics.z), m24: CGFloat(s.sparkSeed),
                            m31: CGFloat(s.coreScale), m32: CGFloat(s.thickness), m33: CGFloat(s.loudness), m34: CGFloat(s.orbitRate),
                            m41: CGFloat(diskYaw), m42: 0, m43: 0, m44: 0)
        if let last = lastDynamic, SCNMatrix4EqualToMatrix4(last.0, m0), SCNMatrix4EqualToMatrix4(last.1, m1) { return }
        lastDynamic = (m0, m1)
        let v0 = NSValue(scnMatrix4: m0), v1 = NSValue(scnMatrix4: m1)
        var i = 0
        while i < shaderMaterials.count {
            shaderMaterials[i].setValue(v0, forKey: "u_dyn0")
            shaderMaterials[i].setValue(v1, forKey: "u_dyn1")
            i += 1
        }
    }
}
