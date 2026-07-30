import SwiftUI
import SceneKit

/// A note placed in the 3D body (id + which axis region it belongs to).
struct GraphNode { let id: UUID; let axis: String }
/// A scored connection between two placed notes.
struct GraphEdge { let a: UUID; let b: UUID; let cross: Bool }

/// Phase-1/3 spike: a rotatable androgynous body (grey when young, tinting to each
/// axis's color as it grows) with the connection graph rendered *inside* it — the
/// translucent figure holds a glowing connectome (nodes at their regions, links as
/// threads, cross-axis brighter). Proves the avatar + graph overlap naturally on a
/// placeholder body; a sculpted model replaces the primitives later.
struct Avatar3DView: UIViewRepresentable {
    var color: (String) -> UIColor
    var growth: (String) -> CGFloat
    var nodes: [GraphNode]
    var links: [GraphEdge]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    private func region(_ axis: String) -> (Double, Double, Double) {
        switch axis {
        case "mind":    return (-0.07, 0.80, 0)
        case "meaning": return ( 0.07, 0.80, 0)
        case "heart":   return (0,  0.38, 0.02)
        case "spirit":  return (0,  0.12, 0.02)
        case "gut":     return (0, -0.06, 0.02)
        case "body":    return (0, -0.20, 0)
        default:        return (0,  0.10, 0)
        }
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 64; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { let c = SCNCapsule(capRadius: r, height: h); c.radialSegmentCount = 32; return c }

        let cam = SCNNode()
        cam.camera = SCNCamera(); cam.camera?.fieldOfView = 42
        cam.position = v(0, 0.05, 4.2)
        scene.rootNode.addChildNode(cam)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 700
        key.eulerAngles = v(-0.5, 0.6, 0); scene.rootNode.addChildNode(key)

        let figure = SCNNode()
        let greyBase = UIColor(white: 0.62, alpha: 1)
        func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa); b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
        }

        // Translucent body: overlapping forms, grey→axis color with growth. It
        // doesn't write depth, so the connectome inside stays fully visible.
        func part(_ geo: SCNGeometry, _ axis: String, _ pos: SCNVector3, scale: SCNVector3 = SCNVector3(1, 1, 1), euler: SCNVector3 = SCNVector3(0, 0, 0)) {
            let g = min(1, max(0, growth(axis)))
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = blend(greyBase, color(axis), g * 0.85).withAlphaComponent(0.34)
            m.roughness.contents = 0.5
            m.emission.contents = color(axis); m.emission.intensity = 0.03 + 0.3 * g
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.position = pos; n.scale = scale; n.eulerAngles = euler; n.renderingOrder = 0
            figure.addChildNode(n)
        }
        part(ball(0.17), "mind",    v(-0.07, 0.80, 0), scale: v(0.85, 1.15, 1.0))
        part(ball(0.17), "meaning", v( 0.07, 0.80, 0), scale: v(0.85, 1.15, 1.0))
        part(limb(0.065, 0.16), "body", v(0, 0.60, 0))
        part(ball(0.27), "heart",  v(0,  0.38, 0), scale: v(1.0, 0.95, 0.72))
        part(ball(0.22), "spirit", v(0,  0.12, 0), scale: v(0.95, 1.0, 0.80))
        part(ball(0.22), "gut",    v(0, -0.06, 0), scale: v(1.0, 0.9, 0.82))
        part(ball(0.24), "body",   v(0, -0.24, 0), scale: v(1.05, 0.82, 0.86))
        part(limb(0.07, 0.66), "body", v(-0.29, 0.20, 0), euler: v(0, 0, 0.16))
        part(limb(0.07, 0.66), "body", v( 0.29, 0.20, 0), euler: v(0, 0, -0.16))
        part(limb(0.095, 0.80), "body", v(-0.11, -0.64, 0))
        part(limb(0.095, 0.80), "body", v( 0.11, -0.64, 0))

        // Place each note as a point of light near its axis region.
        var pos: [UUID: SCNVector3] = [:]
        for (_, group) in Dictionary(grouping: nodes, by: { $0.axis }) {
            let c = region(group[0].axis)
            let n = Double(group.count)
            for (i, gn) in group.enumerated() {
                let ga = Double(i) * 2.399963
                let rr = 0.12 * (Double(i) + 0.6).squareRoot() / max(1, n).squareRoot()
                let p = v(c.0 + rr * cos(ga), c.1 + (Double(i % 3) - 1) * 0.05, c.2 + 0.02 + rr * sin(ga))
                pos[gn.id] = p
                let s = ball(0.023); s.segmentCount = 14
                let m = SCNMaterial(); m.lightingModel = .constant
                let col = color(gn.axis); m.diffuse.contents = col; m.emission.contents = col; m.emission.intensity = 1.0
                s.materials = [m]
                let node = SCNNode(geometry: s); node.position = p; node.renderingOrder = 12
                figure.addChildNode(node)
            }
        }

        // Draw links as glowing threads; cross-axis ones brighter and thicker.
        for e in links {
            guard let a = pos[e.a], let b = pos[e.b] else { continue }
            let col = e.cross ? UIColor(red: 0.55, green: 0.8, blue: 1.0, alpha: 1) : UIColor(white: 0.72, alpha: 1)
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
            let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
            let cyl = SCNCylinder(radius: e.cross ? 0.006 : 0.0035, height: CGFloat(dist))
            cyl.radialSegmentCount = 6
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = col; m.emission.contents = col; m.emission.intensity = e.cross ? 1.0 : 0.5
            cyl.materials = [m]
            let node = SCNNode(geometry: cyl)
            node.position = v((Double(a.x) + Double(b.x)) / 2, (Double(a.y) + Double(b.y)) / 2, (Double(a.z) + Double(b.z)) / 2)
            node.look(at: b, up: v(0, 1, 0), localFront: v(0, 1, 0))
            node.renderingOrder = 11
            figure.addChildNode(node)
        }

        figure.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 30)))
        scene.rootNode.addChildNode(figure)
        return scene
    }
}
