import Foundation
import SceneKit

/// 地形的靜態網格（只在欄數／列數改變時建立；每幀的高度與捲動都在 geometry modifier 裡算）。
enum TerrainGeometry {
    /// columns × rows 的格點曲面。texcoord = (u 0...1, 列號 k)；三角形由後往前排（半透明時畫家順序正確）。
    static func surface(columns: Int, rows: Int, width: Float, depth: Float, height: Float, base: Float) -> SCNGeometry {
        let cols = max(2, columns), rowCount = max(4, rows)
        let vertexCount = cols * rowCount
        var positions = [Float](repeating: 0, count: vertexCount * 3)
        var normals = [Float](repeating: 0, count: vertexCount * 3)
        var texcoords = [Float](repeating: 0, count: vertexCount * 2)
        var k = 0
        while k < rowCount {
            let s = k == 0 ? 0 : min(depth, Float(k - 1) * depth / Float(rowCount - 2))
            var j = 0
            while j < cols {
                let v = k * cols + j
                let u = Float(j) / Float(cols - 1)
                positions[v * 3] = (u - 0.5) * width
                positions[v * 3 + 2] = depth / 2 - s
                normals[v * 3 + 1] = 1
                texcoords[v * 2] = u
                texcoords[v * 2 + 1] = Float(k)
                j += 1
            }
            k += 1
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((rowCount - 1) * (cols - 1) * 6)
        k = rowCount - 2
        while k >= 0 {
            var j = 0
            while j < cols - 1 {
                let a = UInt32(k * cols + j), b = UInt32(k * cols + j + 1)
                let c = UInt32((k + 1) * cols + j), d = UInt32((k + 1) * cols + j + 1)
                indices.append(contentsOf: [a, b, c, b, d, c])
                j += 1
            }
            k -= 1
        }
        let geometry = make(positions: positions, normals: normals, texcoords: texcoords, indices: indices)
        geometry.boundingBox = (min: SCNVector3(-width / 2, -base, -depth / 2), max: SCNVector3(width / 2, height, depth / 2))
        return geometry
    }

    /// 雕塑模式的四面切面：每個邊緣頂點一對（底 y = 0、頂 y = 1 當旗標），法線朝外。
    static func skirt(columns: Int, rows: Int, width: Float, depth: Float, height: Float, base: Float) -> SCNGeometry {
        let cols = max(2, columns), rowCount = max(4, rows)
        var positions: [Float] = [], normals: [Float] = [], texcoords: [Float] = []
        var indices: [UInt32] = []
        // 一面：沿著 (u, k) 的邊緣點序列，outward 為朝外法線。
        func side(_ points: [(u: Float, k: Int)], outward: SIMD3<Float>) {
            let first = UInt32(positions.count / 3)
            var i = 0
            while i < points.count {
                let p = points[i]
                let s = p.k == 0 ? 0 : min(depth, Float(p.k - 1) * depth / Float(rowCount - 2))
                let x = (p.u - 0.5) * width, z = depth / 2 - s
                var flag: Float = 0
                while flag <= 1 {
                    positions.append(contentsOf: [x, flag, z])
                    normals.append(contentsOf: [outward.x, outward.y, outward.z])
                    texcoords.append(contentsOf: [p.u, Float(p.k)])
                    flag += 1
                }
                i += 1
            }
            // 用名目位置判斷繞序，讓正面朝外。
            var flip = false
            if points.count >= 2 {
                let a = SIMD3<Float>(positions[Int(first) * 3], 0, positions[Int(first) * 3 + 2])
                let b = SIMD3<Float>(positions[Int(first + 2) * 3], 0, positions[Int(first + 2) * 3 + 2])
                let top = SIMD3<Float>(a.x, 1, a.z)
                let n = simd_cross(b - a, top - a)
                flip = simd_dot(n, outward) < 0
            }
            i = 0
            while i + 1 < points.count {
                let b0 = first + UInt32(i * 2), t0 = b0 + 1, b1 = b0 + 2, t1 = b0 + 3
                if flip {
                    indices.append(contentsOf: [b0, t0, b1, b1, t0, t1])
                } else {
                    indices.append(contentsOf: [b0, b1, t0, b1, t1, t0])
                }
                i += 1
            }
        }
        var front: [(u: Float, k: Int)] = [], back: [(u: Float, k: Int)] = []
        var left: [(u: Float, k: Int)] = [], right: [(u: Float, k: Int)] = []
        var j = 0
        while j < cols {
            let u = Float(j) / Float(cols - 1)
            front.append((u, 0))
            back.append((u, rowCount - 1))
            j += 1
        }
        var k = 0
        while k < rowCount {
            left.append((0, k))
            right.append((1, k))
            k += 1
        }
        side(front, outward: SIMD3(0, 0, 1))
        side(back, outward: SIMD3(0, 0, -1))
        side(left, outward: SIMD3(-1, 0, 0))
        side(right, outward: SIMD3(1, 0, 0))
        let geometry = make(positions: positions, normals: normals, texcoords: texcoords, indices: indices)
        geometry.boundingBox = (min: SCNVector3(-width / 2, -base, -depth / 2), max: SCNVector3(width / 2, height, depth / 2))
        return geometry
    }

    private static func make(positions: [Float], normals: [Float], texcoords: [Float], indices: [UInt32]) -> SCNGeometry {
        let vertexCount = positions.count / 3
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: vertexCount, usesFloatComponents: true,
                                     componentsPerVector: components, bytesPerComponent: MemoryLayout<Float>.size,
                                     dataOffset: 0, dataStride: MemoryLayout<Float>.size * components)
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: indices.count / 3,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        return SCNGeometry(sources: [source(positions, .vertex, components: 3), source(normals, .normal, components: 3),
                                     source(texcoords, .texcoord, components: 2)], elements: [element])
    }
}
