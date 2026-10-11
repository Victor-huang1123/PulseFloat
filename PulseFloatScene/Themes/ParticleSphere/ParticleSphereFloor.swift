import PulseFloatCore
import SceneKit

/// 雕塑模式：球下方地面的柔和光池與接觸陰影（一個水平平面＋徑向衰減的 shader）。
/// 深色桌布上看到的是球照亮地面的光，淺色桌布上看到的是讓球「落地」的淡陰影。亮度跟著核心亮度與膨脹。
@MainActor
final class ParticleSphereFloor {
    let node = SCNNode()
    private let material = SCNMaterial()
    private var lastIntensity: Float = -1

    private static let geometryModifier = """
    #pragma varyings
    float2 v_uv;
    #pragma body
    out.v_uv = _geometry.texcoords[0] * 2.0 - 1.0;
    """

    private static let fragmentModifier = """
    #pragma arguments
    float4 u_pool;
    float4 u_shade;
    #pragma varyings
    float2 v_uv;
    #pragma body
    float r2 = dot(in.v_uv, in.v_uv);
    float edge = clamp(1.0 - r2, 0.0, 1.0);
    float light = exp(-r2 * 4.0) * edge;
    float contact = exp(-r2 * 9.0) * edge;
    float a = u_shade.w * (0.55 * light + 0.45 * contact);
    _output.color = float4(u_shade.rgb * a + u_pool.rgb * (u_pool.w * light), a);
    """

    init() {
        let plane = SCNPlane(width: 3.0, height: 3.0)
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.transparencyMode = .singleLayer
        material.transparency = 0.999
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: Self.geometryModifier, .fragment: Self.fragmentModifier]
        plane.firstMaterial = material
        node.geometry = plane
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.castsShadow = false
        node.renderingOrder = 5
        node.isHidden = true
    }

    /// 套用呈現方式與顏色：只在雕塑模式顯示。
    func apply(visible: Bool, floorY: Float, glow: RGB, shade: RGB, shadeOpacity: Float) {
        node.isHidden = !visible
        node.position = SCNVector3(0, CGFloat(floorY + 0.002), 0)
        material.setValue(Self.vector(shade, shadeOpacity), forKey: "u_shade")
        poolColor = glow
        lastIntensity = -1
    }

    private var poolColor = RGB(red: 255, green: 255, blue: 255)

    /// 光池亮度（0...1）；值沒變就不重設。
    func update(intensity: Float) {
        guard !node.isHidden, intensity != lastIntensity else { return }
        lastIntensity = intensity
        material.setValue(Self.vector(poolColor, intensity), forKey: "u_pool")
    }

    private static func vector(_ c: RGB, _ w: Float) -> NSValue {
        NSValue(scnVector4: SCNVector4(CGFloat(c.red) / 255, CGFloat(c.green) / 255, CGFloat(c.blue) / 255, CGFloat(w)))
    }
}
