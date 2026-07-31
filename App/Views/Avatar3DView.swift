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
    /// 0→1 overall growth (fidelity): drives how materialized the body is.
    var maturity: Double
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
        context.coordinator.builtMaturity = maturity
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Rebuild when maturity changes (e.g. the "watch it grow" animation stepping
        // it) so the birth sequence plays; otherwise just track zoom.
        if abs(context.coordinator.builtMaturity - maturity) > 0.004 {
            view.scene = buildScene()
            view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
            context.coordinator.builtMaturity = maturity
        }
        view.pointOfView?.position.z = Self.baseDistance / Float(max(0.35, zoom))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var builtMaturity: Double = -1
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let figure = view?.scene?.rootNode.childNode(withName: "figure", recursively: true) else { return }
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
        // The body mesh lives on its own node so it can float and tumble
        // independently of the connectome nodes, axes, and stars.
        let bodyFloat = SCNNode()
        figure.addChildNode(bodyFloat)
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
            bodyFloat.addChildNode(n)
        }
        // ── Maturation: begin as a diffuse cloud that coalesces into a body ──
        let matur = max(0, min(1, maturity))
        func hrand(_ i: Int, _ salt: Int) -> Double {
            let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233 + 1.7) * 43758.5453
            return x - floor(x)
        }
        func diffusePoint(_ i: Int) -> SCNVector3 {
            v((hrand(i, 1) - 0.5) * 5.6, (hrand(i, 2) - 0.5) * 6.6, (hrand(i, 3) - 0.5) * 3.4)
        }
        func lerpV(_ a: SCNVector3, _ b: SCNVector3, _ t: Double) -> SCNVector3 {
            v(Double(a.x) + (Double(b.x) - Double(a.x)) * t,
              Double(a.y) + (Double(b.y) - Double(a.y)) * t,
              Double(a.z) + (Double(b.z) - Double(a.z)) * t)
        }
        // A birth sequence: just stars → nodes → connections → (as connections
        // multiply) a body with organs. Each layer emerges in its own maturity band.
        func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
        }
        let nodesAppear = smoothstep(0.05, 0.22, matur)
        let linksAppear = smoothstep(0.22, 0.46, matur)
        let bodyAppear  = smoothstep(0.42, 0.90, matur)

        // The real sculpted body, re-skinned grey→color; primitives if it can't load.
        var bodySamples: [SCNVector3] = []
        if let loaded = GLTFBody.load(color: color, growth: growth, maturity: bodyAppear) {
            if bodyAppear > 0.02 { bodyFloat.addChildNode(loaded.node) }   // no ghost body before the body stage
            bodySamples = loaded.samples
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
            for i in 0..<220 {
                let ax = ["mind", "meaning", "heart", "spirit", "gut", "body"][i % 6]
                let c = region(ax)
                bodySamples.append(v(c.0 + (hrand(i, 4) - 0.5) * 0.22, c.1 + (hrand(i, 5) - 0.5) * 0.5, c.2 + (hrand(i, 6) - 0.5) * 0.16))
            }
        }

        // A diffuse cloud of dust that begins scattered across the whole view and
        // gathers onto the body's surface as the avatar matures — stardust → human.
        // The body materializes from a shimmer of motes that gathers onto its
        // surface — only during the body stage, once connections have multiplied.
        if !bodySamples.isEmpty, bodyAppear > 0.02 {
            for i in 0..<460 {
                let target = bodySamples[(i * 89) % bodySamples.count]
                let p = lerpV(diffusePoint(i), target, bodyAppear)
                let ax = GLTFBody.axis(forX: Double(target.x), y: Double(target.y))
                // Bright + emissive so it glows against the dark cosmos backdrop.
                let col = GLTFBody.blend(UIColor(white: 0.9, alpha: 1), color(ax), CGFloat(0.4 + matur * 0.5))
                let dot = ball(0.016); dot.segmentCount = 6
                let dm = SCNMaterial(); dm.lightingModel = .constant
                dm.diffuse.contents = col; dm.emission.contents = col; dm.emission.intensity = 0.9
                dm.transparency = CGFloat(0.6 * bodyAppear)
                dm.writesToDepthBuffer = false
                dot.materials = [dm]
                let n = SCNNode(geometry: dot); n.position = p; n.renderingOrder = 5
                figure.addChildNode(n)
            }
        }

        // A boundless background starfield on a far shell that surrounds the camera,
        // so the cosmos keeps going (never shows an edge) however far you zoom out.
        for i in 0..<700 {
            let u = hrand(i, 11) * 2 - 1
            let phi = hrand(i, 12) * 2 * .pi
            let r = 26 + hrand(i, 13) * 16
            let s = (1 - u * u).squareRoot()
            let b = 0.55 + hrand(i, 14) * 0.45
            let star = ball(0.05); star.segmentCount = 4
            let sm = SCNMaterial(); sm.lightingModel = .constant
            let c = UIColor(white: b, alpha: 1)
            sm.diffuse.contents = c; sm.emission.contents = c; sm.emission.intensity = 0.9
            sm.transparency = CGFloat(0.4 + hrand(i, 15) * 0.5)
            sm.writesToDepthBuffer = false
            star.materials = [sm]
            let n = SCNNode(geometry: star)
            n.position = v(cos(phi) * s * r, u * r, sin(phi) * s * r)
            n.renderingOrder = -1
            figure.addChildNode(n)
        }

        // Place each note as a point of light, spread evenly through its region
        // (Body drapes across the whole figure) and varied in depth so the web
        // fills the body rather than clustering at the centre.
        // How many links touch each note → hubs are drawn a little larger.
        var degree: [UUID: Int] = [:]
        for e in links { degree[e.a, default: 0] += 1; degree[e.b, default: 0] += 1 }

        // Faint translucent organs drawn inside the body (grey→axis color with
        // growth), built from clustered lobes so they read as organic tissue —
        // a two-lobed heart tapering to a point, folded brain hemispheres, a
        // coiled gut — not plain spheres. Their nodes live inside them.
        func organNode(_ axisKey: String, _ orr: Double, _ mat: SCNMaterial) -> SCNNode {
            let parent = SCNNode()
            func lobe(_ r: Double, _ x: Double, _ y: Double, _ z: Double, _ sx: Double = 1, _ sy: Double = 1, _ sz: Double = 1) {
                let s = ball(r); s.segmentCount = 20; s.materials = [mat]
                let n = SCNNode(geometry: s); n.position = v(x, y, z); n.scale = v(sx, sy, sz)
                parent.addChildNode(n)
            }
            // A rounded ridge lying along X — used for brain gyri / intestine tube.
            func ridge(_ length: Double, _ rad: Double, _ x: Double, _ y: Double, _ z: Double, _ ez: Double = 0) {
                let c = SCNCapsule(capRadius: rad, height: length); c.radialSegmentCount = 8; c.materials = [mat]
                let n = SCNNode(geometry: c); n.position = v(x, y, z); n.eulerAngles = v(0, 0, .pi / 2 + ez)
                parent.addChildNode(n)
            }
            switch axisKey {
            case "heart":   // two lobes at top, tapering to a point below
                lobe(orr * 0.62, -orr * 0.34, orr * 0.30, 0)
                lobe(orr * 0.62,  orr * 0.34, orr * 0.30, 0)
                lobe(orr * 0.58, 0, orr * 0.02, 0)
                lobe(orr * 0.42, 0, -orr * 0.34, 0)
                lobe(orr * 0.26, 0, -orr * 0.62, 0)
            case "mind", "meaning":   // a hemisphere (flattened ovoid) with gyri folds
                let toMid = axisKey == "mind" ? 1.0 : -1.0
                lobe(orr * 0.9, toMid * orr * 0.05, 0, 0, 0.8, 0.82, 1.0)   // main mass, flat at the fissure
                for k in 0..<3 {                                            // gyri ridges over the top
                    ridge(orr * 1.05, orr * 0.15, 0, orr * 0.42, Double(k - 1) * orr * 0.42)
                }
            case "gut":   // a serpentine coil of intestine, winding side-to-side downward
                for i in 0..<8 {
                    let t = Double(i) / 7
                    lobe(orr * 0.34, sin(t * .pi * 3) * orr * 0.5, (0.5 - t) * orr * 1.25, cos(t * .pi * 2) * orr * 0.22)
                }
            default:      // spirit: a smooth luminous core
                lobe(orr, 0, 0, 0)
            }
            return parent
        }

        let organRadius: [String: Double] = ["mind": 0.10, "meaning": 0.10, "heart": 0.12, "spirit": 0.09, "gut": 0.12]
        for (axisKey, orr) in organRadius {
            let c = region(axisKey)
            let g = CGFloat(min(1, max(0, growth(axisKey))))
            let col = GLTFBody.blend(UIColor(white: 0.6, alpha: 1), color(axisKey), g * 0.9)
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = col; m.emission.contents = col; m.emission.intensity = 0.12
            m.transparency = CGFloat(0.18 * bodyAppear); m.writesToDepthBuffer = false; m.isDoubleSided = true
            let organ = organNode(axisKey, orr, m)
            organ.position = v(c.0, c.1, c.2)
            organ.renderingOrder = 8
            figure.addChildNode(organ)
        }

        // Every axis places its nodes inside a small interior ellipsoid, so the
        // whole connectome stays within the body (Body fills the torso/pelvis core).
        let contain: [String: (Double, Double, Double)] = [
            "mind": (0.06, 0.07, 0.05), "meaning": (0.06, 0.07, 0.05),
            "heart": (0.08, 0.075, 0.055), "spirit": (0.065, 0.075, 0.05),
            "gut": (0.08, 0.06, 0.055), "body": (0.10, 0.20, 0.06),
        ]

        var pos: [UUID: SCNVector3] = [:]
        for (axisKey, group) in Dictionary(grouping: nodes, by: { $0.axis }) {
            let c = region(axisKey)
            let (rx, ry, rz) = contain[axisKey] ?? (0.07, 0.07, 0.05)
            let n = Double(group.count)
            for (i, gn) in group.enumerated() {
                let t = (Double(i) + 0.5) / max(1, n)
                let ga = Double(i) * 2.399963
                let rad = t.squareRoot()
                // Nodes start scattered across space and only drift together into
                // the body form as the avatar matures — a few loose points first.
                let anatomical = v(c.0 + rx * rad * cos(ga),
                                   c.1 + (t - 0.5) * 2 * ry,
                                   c.2 + rz * rad * sin(ga))
                let converge = smoothstep(0.08, 0.55, matur)
                let p = lerpV(diffusePoint(abs(gn.id.hashValue % 90000) + 3), anatomical, converge)
                pos[gn.id] = p
                guard nodesAppear > 0.02 else { continue }
                let r = min(0.026, 0.007 + 0.006 * Double(degree[gn.id] ?? 0).squareRoot())  // grows with connections
                let s = ball(r); s.segmentCount = 12
                let m = SCNMaterial(); m.lightingModel = .constant
                let col = color(gn.axis); m.diffuse.contents = col; m.emission.contents = col
                m.emission.intensity = 0.6; m.transparency = CGFloat(0.88 * nodesAppear)
                s.materials = [m]
                let node = SCNNode(geometry: s); node.position = p; node.renderingOrder = 12
                figure.addChildNode(node)
            }
        }

        // Curved neural threads: each link bows toward the core so it stays inside
        // the body instead of cutting straight across. Only cross-axis links carry
        // a small, slow travelling signal.
        func curve(_ a: SCNVector3, _ b: SCNVector3, _ steps: Int) -> [SCNVector3] {
            let mx = (Double(a.x) + Double(b.x)) / 2, my = (Double(a.y) + Double(b.y)) / 2, mz = (Double(a.z) + Double(b.z)) / 2
            let cx = mx * 0.35, cy = my, cz = mz * 0.35 + 0.03   // control pulled toward the spine
            var pts: [SCNVector3] = []
            for i in 0...steps {
                let t = Double(i) / Double(steps), u = 1 - t
                pts.append(v(u * u * Double(a.x) + 2 * u * t * cx + t * t * Double(b.x),
                             u * u * Double(a.y) + 2 * u * t * cy + t * t * Double(b.y),
                             u * u * Double(a.z) + 2 * u * t * cz + t * t * Double(b.z)))
            }
            return pts
        }
        func thread(_ p0: SCNVector3, _ p1: SCNVector3, _ radius: CGFloat, _ mat: SCNMaterial) {
            let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y), dz = Double(p1.z - p0.z)
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard d > 1e-6 else { return }
            let cyl = SCNCylinder(radius: radius, height: CGFloat(d)); cyl.radialSegmentCount = 5
            cyl.materials = [mat]
            let node = SCNNode(geometry: cyl)
            node.position = v((Double(p0.x) + Double(p1.x)) / 2, (Double(p0.y) + Double(p1.y)) / 2, (Double(p0.z) + Double(p1.z)) / 2)
            node.look(at: p1, up: v(0, 1, 0), localFront: v(0, 1, 0))
            node.renderingOrder = 11
            figure.addChildNode(node)
        }
        for e in links where linksAppear > 0.05 {
            guard let a = pos[e.a], let b = pos[e.b] else { continue }
            let col = e.cross ? UIColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 1) : UIColor(white: 0.8, alpha: 1)
            let mat = SCNMaterial(); mat.lightingModel = .constant
            mat.diffuse.contents = col; mat.emission.contents = col
            mat.emission.intensity = (e.cross ? 0.38 : 0.2) * linksAppear; mat.transparency = CGFloat(0.4 * linksAppear)
            let pts = curve(a, b, 12)
            let r: CGFloat = e.cross ? 0.0017 : 0.0011
            for i in 0..<(pts.count - 1) { thread(pts[i], pts[i + 1], r, mat) }

            if e.cross {
                let signal = ball(0.009); signal.segmentCount = 10
                let sm = SCNMaterial(); sm.lightingModel = .constant
                sm.diffuse.contents = col; sm.emission.contents = col; sm.emission.intensity = 0.9
                signal.materials = [sm]
                let pulse = SCNNode(geometry: signal); pulse.position = pts[0]; pulse.renderingOrder = 13
                pulse.opacity = 0.7
                let dur = Double.random(in: 3.0...5.5)
                let seg = dur / Double(pts.count - 1)
                var moves: [SCNAction] = pts.dropFirst().map { .move(to: $0, duration: seg) }
                moves.append(.move(to: pts[0], duration: 0))
                pulse.runAction(.sequence([.wait(duration: Double.random(in: 0...5)), .repeatForever(.sequence(moves))]))
                figure.addChildNode(pulse)
            }
        }

        // Only the body gently floats and tumbles in space — a weightless bob,
        // sway, and slow turn — independent of the (stationary) connectome nodes,
        // axes, and starfield. User drag-rotation still turns the whole `figure`.
        func drift(_ dx: Double, _ dy: Double, _ dz: Double, _ dur: Double) -> SCNAction {
            let a = SCNAction.moveBy(x: dx, y: dy, z: dz, duration: dur)
            a.timingMode = .easeInEaseOut
            return .repeatForever(.sequence([a, a.reversed()]))
        }
        bodyFloat.runAction(drift(0, 0.06, 0, 2.9))
        bodyFloat.runAction(drift(0.045, 0, 0.02, 3.8))
        let turn = SCNAction.rotateBy(x: 0.05, y: 0.14, z: 0, duration: 5.2)
        turn.timingMode = .easeInEaseOut
        bodyFloat.runAction(.repeatForever(.sequence([turn, turn.reversed()])))
        scene.rootNode.addChildNode(figure)
        return scene
    }
}
