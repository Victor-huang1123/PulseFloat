import PulseFloatCore
import SceneKit

/// 音訊地形（暫時的佔位實作：隨音訊時鐘起伏的網格）。正式版本由主題分支取代。
@MainActor
final class TerrainTheme: SceneTheme {
    let stage = SceneStage()
    private let ground = SCNNode()
    private var silent = true

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    var isAtRest: Bool { silent }

    init() {
        stage.content.addChildNode(ground)
    }

    func apply(_ settings: SceneSettings) {
        stage.apply(settings, compact: CameraPose(target: SIMD3(0, -0.1, 0), distance: 2.4, elevation: 22, fov: 34),
                    sculpture: CameraPose(target: SIMD3(0, -0.2, 0), distance: 3.2, elevation: 28, fov: 32),
                    floorY: -0.35, pedestalRadius: nil)
        let plane = SCNPlane(width: 3.2, height: 1.6)
        let segments = settings.quality == .low ? 48 : (settings.quality == .medium ? 96 : 160)
        plane.widthSegmentCount = segments
        plane.heightSegmentCount = segments / 2
        let material = SceneMaterials.pbr(base: stage.look.baseColor(at: 0.5), metalness: stage.look.metalness, roughness: stage.look.roughness)
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: """
            uniform float u_level;
            uniform float u_phase;
            float h = sin(_geometry.position.x * 4.0 + u_phase) * cos(_geometry.position.y * 6.0 - u_phase * 0.7);
            _geometry.position.z += h * (0.04 + 0.22 * u_level);
            """]
        material.setValue(NSNumber(value: 0), forKey: "u_level")
        material.setValue(NSNumber(value: 0), forKey: "u_phase")
        plane.firstMaterial = material
        ground.geometry = plane
        ground.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        ground.position = SCNVector3(0, -0.3, 0)
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let f = frame.features
        silent = f.isSilent
        ground.geometry?.firstMaterial?.setValue(NSNumber(value: f.energy), forKey: "u_level")
        ground.geometry?.firstMaterial?.setValue(NSNumber(value: f.time.truncatingRemainder(dividingBy: 1000)), forKey: "u_phase")
        stage.update(features: f)
    }
}
