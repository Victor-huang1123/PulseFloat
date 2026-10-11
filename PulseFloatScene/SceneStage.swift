import PulseFloatCore
import SceneKit

/// 鏡頭姿勢：看向 target，距離 distance，仰角／方位角（度），垂直視角 fov（度）。
public struct CameraPose: Equatable, Sendable {
    public var target: SIMD3<Float>
    public var distance: Float
    public var elevation: Float
    public var azimuth: Float
    public var fov: Float

    public init(target: SIMD3<Float> = .zero, distance: Float = 4, elevation: Float = 12, azimuth: Float = 0, fov: Float = 32) {
        self.target = target
        self.distance = distance
        self.elevation = elevation
        self.azimuth = azimuth
        self.fov = fov
    }
}

/// 三個主題共用的舞台：相機、三點燈光、攝影棚環境反射，以及雕塑模式的台座與透明陰影地面。
/// 主題把自己的節點加到 `content`。全部在主執行緒使用。
@MainActor
public final class SceneStage {
    public let scene = SCNScene()
    /// 主題節點的父節點（原點為中心）。
    public let content = SCNNode()
    public let cameraNode = SCNNode()
    public var camera: SCNCamera { cameraNode.camera ?? SCNCamera() }
    public let keyLight = SCNNode()
    public let fillLight = SCNNode()
    public let rimLight = SCNNode()
    /// 雕塑模式的台座（主題可以改材質或隱藏）。
    public let pedestal = SCNNode()
    /// 雕塑模式只接收陰影的透明地面。
    public let shadowFloor = SCNNode()

    public private(set) var settings = SceneSettings()
    public private(set) var look = SceneMaterials.look(style: .porcelain, palette: .aurora)
    private var compactPose = CameraPose()
    private var sculpturePose = CameraPose()
    private var orbitSpeed: Float = 0
    private var orbitAngle: Float = 0
    /// 使用者在雕塑模式拖曳／捲動造成的鏡頭偏移（度、倍率）。這是明確的使用者操作，靜音時也可以改變。
    public private(set) var userYaw: Float = 0
    public private(set) var userPitch: Float = 0
    public private(set) var userZoom: Float = 1

    public init() {
        scene.rootNode.addChildNode(content)
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 100
        camera.wantsExposureAdaptation = false   // 自動曝光會讓靜止的畫面繼續變化
        camera.motionBlurIntensity = 0
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        keyLight.light = Self.light(.directional, intensity: 900)
        keyLight.eulerAngles = SCNVector3(-0.9, 0.55, 0)
        fillLight.light = Self.light(.directional, intensity: 220)
        fillLight.eulerAngles = SCNVector3(-0.25, -1.9, 0)
        rimLight.light = Self.light(.directional, intensity: 520)
        rimLight.eulerAngles = SCNVector3(-0.35, 3.0, 0)
        scene.rootNode.addChildNode(keyLight)
        scene.rootNode.addChildNode(fillLight)
        scene.rootNode.addChildNode(rimLight)

        scene.lightingEnvironment.contents = SceneMaterials.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.1

        let slab = SCNCylinder(radius: 1.15, height: 0.08)
        slab.radialSegmentCount = 96
        pedestal.geometry = slab
        pedestal.position = SCNVector3(0, -1.04, 0)
        pedestal.isHidden = true
        scene.rootNode.addChildNode(pedestal)

        let floor = SCNPlane(width: 8, height: 8)
        let shadowMaterial = SCNMaterial()
        shadowMaterial.lightingModel = .shadowOnly
        shadowMaterial.writesToDepthBuffer = true
        floor.firstMaterial = shadowMaterial
        shadowFloor.geometry = floor
        shadowFloor.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        shadowFloor.position = SCNVector3(0, -1.0, 0)
        shadowFloor.castsShadow = false
        shadowFloor.isHidden = true
        scene.rootNode.addChildNode(shadowFloor)
    }

    private static func light(_ type: SCNLight.LightType, intensity: CGFloat) -> SCNLight {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = CGColor(gray: 1, alpha: 1)
        return light
    }

    /// 套用設定與這個主題在兩種呈現方式下的鏡頭。
    /// - Parameters:
    ///   - floorY: 雕塑模式地面（陰影）的高度；台座頂面也在這裡。
    ///   - pedestalRadius: 台座半徑；nil 表示不要台座（只留陰影）。
    ///   - orbitSpeed: 雕塑模式下鏡頭每「音訊秒」環繞的角度（度）；靜音時音訊時鐘停止，鏡頭也停。
    public func apply(_ settings: SceneSettings, compact: CameraPose, sculpture: CameraPose,
                      floorY: Float = -1, pedestalRadius: Float? = 1.15, orbitSpeed: Float = 4) {
        self.settings = settings
        look = SceneMaterials.look(style: settings.style, palette: settings.palette)
        compactPose = compact
        sculpturePose = sculpture
        self.orbitSpeed = orbitSpeed
        let isSculpture = settings.presentation == .sculpture

        shadowFloor.isHidden = !isSculpture
        shadowFloor.position = SCNVector3(0, CGFloat(floorY), 0)
        if let pedestalRadius, isSculpture {
            pedestal.isHidden = false
            if let slab = pedestal.geometry as? SCNCylinder { slab.radius = CGFloat(pedestalRadius) }
            pedestal.position = SCNVector3(0, CGFloat(floorY) - 0.04, 0)
            let tone = SculptureStyleColors.mix(look.baseColor(at: 0.5), RGB(red: 20, green: 20, blue: 24), look.isLight ? 0.18 : 0.55)
            pedestal.geometry?.firstMaterial = SceneMaterials.pbr(base: tone, metalness: look.metalness * 0.5, roughness: 0.55)
        } else {
            pedestal.isHidden = true
        }

        let shadows = isSculpture && settings.quality != .low
        keyLight.light?.castsShadow = shadows
        if shadows, let light = keyLight.light {
            light.shadowMode = .forward
            light.shadowMapSize = settings.quality == .high ? CGSize(width: 2048, height: 2048) : CGSize(width: 1024, height: 1024)
            light.shadowSampleCount = settings.quality == .high ? 16 : 8
            light.shadowRadius = 6
            light.shadowColor = CGColor(gray: 0, alpha: look.isLight ? 0.38 : 0.55)
            light.orthographicScale = 3
            light.automaticallyAdjustsShadowProjection = true
        }

        camera.fieldOfView = CGFloat((isSculpture ? sculpture : compact).fov)
        refreshCamera()
    }

    /// 雕塑模式：鏡頭以 `features.time` 緩慢環繞（純函數，沒有內部狀態，所以靜音時一定靜止）。精簡模式固定。
    public func update(features: AudioFeatures) {
        guard settings.presentation == .sculpture else { return }
        orbitAngle = Float(features.time.truncatingRemainder(dividingBy: 3600)) * orbitSpeed
        refreshCamera()
    }

    /// 設定使用者鏡頭偏移（只在雕塑模式生效）：yaw/pitch 為度，zoom 為距離倍率（0.6...1.8）。
    public func setUserCamera(yaw: Float, pitch: Float, zoom: Float) {
        userYaw = yaw.isFinite ? yaw.truncatingRemainder(dividingBy: 360) : 0
        userPitch = pitch.isFinite ? min(60, max(-30, pitch)) : 0
        userZoom = zoom.isFinite ? min(1.8, max(0.6, zoom)) : 1
        refreshCamera()
    }

    /// 依目前的呈現方式、音訊環繞角度與使用者偏移重新擺放相機。
    public func refreshCamera() {
        if settings.presentation == .sculpture {
            var pose = sculpturePose
            pose.azimuth += userYaw
            pose.elevation = min(80, max(-20, pose.elevation + userPitch))
            pose.distance *= userZoom
            place(pose, orbit: orbitAngle)
        } else {
            place(compactPose, orbit: 0)
        }
    }

    private func place(_ pose: CameraPose, orbit: Float) {
        let el = pose.elevation * .pi / 180
        let az = (pose.azimuth + orbit) * .pi / 180
        let offset = SIMD3<Float>(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * pose.distance
        let eye = pose.target + offset
        cameraNode.simdPosition = eye
        cameraNode.simdLook(at: pose.target, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
    }
}
