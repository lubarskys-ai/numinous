import SwiftUI
import SceneKit

/// Phase-1 3D spike: a rotatable humanoid assembled from SceneKit primitives,
/// each region carrying its axis's color and glowing with that axis's growth.
/// It's a *placeholder* body — the point is to prove the SwiftUI + SceneKit
/// pipeline renders and orbits smoothly on device; a real sculpted/rigged model
/// replaces these primitives in a later phase.
struct Avatar3DView: UIViewRepresentable {
    var color: (String) -> UIColor
    var growth: (String) -> CGFloat

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

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
            SCNVector3(Float(x), Float(y), Float(z))
        }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 64; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { let c = SCNCapsule(capRadius: r, height: h); c.radialSegmentCount = 32; return c }

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 42
        cam.position = v(0, 0.05, 4.2)
        scene.rootNode.addChildNode(cam)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 750
        key.eulerAngles = v(-0.5, 0.6, 0)
        scene.rootNode.addChildNode(key)

        let figure = SCNNode()
        let greyBase = UIColor(white: 0.60, alpha: 1)
        func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
        }

        // One smooth androgynous body. Every region starts neutral grey and tints
        // toward — and glows with — its axis's color as that axis matures.
        func part(_ geo: SCNGeometry, _ axis: String, _ pos: SCNVector3, scale: SCNVector3 = SCNVector3(1, 1, 1), euler: SCNVector3 = SCNVector3(0, 0, 0)) {
            let g = min(1, max(0, growth(axis)))
            let c = color(axis)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = blend(greyBase, c, g * 0.85)
            m.roughness.contents = 0.42
            m.metalness.contents = 0.04
            m.emission.contents = c
            m.emission.intensity = 0.04 + 0.4 * g
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.position = pos; n.scale = scale; n.eulerAngles = euler
            figure.addChildNode(n)
        }
        // bicameral brain — two overlapping hemispheres (grey until they grow)
        part(ball(0.17), "mind",    v(-0.07, 0.80, 0), scale: v(0.85, 1.15, 1.0))
        part(ball(0.17), "meaning", v( 0.07, 0.80, 0), scale: v(0.85, 1.15, 1.0))
        part(limb(0.065, 0.16), "body", v(0, 0.60, 0))                 // neck
        part(ball(0.27), "heart",  v(0,  0.38, 0), scale: v(1.0, 0.95, 0.72))   // chest
        part(ball(0.22), "spirit", v(0,  0.12, 0), scale: v(0.95, 1.0, 0.80))   // core
        part(ball(0.22), "gut",    v(0, -0.06, 0), scale: v(1.0, 0.9, 0.82))    // belly
        part(ball(0.24), "body",   v(0, -0.24, 0), scale: v(1.05, 0.82, 0.86))  // hips
        part(limb(0.07, 0.66), "body", v(-0.29, 0.20, 0), euler: v(0, 0, 0.16)) // arms
        part(limb(0.07, 0.66), "body", v( 0.29, 0.20, 0), euler: v(0, 0, -0.16))
        part(limb(0.095, 0.80), "body", v(-0.11, -0.64, 0))            // legs
        part(limb(0.095, 0.80), "body", v( 0.11, -0.64, 0))

        figure.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 30)))
        scene.rootNode.addChildNode(figure)
        return scene
    }
}
