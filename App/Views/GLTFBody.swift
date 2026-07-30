import Foundation
import SceneKit
import UIKit

/// A minimal glTF geometry loader — just enough to pull the single body mesh
/// (positions, normals, indices) out of `scene.gltf` + `scene.bin`, bake the node
/// transforms, normalize it to our canonical figure space (feet at y≈-0.85, head
/// at y≈+0.85, centred, ~1.7 tall), and re-skin it with our own grey→axis-color
/// material per body region. No external dependency, no format conversion.
///
/// Model: "sculpting a human body" by Animation-class-k, CC-BY-4.0 (via Sketchfab).
enum GLTFBody {

    // Canonical region centres (used both for vertex tint and connectome anchors).
    static func region(_ axis: String) -> (Double, Double, Double) {
        switch axis {
        case "mind":    return (-0.09, 0.70, 0.06)
        case "meaning": return ( 0.09, 0.70, 0.06)
        case "heart":   return (0,  0.44, 0.08)
        case "spirit":  return (0,  0.24, 0.08)
        case "gut":     return (0,  0.06, 0.08)
        case "body":    return (0, -0.35, 0.04)
        default:        return (0,  0.20, 0.06)
        }
    }

    /// Which axis a vertex belongs to, from its normalized position.
    private static func axis(forX x: Double, y: Double) -> String {
        if abs(x) > 0.20 { return "body" }        // arms / outer limbs
        if y >= 0.60 { return x < 0 ? "mind" : "meaning" }
        if y >= 0.34 { return "heart" }
        if y >= 0.16 { return "spirit" }
        if y >= 0.00 { return "gut" }
        return "body"
    }

    private struct GLTF: Decodable {
        struct Buffer: Decodable { let uri: String?; let byteLength: Int }
        struct BufferView: Decodable { let buffer: Int; let byteOffset: Int?; let byteStride: Int? }
        struct Accessor: Decodable { let bufferView: Int?; let byteOffset: Int?; let componentType: Int; let count: Int; let type: String }
        struct Primitive: Decodable { let attributes: [String: Int]; let indices: Int? }
        struct Mesh: Decodable { let primitives: [Primitive] }
        struct Node: Decodable { let mesh: Int?; let children: [Int]?; let matrix: [Double]? }
        struct Scene: Decodable { let nodes: [Int]? }
        let buffers: [Buffer]; let bufferViews: [BufferView]; let accessors: [Accessor]
        let meshes: [Mesh]; let nodes: [Node]; let scenes: [Scene]?; let scene: Int?
    }

    static func load(color: (String) -> UIColor, growth: (String) -> CGFloat) -> SCNNode? {
        guard let gltfURL = Bundle.main.url(forResource: "scene", withExtension: "gltf", subdirectory: "HumanBody")
                ?? Bundle.main.url(forResource: "scene", withExtension: "gltf"),
              let json = try? Data(contentsOf: gltfURL),
              let g = try? JSONDecoder().decode(GLTF.self, from: json),
              let binName = g.buffers.first?.uri,
              let binURL = Bundle.main.url(forResource: (binName as NSString).deletingPathExtension, withExtension: "bin", subdirectory: "HumanBody")
                ?? Bundle.main.url(forResource: (binName as NSString).deletingPathExtension, withExtension: "bin"),
              let bin = try? Data(contentsOf: binURL)
        else { return nil }

        // World matrix of the mesh node (product of matrices down the hierarchy).
        var meshWorld: [Double] = Self.identity
        var meshIndex: Int?
        func dfs(_ idx: Int, _ parent: [Double]) {
            guard idx < g.nodes.count else { return }
            let n = g.nodes[idx]
            let world = Self.mul(parent, n.matrix ?? Self.identity)
            if let m = n.mesh { meshWorld = world; meshIndex = m }
            for c in n.children ?? [] { dfs(c, world) }
        }
        for r in (g.scenes?[g.scene ?? 0].nodes ?? [0]) { dfs(r, Self.identity) }
        guard let mi = meshIndex, let prim = g.meshes[safe: mi]?.primitives.first,
              let posA = prim.attributes["POSITION"], let idxA = prim.indices
        else { return nil }

        func offsetStride(_ accessor: Int) -> (base: Int, stride: Int, count: Int, ctype: Int)? {
            guard let a = g.accessors[safe: accessor], let bv = a.bufferView, let view = g.bufferViews[safe: bv] else { return nil }
            let comp = a.type == "VEC3" ? 3 : (a.type == "VEC2" ? 2 : 1)
            let size = a.componentType == 5126 ? 4 : (a.componentType == 5125 ? 4 : (a.componentType == 5123 ? 2 : 1))
            let stride = view.byteStride ?? (comp * size)
            return ((view.byteOffset ?? 0) + (a.byteOffset ?? 0), stride, a.count, a.componentType)
        }
        guard let pos = offsetStride(posA), let idx = offsetStride(idxA) else { return nil }
        let nrm = prim.attributes["NORMAL"].flatMap { offsetStride($0) }

        var vertices = [SCNVector3](); vertices.reserveCapacity(pos.count)
        var normals = [SCNVector3](); normals.reserveCapacity(pos.count)
        var raw = [(Double, Double, Double)](); raw.reserveCapacity(pos.count)
        var indices = [UInt32](); indices.reserveCapacity(idx.count)

        bin.withUnsafeBytes { rp in
            func f(_ o: Int) -> Double { Double(rp.loadUnaligned(fromByteOffset: o, as: Float32.self)) }
            for i in 0..<pos.count {
                let b = pos.base + i * pos.stride
                let p = Self.apply(meshWorld, f(b), f(b + 4), f(b + 8))
                raw.append(p)
            }
            if let nrm {
                for i in 0..<nrm.count {
                    let b = nrm.base + i * nrm.stride
                    let n = Self.applyDir(meshWorld, f(b), f(b + 4), f(b + 8))
                    let len = max(1e-6, (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot())
                    normals.append(SCNVector3(Float(n.0 / len), Float(n.1 / len), Float(n.2 / len)))
                }
            }
            for i in 0..<idx.count {
                let b = idx.base + i * idx.stride
                indices.append(idx.ctype == 5125 ? rp.loadUnaligned(fromByteOffset: b, as: UInt32.self)
                                                 : UInt32(rp.loadUnaligned(fromByteOffset: b, as: UInt16.self)))
            }
        }

        // Normalize: centre in x/z, scale to ~1.7 tall, feet at y = -0.85.
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var minX = minY, maxX = maxY, minZ = minY, maxZ = maxY
        for p in raw {
            minX = min(minX, p.0); maxX = max(maxX, p.0)
            minY = min(minY, p.1); maxY = max(maxY, p.1)
            minZ = min(minZ, p.2); maxZ = max(maxZ, p.2)
        }
        let scale = 1.7 / max(1e-6, maxY - minY)
        let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
        var colors = [Float](); colors.reserveCapacity(raw.count * 3)
        let grey = UIColor(white: 0.62, alpha: 1)
        for p in raw {
            let nx = (p.0 - cx) * scale, ny = (p.1 - minY) * scale - 0.85, nz = (p.2 - cz) * scale
            vertices.append(SCNVector3(Float(nx), Float(ny), Float(nz)))
            let ax = axis(forX: nx, y: ny)
            let c = Self.blend(grey, color(ax), min(1, max(0, growth(ax))) * 0.85)
            var r: CGFloat = 0, gg: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &gg, blue: &b, alpha: &a)
            colors.append(Float(r)); colors.append(Float(gg)); colors.append(Float(b))
        }

        let vSource = SCNGeometrySource(vertices: vertices)
        let cSource = SCNGeometrySource(data: Data(bytes: colors, count: colors.count * 4), semantic: .color,
                                        vectorCount: raw.count, usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        var sources = [vSource, cSource]
        if !normals.isEmpty { sources.append(SCNGeometrySource(normals: normals)) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: sources, elements: [element])

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor.white          // modulated by vertex colors
        m.roughness.contents = 0.45
        m.emission.contents = UIColor(white: 0.06, alpha: 1)   // lift shadows on the pale bg
        m.transparency = 0.22                        // ghostly, so the connectome shows through
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        geo.materials = [m]

        let node = SCNNode(geometry: geo)
        node.renderingOrder = 0
        return node
    }

    // MARK: - Small matrix helpers (column-major 4×4)

    static let identity: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 16)
        for col in 0..<4 { for row in 0..<4 {
            var s = 0.0
            for k in 0..<4 { s += a[k * 4 + row] * b[col * 4 + k] }
            c[col * 4 + row] = s
        } }
        return c
    }
    static func apply(_ m: [Double], _ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (m[0]*x + m[4]*y + m[8]*z + m[12], m[1]*x + m[5]*y + m[9]*z + m[13], m[2]*x + m[6]*y + m[10]*z + m[14])
    }
    static func applyDir(_ m: [Double], _ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (m[0]*x + m[4]*y + m[8]*z, m[1]*x + m[5]*y + m[9]*z, m[2]*x + m[6]*y + m[10]*z)
    }
    static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa); b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
