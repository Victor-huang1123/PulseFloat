import Foundation
import PulseFloatCore
import SceneKit
import simd

/// 粒子在片段著色器裡的外觀：柔和圓點、寬光暈、細線、核心熱點。
enum ParticleProfile: Float {
    case dot = 0
    case glow = 1
    case line = 2
    case hot = 3
}

/// 一個密度層：費氏球面（或體積分佈）上的粒子，位置完全決定性（同一組參數永遠同一個結構）。
struct ParticleLayer: Equatable {
    var count: Int
    /// 基準半徑（球的半徑為 1）。
    var radius: Float
    /// 徑向厚度：每顆粒子依雜湊在 ±thickness 內偏移。
    var thickness: Float = 0
    /// 切向抖動（佔晶格間距的比例），打散費氏螺旋的疊紋。
    var jitter: Float = 0.3
    /// 粒子半徑 = sizeFactor × 晶格間距（上限 maxSize）。
    var sizeFactor: Float = 0.38
    var maxSize: Float = 0.03
    /// 對變形的反應程度（0 = 不動，1 = 主殼層）。
    var response: Float = 1
    /// 基本亮度／覆蓋率。
    var brightness: Float = 1
    var profile: ParticleProfile = .dot
    /// 體積分佈（核心、外圍光暈）：半徑由 radius 往外延伸 spread。
    var spread: Float = 0
    /// 體積分佈的密度指數（越大越集中在內側）。
    var falloff: Float = 2
    var seed: UInt32 = 1
}

/// 依畫質與呈現方式決定的粒子配置（精簡模式粒子較少、較大，輪廓乾淨）。
struct ParticleSphereRecipe: Equatable {
    var core: ParticleLayer
    var inner: ParticleLayer
    var second: ParticleLayer
    var main: ParticleLayer
    var nodes: ParticleLayer
    /// 淡淡的外殼（稀疏晶格）。
    var outer: ParticleLayer
    /// 外殼周圍的稀疏塵埃（體積分佈）。
    var halo: ParticleLayer
    /// 節點之間保留的連線比例。
    var linkKeep: Float

    static func make(quality: RenderQuality, presentation: ScenePresentation) -> ParticleSphereRecipe {
        let compact = presentation == .compact
        // [core, inner, second, main, nodes, outer, halo]
        let counts: [Int]
        switch (quality, compact) {
        case (.low, true): counts = [160, 320, 0, 1_150, 80, 220, 60]
        case (.low, false): counts = [220, 460, 0, 1_750, 110, 320, 120]
        case (.medium, true): counts = [380, 820, 1_100, 3_700, 160, 600, 220]
        case (.medium, false): counts = [600, 1_400, 2_000, 6_300, 240, 1_000, 420]
        case (.high, true): counts = [900, 2_000, 3_400, 9_200, 300, 1_500, 600]
        case (.high, false): counts = [1_600, 3_600, 6_400, 17_600, 460, 2_800, 1_200]
        }
        let maxDot: Float = quality == .low ? 0.02 : (quality == .medium ? 0.0165 : 0.0145)
        return ParticleSphereRecipe(
            core: ParticleLayer(count: counts[0], radius: 0.05, jitter: 0, sizeFactor: 0, maxSize: 0.011,
                                response: 0.15, brightness: 0.9, profile: .hot, spread: 0.26, falloff: 1.7, seed: 11),
            inner: ParticleLayer(count: counts[1], radius: 0.5, thickness: 0.035, jitter: 0.35, sizeFactor: 0.34,
                                 maxSize: maxDot * 0.8, response: 0.55, brightness: 0.7, seed: 23),
            second: ParticleLayer(count: counts[2], radius: 0.84, thickness: 0.02, jitter: 0.4, sizeFactor: 0.3,
                                  maxSize: maxDot * 0.8, response: 0.85, brightness: 0.42, seed: 37),
            main: ParticleLayer(count: counts[3], radius: 1.0, thickness: 0.012, jitter: 0.32, sizeFactor: 0.37,
                                maxSize: maxDot, response: 1, brightness: 0.85, seed: 41),
            nodes: ParticleLayer(count: counts[4], radius: 1.0, thickness: 0, jitter: 0.12, sizeFactor: 0,
                                 maxSize: maxDot * 1.35, response: 1, brightness: 1, seed: 53),
            outer: ParticleLayer(count: counts[5], radius: 1.34, thickness: 0.03, jitter: 0.45, sizeFactor: 0.12,
                                 maxSize: maxDot * 0.6, response: 1.2, brightness: 0.34, seed: 61),
            halo: ParticleLayer(count: counts[6], radius: 1.1, jitter: 0, sizeFactor: 0, maxSize: maxDot * 0.55,
                                response: 1.3, brightness: 0.3, spread: 0.65, falloff: 1.6, seed: 67),
            linkKeep: quality == .low ? 0.55 : 0.7)
    }

    /// 粒子總數（不含連線端點）。
    var particleCount: Int { 1 + core.count + inner.count + second.count + main.count + nodes.count + outer.count + halo.count }
}

/// 建好的幾何與數量（測試用）。
struct ParticleSphereMesh {
    let geometry: SCNGeometry
    let particleCount: Int
    let linkCount: Int
}

/// 產生粒子球的幾何：每顆粒子是 4 個頂點的方形（頂點階段展開成面向鏡頭的圓點），
/// 位置存晶格座標的「中心」，texcoord 存角落 (±1, ±1)，color 存 (半徑, 反應, 亮度, 外觀)。
/// 連線是同一組頂點來源裡額外的端點（角落 0、外觀 line）。只在設定改變時呼叫。
enum ParticleSphereLayout {
    static func build(_ recipe: ParticleSphereRecipe) -> ParticleSphereMesh {
        var builder = Builder(capacity: recipe.particleCount + recipe.nodes.count)
        // 核心光暈（一個大的柔和光點，最先畫）
        builder.addQuad(SIMD3<Float>(0, 0, 0), size: 0.42, response: 0, brightness: 0.5, profile: .glow)
        addVolume(recipe.core, into: &builder)
        addShell(recipe.inner, into: &builder)
        addShell(recipe.second, into: &builder)
        addShell(recipe.main, into: &builder)
        let nodeDirections = addShell(recipe.nodes, into: &builder, nodeSize: true)
        addShell(recipe.outer, into: &builder)
        addVolume(recipe.halo, into: &builder)
        let links = makeLinks(nodeDirections, radius: recipe.nodes.radius, keep: recipe.linkKeep, seed: recipe.nodes.seed)
        let lineBase = builder.vertexCount
        var i = 0
        while i < nodeDirections.count {
            builder.addVertex(nodeDirections[i] * recipe.nodes.radius, corner: .zero,
                              attr: SIMD4(0, recipe.nodes.response, 0.5, ParticleProfile.line.rawValue))
            i += 1
        }
        var lineIndices: [UInt32] = []
        lineIndices.reserveCapacity(links.count * 2)
        i = 0
        while i < links.count {
            lineIndices.append(UInt32(lineBase + links[i].0))
            lineIndices.append(UInt32(lineBase + links[i].1))
            i += 1
        }
        let geometry = builder.makeGeometry(lineIndices: lineIndices)
        return ParticleSphereMesh(geometry: geometry, particleCount: builder.quadCount, linkCount: links.count)
    }

    /// 費氏球面殼層（含決定性切向／徑向抖動）；回傳抖動後的方向。
    @discardableResult
    private static func addShell(_ layer: ParticleLayer, into builder: inout Builder, nodeSize: Bool = false) -> [SIMD3<Float>] {
        guard layer.count > 0 else { return [] }
        var directions: [SIMD3<Float>] = []
        directions.reserveCapacity(layer.count)
        let spacing = (4 * Float.pi / Float(layer.count)).squareRoot()   // 單位球上的角間距
        let size = nodeSize ? layer.maxSize : min(layer.maxSize, layer.sizeFactor * spacing * layer.radius)
        let offset = hash(0, layer.seed) * 2 * .pi
        var i = 0
        while i < layer.count {
            var d = fibonacci(i, layer.count, offset: offset)
            if layer.jitter > 0 {
                let (t1, t2) = tangents(d)
                let j1 = hash(UInt32(i) &* 2, layer.seed) * 2 - 1
                let j2 = hash(UInt32(i) &* 2 &+ 1, layer.seed) * 2 - 1
                d = simd_normalize(d + (t1 * j1 + t2 * j2) * layer.jitter * spacing)
            }
            directions.append(d)
            let radial = layer.thickness * (hash(UInt32(i), layer.seed &+ 991) * 2 - 1)
            // 每顆粒子亮度有一點決定性的差異（不是每幀亂數）：約 7% 是較亮的「閃點」，表面有層次
            let h = hash(UInt32(i), layer.seed &+ 577)
            let shade = h > 0.93 ? 1.45 : 0.72 + 0.28 * h / 0.93
            builder.addQuad(d * (layer.radius + radial), size: size * (0.8 + 0.2 * min(1, shade)),
                            response: layer.response, brightness: layer.brightness * shade, profile: layer.profile)
            i += 1
        }
        return directions
    }

    /// 體積分佈（核心團、外圍光暈）：方向走費氏球面，半徑依雜湊與密度指數分佈。
    private static func addVolume(_ layer: ParticleLayer, into builder: inout Builder) {
        guard layer.count > 0 else { return }
        let offset = hash(0, layer.seed) * 2 * .pi
        var i = 0
        while i < layer.count {
            let d = fibonacci(i, layer.count, offset: offset)
            let h = hash(UInt32(i), layer.seed &+ 313)
            let depth = powf(h, layer.falloff)
            let r = layer.radius + layer.spread * depth
            // 越外側越暗、越小
            let fade = 1 - 0.8 * depth
            builder.addQuad(d * r, size: layer.maxSize * (0.7 + 0.3 * fade), response: layer.response,
                            brightness: layer.brightness * fade, profile: layer.profile)
            i += 1
        }
    }

    /// 節點晶格上相鄰點之間的連線（費氏晶格的鄰居在 i ± F_k；只往前找避免重複）。
    static func makeLinks(_ dirs: [SIMD3<Float>], radius: Float, keep: Float, seed: UInt32) -> [(Int, Int)] {
        let n = dirs.count
        guard n > 3 else { return [] }
        var fibs: [Int] = []
        var a = 1, b = 2
        while b < n { fibs.append(b); (a, b) = (b, a + b) }
        let spacing = (4 * Float.pi / Float(n)).squareRoot()
        let limit = 1.55 * spacing
        var links: [(Int, Int)] = []
        links.reserveCapacity(n * 3)
        var i = 0
        while i < n {
            var k = 0
            while k < fibs.count {
                let j = i + fibs[k]
                if j < n, simd_distance(dirs[i], dirs[j]) < limit, hash(UInt32(i &* 131 &+ j), seed &+ 7) < keep {
                    links.append((i, j))
                }
                k += 1
            }
            i += 1
        }
        return links
    }

    /// 費氏球面第 i 點（共 n 點）。
    static func fibonacci(_ i: Int, _ n: Int, offset: Float) -> SIMD3<Float> {
        let y = 1 - 2 * (Float(i) + 0.5) / Float(n)
        let r = max(0, 1 - y * y).squareRoot()
        let a = 2.399_963_2 * Float(i) + offset
        return SIMD3(cos(a) * r, y, sin(a) * r)
    }

    private static func tangents(_ d: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let up: SIMD3<Float> = abs(d.y) < 0.95 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let t1 = simd_normalize(simd_cross(up, d))
        return (t1, simd_cross(d, t1))
    }

    /// 決定性雜湊 → [0, 1)。
    static func hash(_ i: UInt32, _ seed: UInt32) -> Float {
        var x = i &* 0x9E37_79B1 ^ (seed &* 0x85EB_CA77 &+ 0x2545_F491)
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return Float(x >> 8) / Float(1 << 24)
    }

    /// 頂點資料累積器（只在 apply 時使用）。
    private struct Builder {
        var positions: [Float] = []
        var corners: [Float] = []
        var attrs: [Float] = []
        var indices: [UInt32] = []
        private(set) var vertexCount = 0
        private(set) var quadCount = 0

        init(capacity: Int) {
            positions.reserveCapacity(capacity * 12)
            corners.reserveCapacity(capacity * 8)
            attrs.reserveCapacity(capacity * 16)
            indices.reserveCapacity(capacity * 6)
        }

        mutating func addVertex(_ p: SIMD3<Float>, corner: SIMD2<Float>, attr: SIMD4<Float>) {
            positions.append(p.x); positions.append(p.y); positions.append(p.z)
            corners.append(corner.x); corners.append(corner.y)
            attrs.append(attr.x); attrs.append(attr.y); attrs.append(attr.z); attrs.append(attr.w)
            vertexCount += 1
        }

        mutating func addQuad(_ center: SIMD3<Float>, size: Float, response: Float, brightness: Float, profile: ParticleProfile) {
            let base = UInt32(vertexCount)
            let attr = SIMD4<Float>(size, response, brightness, profile.rawValue)
            addVertex(center, corner: SIMD2(-1, -1), attr: attr)
            addVertex(center, corner: SIMD2(1, -1), attr: attr)
            addVertex(center, corner: SIMD2(1, 1), attr: attr)
            addVertex(center, corner: SIMD2(-1, 1), attr: attr)
            indices.append(base); indices.append(base + 1); indices.append(base + 2)
            indices.append(base); indices.append(base + 2); indices.append(base + 3)
            quadCount += 1
        }

        func makeGeometry(lineIndices: [UInt32]) -> SCNGeometry {
            let n = vertexCount
            let vertex = SCNGeometrySource(data: Data(bytes: positions, count: positions.count * 4), semantic: .vertex,
                                           vectorCount: n, usesFloatComponents: true, componentsPerVector: 3,
                                           bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let texcoord = SCNGeometrySource(data: Data(bytes: corners, count: corners.count * 4), semantic: .texcoord,
                                             vectorCount: n, usesFloatComponents: true, componentsPerVector: 2,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
            let color = SCNGeometrySource(data: Data(bytes: attrs, count: attrs.count * 4), semantic: .color,
                                          vectorCount: n, usesFloatComponents: true, componentsPerVector: 4,
                                          bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let quads = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * 4), primitiveType: .triangles,
                                           primitiveCount: indices.count / 3, bytesPerIndex: 4)
            var elements = [quads]
            if !lineIndices.isEmpty {
                elements.append(SCNGeometryElement(data: Data(bytes: lineIndices, count: lineIndices.count * 4),
                                                   primitiveType: .line, primitiveCount: lineIndices.count / 2, bytesPerIndex: 4))
            }
            let geometry = SCNGeometry(sources: [vertex, texcoord, color], elements: elements)
            // 變形在頂點階段發生，CPU 端的包圍盒要涵蓋最大變形，避免被視錐剔除
            geometry.boundingBox = (min: SCNVector3(-2.4, -2.4, -2.4), max: SCNVector3(2.4, 2.4, 2.4))
            return geometry
        }
    }
}
