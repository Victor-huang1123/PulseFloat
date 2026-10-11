import SceneKit

/// 一個 shader 圖層：一個節點加自己的材質（同一份頂點資料可以給好幾個圖層用）。
@MainActor
final class BlackHoleLayer {
    let node = SCNNode()
    let material: SCNMaterial

    /// order：繪製順序（SceneKit 的 renderingOrder）；writesDepth：是否寫入深度（只有吸積盤寫）。
    init(geometry: String, fragment: String, order: Int, writesDepth: Bool = false) {
        material = BlackHoleShaders.material(geometry: geometry, fragment: fragment, writesDepth: writesDepth)
        node.renderingOrder = order
        node.castsShadow = false
    }

    /// 換上新的幾何（共用頂點資料的副本，材質換成這個圖層的）；nil 表示不畫。
    func setGeometry(_ geometry: SCNGeometry?) {
        let copy = geometry?.copy() as? SCNGeometry
        copy?.firstMaterial = material
        node.geometry = copy
    }

    func set(_ key: String, _ value: Any) {
        material.setValue(value, forKey: key)
    }
}
