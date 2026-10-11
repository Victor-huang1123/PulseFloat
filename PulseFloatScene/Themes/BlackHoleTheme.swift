import PulseFloatCore
import SceneKit

/// 黑洞（暫時的佔位實作：黑色球＋發光圓盤）。正式版本由主題分支取代。
@MainActor
final class BlackHoleTheme: SceneTheme {
    let stage = SceneStage()
    private let horizon = SCNNode()
    private let disk = SCNNode()
    private var silent = true

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    var isAtRest: Bool { silent }

    init() {
        let sphere = SCNSphere(radius: 0.32)
        sphere.segmentCount = 64
        let black = SCNMaterial()
        black.lightingModel = .constant
        black.diffuse.contents = CGColor(gray: 0, alpha: 1)
        sphere.firstMaterial = black
        horizon.geometry = sphere
        stage.content.addChildNode(horizon)
        let ring = SCNTube(innerRadius: 0.42, outerRadius: 1.0, height: 0.01)
        ring.radialSegmentCount = 128
        disk.geometry = ring
        stage.content.addChildNode(disk)
    }

    func apply(_ settings: SceneSettings) {
        stage.apply(settings, compact: CameraPose(distance: 2.6, elevation: 12, fov: 30),
                    sculpture: CameraPose(distance: 3.4, elevation: 20, fov: 30), pedestalRadius: nil)
        disk.geometry?.firstMaterial = SceneMaterials.unlit(stage.look.glowColor(at: 0.3), alpha: 0.9)
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let f = frame.features
        silent = f.isSilent
        disk.eulerAngles.y = CGFloat(f.time.truncatingRemainder(dividingBy: 2 * .pi * 100) * 0.6)
        let s = 1 + 0.25 * CGFloat(f.bass)
        disk.scale = SCNVector3(s, 1, s)
        stage.update(features: f)
    }
}
