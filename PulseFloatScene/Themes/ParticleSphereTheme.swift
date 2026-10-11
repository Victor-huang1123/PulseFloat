import PulseFloatCore
import SceneKit

/// 粒子球（暫時的佔位實作：費氏球面上的點，隨能量放大）。正式版本由主題分支取代。
@MainActor
final class ParticleSphereTheme: SceneTheme {
    let stage = SceneStage()
    private let cloud = SCNNode()
    private var silent = true

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    var isAtRest: Bool { silent }

    init() {
        stage.content.addChildNode(cloud)
    }

    func apply(_ settings: SceneSettings) {
        stage.apply(settings, compact: CameraPose(distance: 3.0, elevation: 8, fov: 30),
                    sculpture: CameraPose(distance: 3.6, elevation: 16, fov: 30), pedestalRadius: 0.9)
        let count = settings.quality == .low ? 2_000 : (settings.quality == .medium ? 6_000 : 12_000)
        var points: [SCNVector3] = []
        points.reserveCapacity(count)
        let golden = Double.pi * (3 - 5.0.squareRoot())
        var i = 0
        while i < count {
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot()
            let a = golden * Double(i)
            points.append(SCNVector3(CGFloat(cos(a) * r * 0.8), CGFloat(y * 0.8), CGFloat(sin(a) * r * 0.8)))
            i += 1
        }
        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: Array(0..<Int32(count)), primitiveType: .point)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = SceneMaterials.unlit(stage.look.glowColor(at: 0.5))
        cloud.geometry = geometry
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let f = frame.features
        silent = f.isSilent
        let s = 1 + 0.2 * CGFloat(f.energy)
        cloud.scale = SCNVector3(s, s, s)
        cloud.eulerAngles.y = CGFloat(f.time.truncatingRemainder(dividingBy: 2 * .pi * 100) * 0.3)
        stage.update(features: f)
    }
}
