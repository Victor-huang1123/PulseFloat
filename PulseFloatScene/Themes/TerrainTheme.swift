import Metal
import PulseFloatCore
import SceneKit

/// 地形的尺寸、解析度與線條密度（由畫質與呈現方式決定）。
struct TerrainLayout: Equatable {
    /// 頻率方向的格點數（對數頻率 X 軸）。
    let columns: Int
    /// 時間方向的格點數＝歷史切片數。
    let rows: Int
    /// 整片地形代表幾秒的音訊（音訊時鐘）。
    let historySeconds: Double
    /// 時間切片線、頻率格線每幾格畫一條。
    let rowLineStep: Int
    let colLineStep: Int
    /// 世界座標：寬（頻率）、深（時間）、最大高度、雕塑台座厚度。
    let width: Float
    let depth: Float
    let height: Float
    let base: Float
    /// 精簡模式左右兩側壓平並淡出的寬度（u 比例）；雕塑模式要露出完整剖面，所以是 0。
    let edgeTaper: Float
    let sculpture: Bool

    /// 音訊時鐘每秒新增的切片數（雕塑模式的地形較淺，用較短的歷史讓鼓點稜線不要擠在一起）。
    var rowsPerSecond: Double { Double(rows - 2) / (historySeconds * (sculpture ? 0.8 : 1)) }

    init(_ settings: SceneSettings) {
        switch settings.quality {
        case .low:
            columns = 64; rows = 48; historySeconds = 3.2; rowLineStep = 2; colLineStep = 2
        case .medium:
            columns = 96; rows = 96; historySeconds = 4.0; rowLineStep = 3; colLineStep = 3
        case .high:
            columns = 128; rows = 160; historySeconds = 4.5; rowLineStep = 4; colLineStep = 4
        }
        sculpture = settings.presentation == .sculpture
        if sculpture {
            width = 2.8; depth = 1.6; height = 0.4; base = 0.1; edgeTaper = 0
        } else {
            width = 3.6; depth = 3.0; height = 0.55; base = 0; edgeTaper = 0.05
        }
    }

    /// 精簡：低角度沿時間軸看過去，地形填滿寬扁的浮動條。
    static let compactPose = CameraPose(target: SIMD3(0, -0.36, -0.1), distance: 4.0, elevation: 23, azimuth: 0, fov: 30)
    /// 雕塑：約 30° 俯角的立體模型（diorama），看得到正面與低頻側的切面。
    /// target 壓低到台座中段，模型在畫面裡垂直置中：擺動到 ±6° 時台座的前角也不會被畫面下緣切掉。
    static let sculpturePose = CameraPose(target: SIMD3(0, -0.25, 0), distance: 3.9, elevation: 27, azimuth: -10, fov: 26)

    /// 地形基準面（高度 0）在世界座標的 y。
    var groundY: Float { sculpture ? -0.12 : -0.3 }
}

/// 音訊地形：頻譜歷史堆成的山脈地景。
///
/// - X = 對數頻率（左低右高），深度 = 時間（新切片從最前面出現、往後退），高度 = 能量。
/// - 歷史是一張小貼圖裡的環狀緩衝（`TerrainHistory`），geometry modifier 取高度並平滑捲動；CPU 每幀只上傳一列。
/// - 低頻用寬的空間平滑核（寬廣的山），高頻用窄的（細緻的稜線）。起音在當時的切片留下標記，變成往後退的鼓點線。
/// - 兩種外觀：線框地景（`.wireframe`）與平滑半透明曲面（`.surface`）。
/// - 雕塑模式：放在台座上的立體模型，四周的切面露出剖面（正面就是即時頻譜的剪影），隨音訊時鐘輕微擺動。
/// - 靜音：不提交切片、不捲動、不擺動，畫面逐像素不變。
@MainActor
final class TerrainTheme: SceneTheme {
    let stage = SceneStage()
    private let root = SCNNode()
    private let surfaceNode = SCNNode()
    private let skirtNode = SCNNode()
    private(set) var history: TerrainHistory?
    private(set) var layout = TerrainLayout(SceneSettings())
    private var settings = SceneSettings()
    private var geometryKey = ""
    private var rest = true
    /// 最近一次的音訊時鐘（雕塑模式的擺動是它的純函數）。
    private var lastTime: Double = 0
    private var swayTime: Double = -1

    private static let device = MTLCreateSystemDefaultDevice()

    var scene: SCNScene { stage.scene }
    var pointOfView: SCNNode { stage.cameraNode }
    var isAtRest: Bool { rest }

    init() {
        root.addChildNode(surfaceNode)
        root.addChildNode(skirtNode)
        stage.content.addChildNode(root)
    }

    func apply(_ settings: SceneSettings) {
        self.settings = settings
        let layout = TerrainLayout(settings)
        self.layout = layout
        stage.apply(settings, compact: TerrainLayout.compactPose, sculpture: TerrainLayout.sculpturePose,
                    floorY: layout.groundY - layout.base, pedestalRadius: nil, orbitSpeed: 0)

        if let history, history.columns == layout.columns, history.rows == layout.rows {
            history.rowsPerSecond = layout.rowsPerSecond
            history.lineStep = layout.rowLineStep
            history.writeParams()
        } else {
            history = TerrainHistory(columns: layout.columns, rows: layout.rows, rowsPerSecond: layout.rowsPerSecond,
                                     lineStep: layout.rowLineStep, device: Self.device, from: history)
        }

        let key = "\(layout.columns)x\(layout.rows)x\(layout.width)x\(layout.depth)x\(layout.height)x\(layout.base)"
        if key != geometryKey {
            geometryKey = key
            surfaceNode.geometry = TerrainGeometry.surface(columns: layout.columns, rows: layout.rows, width: layout.width,
                                                           depth: layout.depth, height: layout.height, base: layout.base)
            skirtNode.geometry = TerrainGeometry.skirt(columns: layout.columns, rows: layout.rows, width: layout.width,
                                                       depth: layout.depth, height: layout.height, base: layout.base)
        }
        let palette = TerrainPalette.make(style: settings.style, look: stage.look, surface: settings.terrainSurface)
        surfaceNode.geometry?.firstMaterial = surfaceMaterial(palette, layout: layout)
        skirtNode.geometry?.firstMaterial = skirtMaterial(palette, layout: layout)
        skirtNode.isHidden = !layout.sculpture
        // 不開 HDR bloom：實測 wantsHDR 時靜音的兩幀不是逐像素相同，而且細線本身已經夠亮。
        stage.camera.wantsHDR = false
        root.position = SCNVector3(0, CGFloat(layout.groundY), 0)
        swayTime = -1
        applySway(time: lastTime)
    }

    func update(frame: SpectrumFrame, dt: Double) {
        let f = frame.features
        let changed = history?.advance(values: frame.values, features: f, dt: dt) ?? false
        if f.time.isFinite { lastTime = f.time }
        applySway(time: lastTime)
        stage.update(features: f)
        rest = f.isSilent && !changed
    }

    /// 雕塑模式隨音訊時鐘輕微左右擺動（純函數：靜音時時鐘停止，擺動也停）；精簡模式固定。
    private func applySway(time: Double) {
        guard time != swayTime else { return }
        swayTime = time
        if layout.sculpture {
            let phase = (time / 38).truncatingRemainder(dividingBy: 1) * 2 * Double.pi
            root.eulerAngles = SCNVector3(0, CGFloat(6 * Double.pi / 180 * sin(phase)), 0)
        } else {
            root.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    // MARK: - 材質

    /// 地形自己的主光：跟舞台主光同一側（右前上方，所以跟雕塑模式的落影一致），但壓低成斜射光，
    /// 讓沿著時間軸延伸的山脈左右兩面明暗分明。補光沿用舞台的補光方向。
    private static let terrainKey = simd_normalize(SIMD3<Float>(0.62, 0.6, 0.5))

    private func lightUniforms(_ palette: TerrainPalette) -> (SIMD4<Float>, SIMD4<Float>) {
        let key = Self.terrainKey
        let fill = -stage.fillLight.simdWorldFront
        return (SIMD4(key.x, key.y, key.z, palette.lighting.y), SIMD4(fill.x, fill.y, fill.z, palette.lighting.z))
    }

    private func geometryUniforms(_ material: SCNMaterial, layout: TerrainLayout) {
        if let texture = history?.texture {
            material.setValue(SCNMaterialProperty(contents: texture), forKey: "u_hist")
        }
        Self.set(material, "u_dims", SIMD4(layout.width, layout.depth, layout.height, layout.depth / 2))
        Self.set(material, "u_shape", SIMD4(1.8, layout.base, Float(layout.rowLineStep), 0.7))
        Self.set(material, "u_edge", SIMD4(layout.edgeTaper, layout.edgeTaper * 1.4, 0, 0))
    }

    private func surfaceMaterial(_ palette: TerrainPalette, layout: TerrainLayout) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.isDoubleSided = false
        guard history?.texture != nil else { return material }
        material.shaderModifiers = [.geometry: TerrainShaders.surfaceGeometry, .fragment: TerrainShaders.surfaceFragment]
        geometryUniforms(material, layout: layout)
        let surface = settings.terrainSurface == .surface
        let (key, fill) = lightUniforms(palette)
        Self.set(material, "u_fillLow", palette.fillLow)
        Self.set(material, "u_fillHigh", palette.fillHigh)
        Self.set(material, "u_fillHot", palette.fillHot)
        Self.set(material, "u_lineCol", palette.line)
        Self.set(material, "u_lineHot", palette.lineHot)
        Self.set(material, "u_lineFreq", palette.lineTreble)
        Self.set(material, "u_beatCol", palette.beat)
        Self.set(material, "u_keyLight", key)
        Self.set(material, "u_fillLight", fill)
        Self.set(material, "u_shade", SIMD4(palette.lighting.x, palette.lighting.w, palette.shininess, palette.fresnel))
        // (線寬 px, 前緣線寬 px, 頻率格線數, 等高線間距)
        let colLines = Float(layout.columns - 1) / Float(layout.colLineStep)
        Self.set(material, "u_lines", SIMD4(surface ? 1.0 : 1.25, surface ? 1.2 : 1.6, colLines, surface ? 0.08 : 0))
        // (最遠處不透明度, 曲面模式, 等高線 alpha, 時間切片線 alpha)
        Self.set(material, "u_mode", SIMD4(palette.fogFar, surface ? 1 : 0, surface ? 0.5 : 0, surface ? 0.0 : 1))
        if surface {
            var hot = palette.lineHot
            hot.w = 0
            Self.set(material, "u_lineHot", hot)
        }
        return material
    }

    private func skirtMaterial(_ palette: TerrainPalette, layout: TerrainLayout) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        guard history?.texture != nil else { return material }
        material.shaderModifiers = [.geometry: TerrainShaders.skirtGeometry, .fragment: TerrainShaders.skirtFragment]
        geometryUniforms(material, layout: layout)
        let (key, fill) = lightUniforms(palette)
        Self.set(material, "u_face", SIMD4(palette.face, palette.strataAlpha))
        Self.set(material, "u_faceLow", SIMD4(palette.faceLow, palette.groundAlpha))
        Self.set(material, "u_rimCol", SIMD4(palette.rim, 1.4))
        Self.set(material, "u_rimHot", SIMD4(palette.rimHot, 0.06))
        Self.set(material, "u_keyLight", key)
        Self.set(material, "u_fillLight", fill)
        Self.set(material, "u_shade", SIMD4(palette.lighting.x + 0.08, 0, 1, 0))
        Self.set(material, "u_faceDims", SIMD4(layout.height, layout.base, 0, 0.55))
        return material
    }

    private static func set(_ material: SCNMaterial, _ key: String, _ v: SIMD4<Float>) {
        material.setValue(NSValue(scnVector4: SCNVector4(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z), CGFloat(v.w))), forKey: key)
    }
}
