import SwiftUI
import SceneKit

/// Phase-1 3D spike: a rotatable humanoid assembled from SceneKit primitives,
/// each region carrying its axis's color and glowing with that axis's growth.
/// It's a *placeholder* body — the point is to prove the SwiftUI + SceneKit
/// pipeline renders and orbits smoothly on device; a real sculpted/rigged model
/// replaces these primitives in a later phase.
struct Avatar3DView: UIViewRepresentable {
    var color: (String) -> UIColor
    var glow: (String) -> CGFloat

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

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 42
        cam.position = v(0, 0.05, 4.4)
        scene.rootNode.addChildNode(cam)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 950
        key.position = v(2.5, 3, 4)
        scene.rootNode.addChildNode(key)

        let figure = SCNNode()
        func part(_ geo: SCNGeometry, _ axis: String, _ pos: SCNVector3, alpha: CGFloat = 0.92) {
            let m = SCNMaterial()
            let c = color(axis)
            m.diffuse.contents = c.withAlphaComponent(alpha)
            m.emission.contents = c
            m.emission.intensity = 0.12 + 0.7 * min(1, max(0, glow(axis)))
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.55
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.position = pos
            figure.addChildNode(n)
        }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 48; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { SCNCapsule(capRadius: r, height: h) }

        part(ball(0.17), "mind",    v(-0.10, 0.78, 0))   // left brain
        part(ball(0.17), "meaning", v( 0.10, 0.78, 0))   // right brain
        part(limb(0.06, 0.16), "body", v(0, 0.60, 0))    // neck
        part(ball(0.22), "heart",  v(0,  0.40, 0))       // chest
        part(ball(0.17), "spirit", v(0,  0.17, 0))       // core
        part(ball(0.18), "gut",    v(0, -0.02, 0))       // belly
        part(ball(0.20), "body",   v(0, -0.22, 0))       // hips
        part(limb(0.06, 0.62), "body", v(-0.30, 0.22, 0))  // arms
        part(limb(0.06, 0.62), "body", v( 0.30, 0.22, 0))
        part(limb(0.08, 0.74), "body", v(-0.11, -0.62, 0)) // legs
        part(limb(0.08, 0.74), "body", v( 0.11, -0.62, 0))

        figure.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 26)))
        scene.rootNode.addChildNode(figure)
        return scene
    }
}

/// Full-screen presentation of the 3D avatar spike.
struct Avatar3DScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Avatar3DView(
                color: { UIColor(model.axis(id: $0)?.color ?? .gray) },
                glow: { min(1, model.score.revealedTotals.points($0) / 150) }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("3D preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .bottom) {
                Text("Drag to rotate · pinch to zoom — a placeholder body (Phase 1)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }
        }
    }
}
