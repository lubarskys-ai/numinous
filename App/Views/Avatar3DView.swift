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
    /// 1 = default distance; larger = zoomed in. Driven by the +/- buttons and pinch.
    var zoom: Double

    static let baseDistance: Float = 8.5

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true          // keep the render loop live for the neural pulses
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.pointOfView?.position.z = Self.baseDistance / Float(max(0.35, zoom))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: SCNView?
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let figure = view?.scene?.rootNode.childNode(withName: "figure", recursively: false) else { return }
            let t = g.translation(in: view)
            figure.eulerAngles.y += Float(t.x) * 0.01
            figure.eulerAngles.x = max(-1.2, min(1.2, figure.eulerAngles.x + Float(t.y) * 0.01))
            g.setTranslation(.zero, in: view)
        }
    }

    private func region(_ axis: String) -> (Double, Double, Double) { GLTFBody.region(axis) }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 64; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { let c = SCNCapsule(capRadius: r, height: h); c.radialSegmentCount = 32; return c }

        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera(); cam.camera?.fieldOfView = 42
        cam.camera?.zNear = 0.01           // allow zooming in close without clipping
        cam.camera?.zFar = 100
        cam.position = v(0, 0.05, 4.2)
        scene.rootNode.addChildNode(cam)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 720
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 620
        key.eulerAngles = v(-0.5, 0.6, 0); scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .directional; fill.light?.intensity = 320
        fill.eulerAngles = v(0.3, -0.9, 0); scene.rootNode.addChildNode(fill)

        let figure = SCNNode()
        figure.name = "figure"
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
        // The real sculpted body, re-skinned grey→color; primitives if it can't load.
        if let modelBody = GLTFBody.load(color: color, growth: growth) {
            figure.addChildNode(modelBody)
        } else {
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
        }

        // Place each note as a point of light, spread evenly through its region
        // (Body drapes across the whole figure) and varied in depth so the web
        // fills the body rather than clustering at the centre.
        var pos: [UUID: SCNVector3] = [:]
        for (axisKey, group) in Dictionary(grouping: nodes, by: { $0.axis }) {
            let c = region(axisKey)
            let n = Double(group.count)
            let spreadXZ = axisKey == "body" ? 0.26 : 0.15
            let spreadY  = axisKey == "body" ? 0.55 : 0.13
            for (i, gn) in group.enumerated() {
                let t = (Double(i) + 0.5) / max(1, n)
                let ga = Double(i) * 2.399963
                let rr = spreadXZ * t.squareRoot()
                let p = v(c.0 + rr * cos(ga),
                          c.1 + (t - 0.5) * 2 * spreadY,
                          c.2 - 0.03 + rr * sin(ga) * 0.7)
                pos[gn.id] = p
                let s = ball(0.014); s.segmentCount = 12          // small, soft synapse
                let m = SCNMaterial(); m.lightingModel = .constant
                let col = color(gn.axis); m.diffuse.contents = col; m.emission.contents = col
                m.emission.intensity = 0.7; m.transparency = 0.92
                s.materials = [m]
                let node = SCNNode(geometry: s); node.position = p; node.renderingOrder = 12
                figure.addChildNode(node)
            }
        }

        // Links as faint neural threads, with a bright signal travelling along each.
        for e in links {
            guard let a = pos[e.a], let b = pos[e.b] else { continue }
            let col = e.cross ? UIColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 1) : UIColor(white: 0.8, alpha: 1)
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
            let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
            let cyl = SCNCylinder(radius: e.cross ? 0.0022 : 0.0014, height: CGFloat(dist))
            cyl.radialSegmentCount = 5
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = col; m.emission.contents = col
            m.emission.intensity = e.cross ? 0.5 : 0.28; m.transparency = 0.5
            cyl.materials = [m]
            let mid = v((Double(a.x) + Double(b.x)) / 2, (Double(a.y) + Double(b.y)) / 2, (Double(a.z) + Double(b.z)) / 2)
            let node = SCNNode(geometry: cyl); node.position = mid
            node.look(at: b, up: v(0, 1, 0), localFront: v(0, 1, 0))
            node.renderingOrder = 11
            figure.addChildNode(node)

            // Travelling signal (neural firing) — staggered so they ripple.
            let signal = ball(0.016); signal.segmentCount = 10
            let sm = SCNMaterial(); sm.lightingModel = .constant
            sm.diffuse.contents = col; sm.emission.contents = col; sm.emission.intensity = 1.4
            signal.materials = [sm]
            let pulse = SCNNode(geometry: signal); pulse.position = a; pulse.renderingOrder = 13
            let dur = Double.random(in: 1.8...3.4)
            let travel = SCNAction.sequence([.move(to: b, duration: dur), .move(to: a, duration: 0)])
            pulse.opacity = 0.9
            pulse.runAction(.sequence([.wait(duration: Double.random(in: 0...3)), .repeatForever(travel)]))
            figure.addChildNode(pulse)
        }

        // No auto-spin: hold still so you can drag to rotate and pinch to zoom in
        // on the connectome without it turning away from you.
        scene.rootNode.addChildNode(figure)
        return scene
    }
}
