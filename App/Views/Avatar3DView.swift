import SwiftUI
import SceneKit

/// A note placed in the 3D body (id + which axis region it belongs to).
struct GraphNode { let id: UUID; let axis: String; var label: String = "" }
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
    var regionMaturity: (String) -> Double = { _ in 1 }
    var nodes: [GraphNode]
    var links: [GraphEdge]
    /// 0→1 overall growth (fidelity): drives how materialized the body is.
    var maturity: Double
    /// 1 = default distance; larger = zoomed in. Driven by the +/- buttons and pinch.
    var zoom: Double
    /// Called with a note's id when its node is tapped.
    var onTapNode: ((UUID) -> Void)? = nil
    var onZoomChange: ((Double) -> Void)? = nil

    static let baseDistance: Float = 8.5
    static let minZoom: Double = 0.12
    static let maxZoom: Double = 30

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
        pan.maximumNumberOfTouches = 1     // leave two-finger gestures to the pinch
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        // Two-finger drag pans the camera so you can move to (and zoom into) any part,
        // not just the centre. Recognizes simultaneously with pinch.
        let camPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.camPan(_:)))
        camPan.minimumNumberOfTouches = 2
        camPan.maximumNumberOfTouches = 2
        camPan.delegate = context.coordinator
        view.addGestureRecognizer(camPan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        context.coordinator.builtMaturity = maturity
        context.coordinator.onTapNode = onTapNode
        context.coordinator.zoom = zoom
        context.coordinator.onZoomChange = onZoomChange
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTapNode = onTapNode
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.zoom = zoom
        // Rebuild when maturity changes (e.g. the "watch it grow" animation stepping
        // it) so the birth sequence plays; otherwise just track zoom.
        if abs(context.coordinator.builtMaturity - maturity) > 0.004 {
            view.scene = buildScene()
            view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
            context.coordinator.builtMaturity = maturity
            context.coordinator.labelsShown = !(zoom > 3)   // force re-apply below
        }
        view.pointOfView?.position.z = Self.baseDistance / Float(max(0.1, zoom))
        // Node name labels appear only when zoomed in.
        let showLabels = zoom > 3
        if showLabels != context.coordinator.labelsShown {
            context.coordinator.labelsShown = showLabels
            view.scene?.rootNode.enumerateChildNodes { node, _ in
                if node.name == "textlabel" { node.isHidden = !showLabels }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: SCNView?
        var builtMaturity: Double = -1
        var onTapNode: ((UUID) -> Void)?
        var onZoomChange: ((Double) -> Void)?
        var zoom: Double = 1
        var labelsShown = false
        private var pinchStartZoom: Double = 1

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Two-finger drag pans the camera (in its own plane), so you can bring any
        /// section to centre and zoom into it.
        @objc func camPan(_ g: UIPanGestureRecognizer) {
            guard let cam = view?.pointOfView else { return }
            let t = g.translation(in: view)
            let s = cam.position.z * 0.0016   // scale by distance so it feels 1:1
            cam.position.x -= Float(t.x) * s
            cam.position.y += Float(t.y) * s
            g.setTranslation(.zero, in: view)
        }
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let figure = view?.scene?.rootNode.childNode(withName: "figure", recursively: true) else { return }
            let t = g.translation(in: view)
            figure.eulerAngles.y += Float(t.x) * 0.01
            figure.eulerAngles.x = max(-1.2, min(1.2, figure.eulerAngles.x + Float(t.y) * 0.01))
            g.setTranslation(.zero, in: view)
        }
        /// Pinch to zoom: scale the committed zoom, move the camera for instant
        /// feedback, and report it back so the +/- buttons and clamp stay in sync.
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { pinchStartZoom = zoom }
            let z = min(Avatar3DView.maxZoom, max(Avatar3DView.minZoom, pinchStartZoom * Double(g.scale)))
            zoom = z
            view?.pointOfView?.position.z = Avatar3DView.baseDistance / Float(max(0.1, z))
            onZoomChange?(z)
        }
        /// Open the note nearest the tap (projected to screen) — checking both the
        /// nodes AND the link threads, so tapping anywhere on any connection (even a
        /// faint one) opens the nearer note.
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let scene = view.scene else { return }
            let p = g.location(in: view)
            var nodePt: [UUID: CGPoint] = [:]
            var links: [(UUID, UUID)] = []
            var best: (id: UUID, dist: CGFloat)?
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name else { return }
                if let id = UUID(uuidString: name) {
                    let s = view.projectPoint(node.worldPosition)
                    guard s.z > 0, s.z < 1 else { return }
                    let pt = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
                    nodePt[id] = pt
                    let d = hypot(pt.x - p.x, pt.y - p.y)
                    if d < 44, best == nil || d < best!.dist { best = (id, d) }
                } else if name.hasPrefix("link:") {
                    let parts = name.dropFirst(5).split(separator: ":")
                    if parts.count == 2, let a = UUID(uuidString: String(parts[0])), let b = UUID(uuidString: String(parts[1])) {
                        links.append((a, b))
                    }
                }
            }
            if let best { onTapNode?(best.id); return }
            // No node hit — see if the tap landed on a link thread.
            var bestLink: (id: UUID, dist: CGFloat)?
            for (a, b) in links {
                guard let pa = nodePt[a], let pb = nodePt[b] else { continue }
                let d = Self.distanceToSegment(p, pa, pb)
                guard d < 24 else { continue }
                let id = hypot(pa.x - p.x, pa.y - p.y) < hypot(pb.x - p.x, pb.y - p.y) ? a : b
                if bestLink == nil || d < bestLink!.dist { bestLink = (id, d) }
            }
            if let bestLink { onTapNode?(bestLink.id) }
        }

        /// Shortest distance from a point to a line segment, in screen space.
        private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-6 else { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
            t = max(0, min(1, t))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
    }

    private func region(_ axis: String) -> (Double, Double, Double) { GLTFBody.region(axis) }

    /// A soft radial glow image used as a galaxy/nebula sprite.
    private static func radialGlow(_ color: UIColor) -> UIImage {
        let size = 128
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let colors = [color.withAlphaComponent(0.95).cgColor,
                          color.withAlphaComponent(0.25).cgColor,
                          color.withAlphaComponent(0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.4, 1]) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.cgContext.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size / 2), options: [])
        }
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 64; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { let c = SCNCapsule(capRadius: r, height: h); c.radialSegmentCount = 32; return c }

        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera(); cam.camera?.fieldOfView = 42
        cam.camera?.zNear = 0.01           // allow zooming in close without clipping
        cam.camera?.zFar = 250
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
        // Your connectome (dust, nodes, links, organs) floats and rotates as its
        // own drifting entity too — independent of the fixed stars and galaxies.
        let connectomeFloat = SCNNode()
        figure.addChildNode(connectomeFloat)
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
        // Each region fades in on its OWN axis maturity, so parts form at different
        // rates and ungrown ones stay ethereal.
        let regionKeys = ["mind", "meaning", "heart", "spirit", "gut", "body"]
        let maxRegion = regionKeys.map { regionMaturity($0) }.max() ?? 0
        var bodySamples: [SCNVector3] = []
        if let loaded = GLTFBody.load(color: color, growth: growth, regionMaturity: regionMaturity) {
            if maxRegion > 0.02 { bodyFloat.addChildNode(loaded.node) }   // present once any part forms
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
        if !bodySamples.isEmpty {
            for i in 0..<460 {
                let target = bodySamples[(i * 89) % bodySamples.count]
                let ax = GLTFBody.axis(forX: Double(target.x), y: Double(target.y))
                // Each mote gathers onto the surface at ITS region's rate — so an
                // ungrown part stays a scattered, ethereal cloud (graph/space-like)
                // while a grown part condenses into solid form.
                let reg = smoothstep(0.0, 1.0, max(0, min(1, regionMaturity(ax))))
                let p = lerpV(diffusePoint(i), target, reg)
                let col = GLTFBody.blend(UIColor(white: 0.9, alpha: 1), color(ax), CGFloat(0.4 + matur * 0.5))
                let dot = ball(0.016); dot.segmentCount = 6
                let dm = SCNMaterial(); dm.lightingModel = .constant
                dm.diffuse.contents = col; dm.emission.contents = col; dm.emission.intensity = 0.9
                dm.transparency = CGFloat(0.18 + 0.42 * reg)   // faint when scattered, bright when gathered
                dm.writesToDepthBuffer = false
                dot.materials = [dm]
                let n = SCNNode(geometry: dot); n.position = p; n.renderingOrder = 5
                connectomeFloat.addChildNode(n)
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
            let star = ball(0.042); star.segmentCount = 4
            let sm = SCNMaterial(); sm.lightingModel = .constant
            let c = UIColor(white: b, alpha: 1)
            sm.diffuse.contents = c; sm.emission.contents = c; sm.emission.intensity = 0.6
            sm.transparency = CGFloat(0.3 + hrand(i, 15) * 0.45)
            sm.writesToDepthBuffer = false
            star.materials = [sm]
            let n = SCNNode(geometry: star)
            n.position = v(cos(phi) * s * r, u * r, sin(phi) * s * r)
            n.renderingOrder = -1
            figure.addChildNode(n)
        }

        // Real named constellations + galaxies in the far sky (billboarded so the
        // patterns stay readable), for a cosmos that feels earned, not random.
        func addConstellation(_ stars: [(Double, Double)], _ lines: [(Int, Int)], at: SCNVector3, scale: Double, tint: UIColor) {
            let group = SCNNode()
            // Just brighter stars in the constellation's shape — no drawn lines;
            // the eye fills in the pattern, like the real sky. (`lines` unused.)
            _ = lines
            for (sx, sy) in stars {
                let s = SCNSphere(radius: 0.1); s.segmentCount = 10
                let m = SCNMaterial(); m.lightingModel = .constant
                m.diffuse.contents = tint; m.emission.contents = tint; m.emission.intensity = 0.7
                m.writesToDepthBuffer = false; s.materials = [m]
                let n = SCNNode(geometry: s)
                n.position = v((sx - 0.5) * scale, (sy - 0.5) * scale, 0)
                group.addChildNode(n)
            }
            group.position = at
            group.constraints = [SCNBillboardConstraint()]
            group.renderingOrder = -1
            figure.addChildNode(group)
        }
        func addGalaxy(at: SCNVector3, scale: Double, tint: UIColor, elong: Double, alpha: CGFloat) {
            let plane = SCNPlane(width: CGFloat(scale * elong), height: CGFloat(scale))
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = Self.radialGlow(tint)
            m.blendMode = .add; m.transparency = alpha; m.writesToDepthBuffer = false; m.isDoubleSided = true
            plane.materials = [m]
            let n = SCNNode(geometry: plane); n.position = at
            n.constraints = [SCNBillboardConstraint()]; n.renderingOrder = -2
            figure.addChildNode(n)
        }
        let starWhite = UIColor(red: 0.9, green: 0.93, blue: 1.0, alpha: 1)
        // Orion
        addConstellation([(0.28, 0.72), (0.60, 0.76), (0.40, 0.50), (0.47, 0.52), (0.55, 0.55), (0.34, 0.20), (0.62, 0.20)],
                         [(0, 1), (0, 2), (1, 4), (2, 3), (3, 4), (2, 5), (4, 6)],
                         at: v(-11, 5, -16), scale: 6, tint: starWhite)
        // Big Dipper
        addConstellation([(0.12, 0.72), (0.14, 0.52), (0.34, 0.48), (0.36, 0.66), (0.56, 0.70), (0.74, 0.74), (0.92, 0.66)],
                         [(0, 1), (1, 2), (2, 3), (3, 0), (3, 4), (4, 5), (5, 6)],
                         at: v(12, 10, -16), scale: 7, tint: starWhite)
        // Cassiopeia (W)
        addConstellation([(0.1, 0.4), (0.3, 0.72), (0.5, 0.46), (0.7, 0.76), (0.9, 0.5)],
                         [(0, 1), (1, 2), (2, 3), (3, 4)],
                         at: v(10, -11, -17), scale: 6, tint: starWhite)
        // Southern Cross
        addConstellation([(0.5, 0.92), (0.5, 0.08), (0.18, 0.5), (0.82, 0.55)],
                         [(0, 1), (2, 3)],
                         at: v(-12, -8, -15), scale: 4.5, tint: starWhite)
        // A couple of distant galaxies (edge-on blue spiral, round pink nebula)
        addGalaxy(at: v(15, -5, -25), scale: 7, tint: UIColor(red: 0.78, green: 0.85, blue: 1.0, alpha: 1), elong: 1.8, alpha: 0.6)
        addGalaxy(at: v(-11, 11, -24), scale: 5, tint: UIColor(red: 1.0, green: 0.72, blue: 0.86, alpha: 1), elong: 1.0, alpha: 0.55)

        // Ambience: occasional comets streak across the far field, plus a lone
        // satellite drifting by with a blinking beacon.
        func addComet(delay: Double, period: Double, from: SCNVector3, to: SCNVector3, headR: Double, color: UIColor) {
            let comet = SCNNode()
            func glow(_ r: Double, _ intensity: CGFloat, _ alpha: CGFloat) -> SCNNode {
                let s = SCNSphere(radius: r); s.segmentCount = 8
                let m = SCNMaterial(); m.lightingModel = .constant
                m.diffuse.contents = color; m.emission.contents = color; m.emission.intensity = intensity
                m.transparency = alpha; m.writesToDepthBuffer = false
                s.materials = [m]
                return SCNNode(geometry: s)
            }
            comet.addChildNode(glow(headR, 1.0, 1))
            let dx = Double(from.x - to.x), dy = Double(from.y - to.y), dz = Double(from.z - to.z)
            let len = max(1e-4, (dx * dx + dy * dy + dz * dz).squareRoot())
            for k in 1...7 {
                let f = 1 - Double(k) / 8
                let t = glow(headR * f, 0.85, CGFloat(0.8 * f))
                t.position = v(dx / len * Double(k) * headR * 1.5, dy / len * Double(k) * headR * 1.5, dz / len * Double(k) * headR * 1.5)
                comet.addChildNode(t)
            }
            comet.position = from; comet.opacity = 0; comet.renderingOrder = 0
            comet.runAction(.repeatForever(.sequence([
                .wait(duration: delay),
                .fadeOpacity(to: 1, duration: 0.25),
                .move(to: to, duration: 2.4),
                .fadeOpacity(to: 0, duration: 0.25),
                .move(to: from, duration: 0),
                .wait(duration: period),
            ])))
            figure.addChildNode(comet)
        }
        addComet(delay: 4, period: 18, from: v(-17, 9, -10), to: v(18, -4, -13), headR: 0.22, color: UIColor(red: 0.82, green: 0.9, blue: 1.0, alpha: 1))
        addComet(delay: 13, period: 25, from: v(17, 12, -14), to: v(-16, -7, -9), headR: 0.17, color: UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1))

        do {   // satellite
            let sat = SCNNode()
            let bodyMat = SCNMaterial(); bodyMat.lightingModel = .physicallyBased
            bodyMat.diffuse.contents = UIColor(white: 0.55, alpha: 1); bodyMat.metalness.contents = 0.7; bodyMat.roughness.contents = 0.4
            let body = SCNBox(width: 0.14, height: 0.08, length: 0.3, chamferRadius: 0.02); body.materials = [bodyMat]
            sat.addChildNode(SCNNode(geometry: body))
            let panelMat = SCNMaterial(); panelMat.lightingModel = .constant
            panelMat.diffuse.contents = UIColor(red: 0.22, green: 0.32, blue: 0.6, alpha: 1)
            panelMat.emission.contents = UIColor(red: 0.22, green: 0.32, blue: 0.6, alpha: 1); panelMat.emission.intensity = 0.4
            for side in [-1.0, 1.0] {
                let panel = SCNBox(width: 0.32, height: 0.01, length: 0.16, chamferRadius: 0); panel.materials = [panelMat]
                let pn = SCNNode(geometry: panel); pn.position = v(side * 0.28, 0, 0); sat.addChildNode(pn)
            }
            let beacon = SCNSphere(radius: 0.03); beacon.segmentCount = 6
            let bm = SCNMaterial(); bm.lightingModel = .constant; bm.diffuse.contents = UIColor.red; bm.emission.contents = UIColor.red; bm.emission.intensity = 1
            beacon.materials = [bm]
            let bn = SCNNode(geometry: beacon); bn.position = v(0, 0.07, 0)
            bn.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.1), .wait(duration: 1.0), .fadeOpacity(to: 1, duration: 0.1), .wait(duration: 1.0)])))
            sat.addChildNode(bn)
            sat.position = v(-14, -9, -12)
            sat.runAction(.repeatForever(.sequence([.move(to: v(15, 10, -16), duration: 60), .move(to: v(-14, -9, -12), duration: 0)])))
            sat.runAction(.repeatForever(.rotateBy(x: 0, y: .pi, z: 0.2, duration: 30)))
            figure.addChildNode(sat)
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
            connectomeFloat.addChildNode(organ)
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
                let col = color(gn.axis)
                // Your nodes read clearly bigger/brighter than the decorative sky
                // stars — they're *you*, not scenery. Grows with connections.
                let r = min(0.05, 0.02 + 0.011 * Double(degree[gn.id] ?? 0).squareRoot())
                let s = ball(r); s.segmentCount = 14
                let m = SCNMaterial(); m.lightingModel = .constant
                m.diffuse.contents = col; m.emission.contents = col
                m.emission.intensity = 1.0; m.transparency = CGFloat(0.92 * nodesAppear)
                s.materials = [m]
                let node = SCNNode(geometry: s); node.position = p; node.renderingOrder = 12
                node.name = gn.id.uuidString    // tap target → opens this note
                connectomeFloat.addChildNode(node)
                // A small name label that only shows when you zoom in (toggled in
                // updateUIView). Billboarded so it always faces you.
                if !gn.label.isEmpty {
                    let txt = SCNText(string: gn.label, extrusionDepth: 0)
                    txt.font = UIFont.systemFont(ofSize: 6, weight: .semibold)
                    txt.flatness = 0.4
                    let tm = SCNMaterial(); tm.lightingModel = .constant
                    tm.diffuse.contents = UIColor.white; tm.emission.contents = UIColor.white
                    tm.writesToDepthBuffer = false
                    txt.materials = [tm]
                    let label = SCNNode(geometry: txt)
                    label.name = "textlabel"
                    label.scale = SCNVector3(0.006, 0.006, 0.006)
                    let (minB, maxB) = txt.boundingBox
                    label.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, minB.y, 0)
                    label.position = v(Double(p.x), Double(p.y) + Double(r) + 0.03, Double(p.z))
                    label.constraints = [SCNBillboardConstraint()]
                    label.renderingOrder = 20
                    label.isHidden = true
                    connectomeFloat.addChildNode(label)
                }
                // Soft glow halo so a node reads as a living orb, not a pinprick.
                let halo = ball(r * 2.7); halo.segmentCount = 12
                let hm = SCNMaterial(); hm.lightingModel = .constant
                hm.diffuse.contents = col; hm.emission.contents = col; hm.emission.intensity = 0.7
                hm.transparency = CGFloat(0.2 * nodesAppear); hm.blendMode = .add; hm.writesToDepthBuffer = false
                halo.materials = [hm]
                let haloNode = SCNNode(geometry: halo); haloNode.position = p; haloNode.renderingOrder = 11
                connectomeFloat.addChildNode(haloNode)
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
        // Faint web threads: thin straight cylinders between connected nodes (line
        // primitives didn't render reliably). Same-axis dim, cross-axis bright.
        func thread(_ p0: SCNVector3, _ p1: SCNVector3, _ radius: CGFloat, _ mat: SCNMaterial, name: String? = nil) {
            let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y), dz = Double(p1.z - p0.z)
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard d > 1e-6 else { return }
            let cyl = SCNCylinder(radius: radius, height: CGFloat(d)); cyl.radialSegmentCount = 4
            cyl.materials = [mat]
            let node = SCNNode(geometry: cyl)
            node.name = name
            node.position = v((Double(p0.x) + Double(p1.x)) / 2, (Double(p0.y) + Double(p1.y)) / 2, (Double(p0.z) + Double(p1.z)) / 2)
            node.look(at: p1, up: v(0, 1, 0), localFront: v(0, 1, 0))
            node.renderingOrder = 11
            connectomeFloat.addChildNode(node)
        }
        for e in links where linksAppear > 0.05 {
            guard let a = pos[e.a], let b = pos[e.b] else { continue }
            let col = e.cross ? UIColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 1) : UIColor(white: 0.78, alpha: 1)
            let mat = SCNMaterial(); mat.lightingModel = .constant
            mat.diffuse.contents = col; mat.emission.contents = col
            mat.emission.intensity = (e.cross ? 0.5 : 0.32) * linksAppear
            mat.transparency = CGFloat((e.cross ? 0.6 : 0.42) * linksAppear)
            mat.writesToDepthBuffer = false
            thread(a, b, e.cross ? 0.0016 : 0.0011, mat, name: "link:\(e.a.uuidString):\(e.b.uuidString)")
        }

        // Cross-axis threads carry a small travelling signal along the strand.
        for e in links where linksAppear > 0.05 && e.cross {
            guard let a = pos[e.a], let b = pos[e.b] else { continue }
            let steps = 8
            let pts = (0...steps).map { i -> SCNVector3 in
                let t = Double(i) / Double(steps)
                return v(Double(a.x) + (Double(b.x) - Double(a.x)) * t,
                         Double(a.y) + (Double(b.y) - Double(a.y)) * t,
                         Double(a.z) + (Double(b.z) - Double(a.z)) * t)
            }
            let col = UIColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 1)
            let signal = ball(0.008); signal.segmentCount = 10
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
            connectomeFloat.addChildNode(pulse)
        }

        // The body and the connectome each gently float and tumble in space — a
        // weightless bob, sway, and slow turn — independent of each other and of
        // the fixed stars/galaxies. User drag-rotation still turns the whole scene.
        func drift(_ dx: Double, _ dy: Double, _ dz: Double, _ dur: Double) -> SCNAction {
            let a = SCNAction.moveBy(x: dx, y: dy, z: dz, duration: dur)
            a.timingMode = .easeInEaseOut
            return .repeatForever(.sequence([a, a.reversed()]))
        }
        func tumble(_ x: Double, _ y: Double, _ dur: Double) -> SCNAction {
            let t = SCNAction.rotateBy(x: x, y: y, z: 0, duration: dur)
            t.timingMode = .easeInEaseOut
            return .repeatForever(.sequence([t, t.reversed()]))
        }
        bodyFloat.runAction(drift(0, 0.06, 0, 2.9))
        bodyFloat.runAction(drift(0.045, 0, 0.02, 3.8))
        bodyFloat.runAction(tumble(0.05, 0.14, 5.2))
        // Connectome drifts on its own, slightly different phase/rate.
        connectomeFloat.runAction(drift(0, 0.05, 0.02, 3.5))
        connectomeFloat.runAction(drift(0.05, 0, 0, 4.4))
        connectomeFloat.runAction(tumble(-0.04, 0.11, 6.3))
        scene.rootNode.addChildNode(figure)
        return scene
    }
}
