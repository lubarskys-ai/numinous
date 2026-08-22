import SwiftUI
import SceneKit

/// A note placed in the 3D body (id + which axis region it belongs to).
struct GraphNode { let id: UUID; let axis: String; var label: String = "" }
/// A scored connection between two placed notes.
struct GraphEdge { let a: UUID; let b: UUID; let cross: Bool }
/// A node's name projected to 2D screen space, for a lightweight SwiftUI label overlay
/// (drawn only when zoomed in — no memory-heavy 3D text).
struct NodeLabel: Identifiable { let id: UUID; let text: String; let point: CGPoint }

/// A request to open the avatar/connectome spotlighting node(s): one note (with its
/// neighbours) or a whole folder's set of nodes (even the unlinked ones).
struct AvatarFocus: Equatable {
    let label: String        // banner text ("2026-08-16" or "golf clubs · 5")
    let ids: [UUID]          // the node(s) to spotlight
    var expandNeighbors: Bool = false   // also light up each node's direct connections
}

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
    /// Reports on-screen positions of node names near the centre while zoomed in, so a 2D
    /// SwiftUI layer can draw labels without any 3D text geometry.
    var onLabels: (([NodeLabel]) -> Void)? = nil
    /// Reports the focused node's name (nil when focus clears), so a banner can show which
    /// node's connections are spotlighted.
    var onFocus: ((String?) -> Void)? = nil
    /// Programmatic focus: spotlight a note's connections or a whole folder's nodes (opened
    /// from a note/folder). Applied once the scene is built.
    var focusRequest: AvatarFocus? = nil

    // A long "telephoto" rig: the camera sits far back with a narrow field of view, which
    // flattens perspective so foreground and background nodes zoom at nearly the same rate
    // (near-Obsidian consistency) and the camera stops flying past near nodes so soon.
    // Kept just inside the star shell (radius 26) so the cosmos still surrounds you.
    static let baseDistance: Float = 23
    /// Orthographic half-height (world units) at zoom 1 — matches the old telephoto framing.
    static let baseOrtho: Double = 3.2
    static let minZoom: Double = 0.12
    static let maxZoom: Double = 120

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
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
        context.coordinator.onLabels = onLabels
        context.coordinator.onFocus = onFocus
        view.delegate = context.coordinator     // per-frame hook for projecting labels
        buildSceneAsync(into: view, context.coordinator)   // build off-main so opening stays smooth
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onTapNode = onTapNode
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.onLabels = onLabels
        context.coordinator.onFocus = onFocus
        context.coordinator.zoom = zoom
        context.coordinator.viewSize = view.bounds.size
        if focusRequest != context.coordinator.appliedFocus { context.coordinator.applyFocus(focusRequest) }
        // Rebuild when maturity changes (e.g. the "watch it grow" animation stepping
        // it) so the birth sequence plays; otherwise just track zoom.
        if abs(context.coordinator.builtMaturity - maturity) > 0.004 {
            context.coordinator.builtMaturity = maturity   // set now so we don't re-trigger mid-build
            buildSceneAsync(into: view, context.coordinator)
        }
        // Orthographic zoom: scale the viewport, never dolly the camera — so foreground and
        // background nodes zoom identically (no parallax) and the camera never flies past
        // near nodes. This is what makes it behave like Obsidian's flat graph.
        view.pointOfView?.camera?.orthographicScale = Self.baseOrtho / max(0.1, zoom)
        // Freeze the drifting connectome (and body) while zoomed in so the labels hold
        // still and stay readable; resume the gentle motion when you zoom back out.
        let frozen = zoom > 6
        context.coordinator.connectomeNode?.isPaused = frozen
        context.coordinator.bodyFloatNode?.isPaused = frozen
        // Node points hold a constant on-screen size automatically (screen-space point
        // radius), so the only thing to re-scale on zoom is the link threads — thin them
        // as you zoom in so a deep zoom reveals structure instead of fat tubes.
        let f = Float(1.0 / max(1.0, zoom))
        if abs(f - context.coordinator.lastNodeScale) > 0.002 {
            context.coordinator.lastNodeScale = f
            view.scene?.rootNode.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix("link:") == true {
                    node.scale = SCNVector3(f, 1, f)   // thin the thread, keep its length
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        weak var view: SCNView?
        var builtMaturity: Double = -1
        var buildGeneration = 0
        var onTapNode: ((UUID) -> Void)?
        var onZoomChange: ((Double) -> Void)?
        var onLabels: (([NodeLabel]) -> Void)?
        var zoom: Double = 1
        var lastNodeScale: Float = -1
        private var pinchStartZoom: Double = 1
        // Nodes are now drawn as batched point clouds (no per-note SCNNode), so tap
        // hit-testing works off these stored local positions, projected through the
        // connectome node's current (animated) world transform.
        var nodeHitTargets: [(id: UUID, local: SCNVector3)] = []
        var labelTargets: [(id: UUID, local: SCNVector3, text: String)] = []
        var viewSize: CGSize = .zero
        private var lastLabelTime: TimeInterval = 0
        private var labelsEmpty = true
        weak var connectomeNode: SCNNode?
        weak var bodyFloatNode: SCNNode?
        // Focus mode: tap a node to spotlight just its connections (dim the rest); tap it
        // again to open the note; tap empty space to clear.
        var focusedNode: UUID?         // single node the pill's "tap again to open" targets
        var appliedFocus: AvatarFocus? // last programmatic focus applied (nil = none)
        var pendingFocus: AvatarFocus? // a focus requested before the scene finished building
        var focusIDs: Set<UUID> = []   // all spotlighted nodes (for scoped labels)
        var nodeName: [UUID: String] = [:]
        var onFocus: ((String?) -> Void)?
        private var highlightOverlay: SCNNode?
        private var dimmed: [SCNNode] = []

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Once per rendered frame (throttled): when zoomed in, project the node names near
        /// screen centre and hand a small set to the 2D SwiftUI overlay. Labels are drawn in
        /// SwiftUI, never as SceneKit text, so they add no scene memory.
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // Labels show either (a) in focus mode — ONLY the focused node + its neighbours, at
            // any zoom — or (b) otherwise, the names nearest screen centre while zoomed in.
            guard let view, viewSize.width > 1, (focusedNode != nil || zoom > 6) else {
                if !labelsEmpty { labelsEmpty = true; DispatchQueue.main.async { self.onLabels?([]) } }
                return
            }
            guard time - lastLabelTime > 0.11 else { return }   // ~9 Hz is plenty for labels
            lastLabelTime = time
            let sz = viewSize
            let connectome = connectomeNode?.presentation
            if focusedNode != nil {
                var out: [NodeLabel] = []
                for (id, local, text) in labelTargets where focusIDs.contains(id) {
                    let wp = connectome?.convertPosition(local, to: nil) ?? local
                    let s = view.projectPoint(wp)
                    guard s.z > 0, s.z < 1 else { continue }
                    out.append(NodeLabel(id: id, text: text, point: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))))
                }
                labelsEmpty = out.isEmpty
                DispatchQueue.main.async { self.onLabels?(out) }
                return
            }
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            // Only label nodes actually near the middle of what you're looking at, so a node
            // you've zoomed past (now off to the edge or off-screen) drops its label instead
            // of lingering. The window tightens the further you zoom in.
            let maxR = min(sz.width, sz.height) * (zoom >= 14 ? 0.28 : 0.4)
            var cands: [(NodeLabel, CGFloat)] = []
            for (id, local, text) in labelTargets {
                let wp = connectome?.convertPosition(local, to: nil) ?? local
                let s = view.projectPoint(wp)
                guard s.z > 0, s.z < 1 else { continue }
                let pt = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
                guard pt.x >= 0, pt.y >= 0, pt.x <= sz.width, pt.y <= sz.height else { continue }
                let d = hypot(pt.x - center.x, pt.y - center.y)
                guard d <= maxR else { continue }
                cands.append((NodeLabel(id: id, text: text, point: pt), d))
            }
            let nearest = cands.sorted { $0.1 < $1.1 }.prefix(10).map(\.0)
            labelsEmpty = nearest.isEmpty
            DispatchQueue.main.async { self.onLabels?(nearest) }
        }

        /// Two-finger drag pans the camera (in its own plane), so you can bring any
        /// section to centre and zoom into it.
        @objc func camPan(_ g: UIPanGestureRecognizer) {
            guard let cam = view?.pointOfView else { return }
            let t = g.translation(in: view)
            // Orthographic: on-screen size tracks orthographicScale, so pan by that to feel 1:1.
            let s = Float(cam.camera?.orthographicScale ?? Avatar3DView.baseOrtho) * 0.0043
            cam.position.x -= Float(t.x) * s
            cam.position.y += Float(t.y) * s
            g.setTranslation(.zero, in: view)
        }
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let figure = view?.scene?.rootNode.childNode(withName: "figure", recursively: true) else { return }
            let t = g.translation(in: view)
            // Gentle rotation — a drag turns the scene about half as fast as the
            // finger travels, so it's easy to inspect without whipping around.
            figure.eulerAngles.y += Float(t.x) * 0.005
            figure.eulerAngles.x = max(-1.2, min(1.2, figure.eulerAngles.x + Float(t.y) * 0.005))
            g.setTranslation(.zero, in: view)
        }
        /// Pinch to zoom: scale the committed zoom, move the camera for instant
        /// feedback, and report it back so the +/- buttons and clamp stay in sync.
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { pinchStartZoom = zoom }
            let z = min(Avatar3DView.maxZoom, max(Avatar3DView.minZoom, pinchStartZoom * Double(g.scale)))
            zoom = z
            view?.pointOfView?.camera?.orthographicScale = Avatar3DView.baseOrtho / max(0.1, z)
            onZoomChange?(z)
        }
        /// Open the note nearest the tap (projected to screen) — checking both the
        /// nodes AND the link threads, so tapping anywhere on any connection (even a
        /// faint one) opens the nearer note.
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let scene = view.scene else { return }
            let p = g.location(in: view)
            // Nodes are a batched point cloud now, so hit-test the stored local positions:
            // convert each to world space through the connectome's CURRENT (animated)
            // presentation node, then project to screen. Let SceneKit do the matrix math.
            let connectome = connectomeNode?.presentation
            var nodePt: [UUID: CGPoint] = [:]
            var best: (id: UUID, dist: CGFloat)?
            for (id, local) in nodeHitTargets {
                let wp = connectome?.convertPosition(local, to: nil) ?? local
                let s = view.projectPoint(wp)
                guard s.z > 0, s.z < 1 else { continue }
                let pt = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
                nodePt[id] = pt
                let d = hypot(pt.x - p.x, pt.y - p.y)
                if d < 44, best == nil || d < best!.dist { best = (id, d) }
            }
            // Link threads are still individual nodes named "link:a:b".
            var links: [(UUID, UUID)] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name, name.hasPrefix("link:") else { return }
                let parts = name.dropFirst(5).split(separator: ":")
                if parts.count == 2, let a = UUID(uuidString: String(parts[0])), let b = UUID(uuidString: String(parts[1])) {
                    links.append((a, b))
                }
            }
            if let best {
                if focusedNode == best.id { onTapNode?(best.id) }   // second tap on the same node opens it
                else { focus(best.id, positions: Dictionary(nodeHitTargets.map { ($0.id, $0.local) }, uniquingKeysWith: { a, _ in a }), links: links) }
                return
            }
            // No node hit — see if the tap landed on a link thread.
            var bestLink: (id: UUID, dist: CGFloat)?
            for (a, b) in links {
                guard let pa = nodePt[a], let pb = nodePt[b] else { continue }
                let d = Self.distanceToSegment(p, pa, pb)
                guard d < 24 else { continue }
                let id = hypot(pa.x - p.x, pa.y - p.y) < hypot(pb.x - p.x, pb.y - p.y) ? a : b
                if bestLink == nil || d < bestLink!.dist { bestLink = (id, d) }
            }
            if let bestLink { focus(bestLink.id, positions: Dictionary(nodeHitTargets.map { ($0.id, $0.local) }, uniquingKeysWith: { a, _ in a }), links: links); return }
            clearFocus()   // tapped empty space → clear the spotlight
        }

        /// Spotlight one node + its neighbours (a tap, or a single-note focus).
        func focus(_ id: UUID, positions: [UUID: SCNVector3], links: [(UUID, UUID)]) {
            var set: Set<UUID> = [id]
            for (a, b) in links { if a == id { set.insert(b) } else if b == id { set.insert(a) } }
            focusSet(set, label: nodeName[id] ?? "", tapTarget: id, positions: positions, links: links)
        }

        /// Spotlight an arbitrary SET of nodes: dim the whole connectome, draw bright dots for
        /// each node in the set, bright threads for links WITHIN the set, and label only these.
        /// Serves both a single node (+ neighbours) and a whole folder's nodes (even unlinked).
        func focusSet(_ ids: Set<UUID>, label: String, tapTarget: UUID?,
                      positions: [UUID: SCNVector3], links: [(UUID, UUID)]) {
            guard let connectome = connectomeNode, !ids.isEmpty else { return }
            clearHighlight()
            focusedNode = tapTarget
            focusIDs = ids
            dimmed = connectome.childNodes
            for c in dimmed { c.opacity = 0.14 }
            let overlay = SCNNode()
            func brightDot(_ p: SCNVector3, _ r: CGFloat, _ color: UIColor) {
                let s = SCNSphere(radius: r); s.segmentCount = 12
                let m = SCNMaterial(); m.lightingModel = .constant
                m.diffuse.contents = color; m.emission.contents = color; m.emission.intensity = 1
                m.writesToDepthBuffer = false; s.materials = [m]
                let n = SCNNode(geometry: s); n.position = p; n.renderingOrder = 30
                overlay.addChildNode(n)
            }
            func brightThread(_ a: SCNVector3, _ b: SCNVector3) {
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
                let d = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard d > 1e-5 else { return }
                let cyl = SCNCylinder(radius: 0.004, height: CGFloat(d)); cyl.radialSegmentCount = 6
                let m = SCNMaterial(); m.lightingModel = .constant
                let col = UIColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1)
                m.diffuse.contents = col; m.emission.contents = col; m.emission.intensity = 0.9
                m.writesToDepthBuffer = false; cyl.materials = [m]
                let n = SCNNode(geometry: cyl)
                n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
                n.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
                n.renderingOrder = 29
                overlay.addChildNode(n)
            }
            for (a, b) in links where ids.contains(a) && ids.contains(b) {
                if let pa = positions[a], let pb = positions[b] { brightThread(pa, pb) }
            }
            for id in ids {
                guard let p = positions[id] else { continue }
                let isTap = id == tapTarget
                brightDot(p, isTap ? 0.05 : 0.03, isTap ? .white : UIColor(white: 0.96, alpha: 1))
            }
            connectome.addChildNode(overlay)
            highlightOverlay = overlay
            onFocus?(label)
        }

        /// Spotlight a note or folder by request (not a tap). Defers until the scene is built.
        func applyFocus(_ f: AvatarFocus?) {
            appliedFocus = f
            guard let f else { clearFocus(); return }
            guard let view, !nodeHitTargets.isEmpty else { pendingFocus = f; return }
            var links: [(UUID, UUID)] = []
            view.scene?.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name, name.hasPrefix("link:") else { return }
                let parts = name.dropFirst(5).split(separator: ":")
                if parts.count == 2, let a = UUID(uuidString: String(parts[0])), let b = UUID(uuidString: String(parts[1])) {
                    links.append((a, b))
                }
            }
            let positions = Dictionary(nodeHitTargets.map { ($0.id, $0.local) }, uniquingKeysWith: { a, _ in a })
            var set = Set(f.ids)
            if f.expandNeighbors {
                for (a, b) in links {
                    if f.ids.contains(a) { set.insert(b) }
                    if f.ids.contains(b) { set.insert(a) }
                }
            }
            focusSet(set, label: f.label, tapTarget: f.ids.count == 1 ? f.ids.first : nil,
                     positions: positions, links: links)
        }

        func clearFocus() {
            guard focusedNode != nil || highlightOverlay != nil else { return }
            focusedNode = nil; focusIDs = []
            clearHighlight()
            onFocus?(nil)
        }

        /// Reset focus refs without a callback — used when the whole scene is rebuilt.
        func resetFocusState() { focusedNode = nil; focusIDs = []; highlightOverlay = nil; dimmed = [] }

        private func clearHighlight() {
            highlightOverlay?.removeFromParentNode(); highlightOverlay = nil
            for c in dimmed { c.opacity = 1 }
            dimmed = []
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

    /// One batched point-cloud geometry for many same-color nodes — a single draw call
    /// for the whole group instead of an SCNNode per note. Screen-space point radius
    /// holds a constant on-screen dot size at any zoom (Obsidian-like). `additive` draws
    /// a soft glow layer (larger, low-opacity, additive blend) so a crisp core over an
    /// additive halo reads as a glowing orb — the batched, HDR-free stand-in for halos.
    private func pointCloud(_ pts: [SCNVector3], color: UIColor, screenRadius: CGFloat,
                            opacity: CGFloat, additive: Bool = false) -> SCNNode {
        let source = SCNGeometrySource(vertices: pts)
        let indices = (0..<pts.count).map { UInt32($0) }
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: data, primitiveType: .point,
                                         primitiveCount: pts.count,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        element.pointSize = screenRadius
        element.minimumPointScreenSpaceRadius = screenRadius
        element.maximumPointScreenSpaceRadius = screenRadius
        let geo = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = additive ? 0.7 : 1.0
        m.transparency = opacity
        if additive { m.blendMode = .add }
        m.writesToDepthBuffer = false
        geo.materials = [m]
        return SCNNode(geometry: geo)
    }

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

    /// The result of a scene build — the scene plus the hit/label data and the two moving
    /// nodes the coordinator needs. Returned (not written to the coordinator) so the whole
    /// build can run OFF the main thread; the caller wires these up on the main thread.
    struct BuiltAvatarScene {
        let scene: SCNScene
        let hits: [(id: UUID, local: SCNVector3)]
        let labels: [(id: UUID, local: SCNVector3, text: String)]
        let connectome: SCNNode
        let body: SCNNode
    }

    private func buildScene() -> BuiltAvatarScene {
        let scene = SCNScene()
        func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(Float(x), Float(y), Float(z)) }
        func ball(_ r: Double) -> SCNSphere { let s = SCNSphere(radius: r); s.segmentCount = 64; return s }
        func limb(_ r: Double, _ h: Double) -> SCNCapsule { let c = SCNCapsule(capRadius: r, height: h); c.radialSegmentCount = 32; return c }

        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true      // flat: no parallax, no fly-past
        cam.camera?.orthographicScale = Self.baseOrtho
        cam.camera?.zNear = 0.01
        cam.camera?.zFar = 250
        cam.position = v(0, 0.05, Double(Self.baseDistance))
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
            // Only solidify in the upper maturity range — invisible (stardust) below.
            let mr = max(0, min(1, regionMaturity(axis)))
            let form = mr <= 0.4 ? 0.0 : (mr - 0.4) / 0.6
            guard form > 0.01 else { return }
            let g = min(1, max(0, growth(axis)))
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = blend(greyBase, color(axis), g * 0.85).withAlphaComponent(CGFloat(0.5 * form))
            m.roughness.contents = 0.5
            m.emission.contents = color(axis); m.emission.intensity = 0.03 + 0.3 * g
            m.transparency = CGFloat(form)
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
        // The graph (nodes + links) is ALWAYS visible — it's the avatar's everyday
        // form, an Obsidian-like web. Only the solid human body is gated by maturity.
        let nodesAppear = 1.0
        let linksAppear = 1.0

        // The real sculpted body, re-skinned grey→color; primitives if it can't load.
        // Each region fades in on its OWN axis maturity, so parts form at different
        // rates and ungrown ones stay ethereal.
        let regionKeys = ["mind", "meaning", "heart", "spirit", "gut", "body"]
        let maxRegion = regionKeys.map { regionMaturity($0) }.max() ?? 0
        let dominantAxis = regionKeys.max { growth($0) < growth($1) } ?? "spirit"
        var bodySamples: [SCNVector3] = []
        // Prefer the RIGGED, animated body (Mixamo → USDZ) once the form emerges — it keeps
        // its skeleton + breathing/idle animation. Falls back to the static sculpted mesh.
        var usedRigged = false
        if maxRegion > 0.62,
           let rigged = RiggedBody.load(dominantColor: color(dominantAxis), growth01: growth(dominantAxis), maturity: matur) {
            bodyFloat.addChildNode(rigged)
            usedRigged = true
        }
        if let loaded = GLTFBody.load(color: color, growth: growth, regionMaturity: regionMaturity) {
            if maxRegion > 0.62 && !usedRigged { bodyFloat.addChildNode(loaded.node) }  // solid body only LATE
            bodySamples = loaded.samples   // static mesh surface points feed the stardust gather
        } else if !usedRigged {
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
            for i in 0..<240 {
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
        for i in 0..<360 {
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

        // ── Organs: the developmental stage BETWEEN the loose graph and the solid body.
        // Each axis's organ mesh swells in as that region matures (grey → axis-color by
        // growth), glows while it's the leading edge of growth, then dissolves as the
        // sculpted body takes over — so the avatar visibly forms organ-by-organ, not all
        // at once. Nodes still cluster inside each organ (organSample), so the mesh and the
        // connectome read as one thing.
        let organAxes = ["mind", "meaning", "heart", "spirit", "gut"]
        for axisKey in organAxes {
            let mr = max(0, min(1, regionMaturity(axisKey)))
            let organIn = smoothstep(0.12, 0.5, mr)     // materialize across the mid band
            let organOut = smoothstep(0.62, 0.95, mr)   // then give way to the solid body
            let alpha = organIn * (1 - organOut)
            guard alpha > 0.02 else { continue }
            let g = min(1, max(0, growth(axisKey)))
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = blend(greyBase, color(axisKey), g * 0.85).withAlphaComponent(CGFloat(0.4 * alpha))
            m.emission.contents = color(axisKey)
            m.emission.intensity = CGFloat((0.12 + 0.45 * g) * alpha)
            m.roughness.contents = 0.55
            m.transparency = CGFloat(alpha)
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            let organ = organNode(axisKey, axisKey == "spirit" ? 0.10 : 0.14, m)
            let c = region(axisKey)
            organ.position = v(c.0, c.1, c.2)
            organ.renderingOrder = 2
            bodyFloat.addChildNode(organ)
        }

        // ── Force-directed graph layout (Obsidian-style). Run Fruchterman–Reingold
        // only on the LINKED nodes (fast even with thousands of files), then scatter
        // the unlinked files on a surrounding shell so every file still shows.
        let ids = nodes.map(\.id)
        let idSet = Set(ids)
        let linkedSet: Set<UUID> = Set(links.flatMap { [$0.a, $0.b] }).intersection(idSet)
        let fdIds = ids.filter { linkedSet.contains($0) }
        var fx = [UUID: Double](), fy = [UUID: Double](), fz = [UUID: Double]()
        for (i, id) in fdIds.enumerated() {
            let a = Double(abs(id.hashValue) % 997) / 997 * 2 * .pi
            let b = Double(i) * 2.399963
            fx[id] = 1.2 * cos(a) * sin(b); fy[id] = 1.2 * cos(b); fz[id] = 1.2 * sin(a) * sin(b)
        }
        if fdIds.count > 1 {
            // Decoupled forces so the graph reads as distinct constellations: a SHORT, strong
            // spring pulls connected notes into tight, concentrated clusters (short links),
            // while a stronger, long-range repulsion drives *separate* groups far apart —
            // leaving generous empty space between clusters. Lower kSpring = tighter clusters;
            // higher kRepel = more space between groups.
            let kSpring = 0.14   // looser springs let the dense central mass expand (higher = more spread)
            let kRepel  = 2.2    // stronger repulsion inflates the interconnected core, not just the edges
            // How connected each node is. HIGH-degree nodes (hubs) otherwise pile up in the centre
            // (the "hairball"); we give hub↔hub pairs extra repulsion so they fan out — but a hub's
            // links to its low-degree leaves get NO boost, so those axes keep their length.
            var degree = [UUID: Double]()
            for e in links where fx[e.a] != nil && fx[e.b] != nil {
                degree[e.a, default: 0] += 1; degree[e.b, default: 0] += 1
            }
            let hubK = 2.0        // degree above which a node counts as a hub
            let hubSpread = 0.08  // how hard hubs push each other apart (unfolds the dense core)
            let hubMax = 12.0     // cap so a super-hub can't blow up the layout
            var temp = 0.6
            let iters = fdIds.count > 800 ? 18 : (fdIds.count > 400 ? 32 : 80)
            for _ in 0..<iters {
                var dx = [UUID: Double](), dy = [UUID: Double](), dz = [UUID: Double]()
                for ai in 0..<fdIds.count {
                    let A = fdIds[ai]
                    for bi in (ai + 1)..<fdIds.count {
                        let B = fdIds[bi]
                        var ex = fx[A]! - fx[B]!, ey = fy[A]! - fy[B]!, ez = fz[A]! - fz[B]!
                        var dist = (ex * ex + ey * ey + ez * ez).squareRoot()
                        if dist < 0.02 { ex += 0.02; dist = 0.02 }
                        // hub factor is ~1 unless BOTH ends are hubs, so leaf/axis links are untouched.
                        let hub = min(hubMax, 1.0 + hubSpread * max(0, (degree[A] ?? 0) - hubK) * max(0, (degree[B] ?? 0) - hubK))
                        let rep = (kRepel * kRepel) / (dist * dist) * hub
                        dx[A, default: 0] += ex * rep; dy[A, default: 0] += ey * rep; dz[A, default: 0] += ez * rep
                        dx[B, default: 0] -= ex * rep; dy[B, default: 0] -= ey * rep; dz[B, default: 0] -= ez * rep
                    }
                }
                for e in links where fx[e.a] != nil && fx[e.b] != nil {
                    let ex = fx[e.a]! - fx[e.b]!, ey = fy[e.a]! - fy[e.b]!, ez = fz[e.a]! - fz[e.b]!
                    let dist = max(0.02, (ex * ex + ey * ey + ez * ez).squareRoot())
                    let att = dist / kSpring
                    dx[e.a, default: 0] -= ex * att; dy[e.a, default: 0] -= ey * att; dz[e.a, default: 0] -= ez * att
                    dx[e.b, default: 0] += ex * att; dy[e.b, default: 0] += ey * att; dz[e.b, default: 0] += ez * att
                }
                for id in fdIds {
                    let mx = dx[id] ?? 0, my = dy[id] ?? 0, mz = dz[id] ?? 0
                    let len = max(0.0001, (mx * mx + my * my + mz * mz).squareRoot())
                    let s = min(len, temp) / len
                    fx[id]! += mx * s; fy[id]! += my * s; fz[id]! += mz * s
                }
                temp *= 0.96
            }
            // Push SEPARATE constellations apart WITHOUT stretching their internal links: find
            // the connected components, then translate each one rigidly outward from the centre.
            // The gaps between groupings widen while every cluster keeps its tight, short-axis
            // shape — "spread the groups, don't lengthen the axes". Union–find is ~linear.
            var parent = [UUID: UUID](minimumCapacity: fdIds.count)
            for id in fdIds { parent[id] = id }
            func find(_ x: UUID) -> UUID {
                var r = x
                while parent[r]! != r { parent[r] = parent[parent[r]!]!; r = parent[r]! }
                return r
            }
            for e in links where fx[e.a] != nil && fx[e.b] != nil {
                let ra = find(e.a), rb = find(e.b); if ra != rb { parent[ra] = rb }
            }
            var comps = [UUID: [UUID]]()
            for id in fdIds { comps[find(id), default: []].append(id) }
            if comps.count > 1 {
                let gn = Double(fdIds.count)
                let gx = fdIds.reduce(0.0) { $0 + fx[$1]! } / gn
                let gy = fdIds.reduce(0.0) { $0 + fy[$1]! } / gn
                let gz = fdIds.reduce(0.0) { $0 + fz[$1]! } / gn
                let spread = 1.9   // >1 widens the gaps between groups; internal links untouched
                for (_, members) in comps {
                    let mn = Double(members.count)
                    let cx = members.reduce(0.0) { $0 + fx[$1]! } / mn
                    let cy = members.reduce(0.0) { $0 + fy[$1]! } / mn
                    let cz = members.reduce(0.0) { $0 + fz[$1]! } / mn
                    let ox = (cx - gx) * (spread - 1), oy = (cy - gy) * (spread - 1), oz = (cz - gz) * (spread - 1)
                    for id in members { fx[id]! += ox; fy[id]! += oy; fz[id]! += oz }
                }
            }
            let n = Double(fdIds.count)
            let cx = fdIds.map { fx[$0]! }.reduce(0, +) / n
            let cy = fdIds.map { fy[$0]! }.reduce(0, +) / n
            let cz = fdIds.map { fz[$0]! }.reduce(0, +) / n
            // Normalize by a high PERCENTILE radius, not the max: one far-flung cluster (or a
            // spread-out hub) shouldn't shrink everything else into a central blob. The BULK of
            // nodes then spreads to fill the view; a handful of outliers reach past the edges
            // (pan/zoom to reach them). This is what stops the graph reading as a middle-of-screen
            // knot.
            var radii = [Double](); radii.reserveCapacity(fdIds.count)
            for id in fdIds {
                let ddx = fx[id]! - cx, ddy = fy[id]! - cy, ddz = fz[id]! - cz
                radii.append((ddx * ddx + ddy * ddy + ddz * ddz).squareRoot())
            }
            radii.sort()
            let pR = max(0.01, radii[Int(Double(radii.count - 1) * 0.85)])   // 85th-percentile radius
            // De-densify the CENTRE with a concave power remap: crowded central nodes get pushed
            // far outward (r^gamma with gamma<1 blows up small radii) while the rim barely moves.
            // Force sims only run ~18 iterations on a big graph so a dense core never unfolds on its
            // own, and a solid 3-D ball always reads dense in the middle when flattened to the
            // screen — this remap fixes both directly, independent of the sim.
            let targetR = 3.4, gamma = 0.4   // lower gamma = harder-hollowed centre
            for id in fdIds {
                let dx0 = fx[id]! - cx, dy0 = fy[id]! - cy, dz0 = fz[id]! - cz
                let r = max(0.0001, (dx0 * dx0 + dy0 * dy0 + dz0 * dz0).squareRoot())
                let s = targetR * pow(r / pR, gamma) / r   // scale ∝ r^(gamma-1): huge near centre, ~1 at rim
                fx[id] = dx0 * s; fy[id] = dy0 * s; fz[id] = dz0 * s
            }
        }
        // Unlinked files sit on a surrounding shell (fibonacci sphere).
        let unlinked = ids.filter { !linkedSet.contains($0) }
        let golden = Double.pi * (1 + 5.0.squareRoot())
        for (i, id) in unlinked.enumerated() {
            let t = (Double(i) + 0.5) / Double(max(1, unlinked.count))
            let phi = acos(1 - 2 * t), theta = golden * Double(i)
            fx[id] = 4.0 * sin(phi) * cos(theta); fy[id] = 4.0 * cos(phi); fz[id] = 4.0 * sin(phi) * sin(theta)
        }
        func graphPos(_ id: UUID) -> SCNVector3 { v(fx[id] ?? 0, fy[id] ?? 0, fz[id] ?? 0) }

        // The connectome IS the body: each axis's connected notes migrate into a HUMANOID part,
        // so the neural web resolves into a figure — head, torso, spine, and four limbs — rather
        // than an organ system. Which axis grows which part is the feedback: a neglected area
        // leaves its limb sparse and unformed. Coordinates are in body space (feet ≈ y −1, crown
        // ≈ y 0.95); the converge step below scales the whole graph down onto it as maturity rises.
        func bodyTarget(_ axis: String, _ i: Int, _ n: Int) -> SCNVector3 {
            func r(_ salt: Int) -> Double { hrand(i, salt) }
            let jit = 0.04
            switch axis {
            case "mind", "meaning":                  // the HEAD (a rounded skull, split L/R by axis)
                let side = axis == "mind" ? -1.0 : 1.0
                let rr = 0.14 * pow(r(20), 1.0 / 3.0), th = r(21) * 2 * .pi, ph = acos(2 * r(22) - 1)
                return v(side * 0.03 + rr * sin(ph) * cos(th) * 0.85, 0.82 + rr * cos(ph), rr * sin(ph) * sin(th) * 0.9)
            case "heart":                            // the CHEST / upper torso (broad shoulders)
                return v((r(20) - 0.5) * 0.34, 0.36 + (r(21) - 0.5) * 0.30, (r(22) - 0.5) * 0.15)
            case "spirit":                           // the SPINE — a column down the core
                let t = (Double(i) + 0.5) / Double(max(1, n))
                return v((r(20) - 0.5) * 0.06, 0.5 - t * 0.7, -0.03 + (r(21) - 0.5) * 0.04)
            case "gut":                              // the PELVIS / lower core
                return v((r(20) - 0.5) * 0.24, -0.06 + (r(21) - 0.5) * 0.22, (r(22) - 0.5) * 0.12)
            case "body":                             // the FOUR LIMBS — arms and legs
                let along = r(30)                    // 0 = joint, 1 = extremity
                switch i % 4 {
                case 0: return v(-0.20 - along * 0.30, 0.42 - along * 0.52 + (r(31) - 0.5) * jit, (r(32) - 0.5) * jit)  // L arm
                case 1: return v( 0.20 + along * 0.30, 0.42 - along * 0.52 + (r(31) - 0.5) * jit, (r(32) - 0.5) * jit)  // R arm
                case 2: return v(-0.11 + (r(31) - 0.5) * jit, -0.30 - along * 0.68, (r(32) - 0.5) * jit)                // L leg
                default: return v( 0.11 + (r(31) - 0.5) * jit, -0.30 - along * 0.68, (r(32) - 0.5) * jit)              // R leg
                }
            case "influences":                       // an aura shell around the whole figure
                let rr = 0.55 + r(20) * 0.12, th = r(21) * 2 * .pi, ph = acos(2 * r(22) - 1)
                return v(rr * sin(ph) * cos(th), 0.05 + rr * cos(ph) * 0.95, rr * sin(ph) * sin(th))
            default:                                  // fallback: near the core
                let c = region(axis)
                return v(c.0, c.1, c.2)
            }
        }

        var pos: [UUID: SCNVector3] = [:]
        // Accumulate node positions grouped by axis + a size bucket, so the ENTIRE graph
        // renders as a few batched point clouds (one draw call each) instead of one
        // SCNNode per note. This is what keeps memory ~flat no matter how many notes.
        var cloudPts: [String: [SCNVector3]] = [:]     // LINKED nodes → organ shapes (bright)
        var looseByAxis: [String: [SCNVector3]] = [:]  // UNLINKED nodes → loose, dim, outside
        var hitTargets: [(id: UUID, local: SCNVector3)] = []
        var labelTargets: [(id: UUID, local: SCNVector3, text: String)] = []
        for (axisKey, group) in Dictionary(grouping: nodes, by: { $0.axis }) {
            let n = group.count
            for (i, gn) in group.enumerated() {
                let linked = linkedSet.contains(gn.id)
                // Only CONNECTED notes coalesce into the organs — the web builds the body.
                // Unlinked notes stay loose points drifting around it, not part of an organ.
                let p: SCNVector3
                if linked {
                    // Start scattered — a loose web at the force-directed graph positions —
                    // and only migrate into the organ SHAPE as THIS axis matures. So a young
                    // graph is diffuse stardust, and organs (then a whole body) emerge slowly,
                    // each axis at its own pace: a rich axis solidifies while a sparse one
                    // stays ethereal and spread out.
                    // Pull toward the organ shape as the axis matures, but only PARTWAY —
                    // the nodes keep breathing room so the connectome stays a spread web
                    // rather than collapsing into a tight knot. The translucent organ mesh
                    // (added below) supplies the actual organ silhouette.
                    // PROTOTYPE: previewMorph forces the mature figure so the body reads on
                    // low-maturity demo data. Set back to 0 to make it maturity-driven.
                    let previewMorph = 0.9
                    let rm = max(regionMaturity(axisKey), previewMorph)
                    let converge = smoothstep(0.05, 0.85, rm) * 0.92
                    p = lerpV(graphPos(gn.id), bodyTarget(axisKey, i, n), converge)
                } else {
                    p = graphPos(gn.id)   // the surrounding shell — loose, unintegrated
                }
                pos[gn.id] = p
                hitTargets.append((gn.id, p))
                if !gn.label.isEmpty { labelTargets.append((gn.id, p, gn.label)) }
                guard nodesAppear > 0.02 else { continue }
                if linked {
                    let bucket = (degree[gn.id] ?? 0) >= 3 ? "hub" : "dot"   // hubs a touch larger
                    cloudPts[gn.axis + "|" + bucket, default: []].append(p)
                } else {
                    looseByAxis[gn.axis, default: []].append(p)
                }
            }
        }
        // Nodes are the star: a glowing dot per note (soft additive halo + crisp core),
        // grouped into organ shapes. The organ meshes stay a faint ghost behind them.
        for (key, pts) in cloudPts where !pts.isEmpty {
            let parts = key.split(separator: "|")
            let axisKey = String(parts.first ?? "")
            let isHub = parts.count > 1 && parts[1] == "hub"
            let col = color(axisKey)
            let coreR: CGFloat = isHub ? 7 : 4.5
            let glow = pointCloud(pts, color: col, screenRadius: coreR * 2.6,
                                  opacity: CGFloat(0.2 * nodesAppear), additive: true)
            glow.renderingOrder = 11
            connectomeFloat.addChildNode(glow)
            let core = pointCloud(pts, color: col, screenRadius: coreR,
                                  opacity: CGFloat(0.95 * nodesAppear))
            core.renderingOrder = 12
            connectomeFloat.addChildNode(core)
        }
        // Unlinked notes: small, dim, no glow — present but clearly not part of the web.
        for (axisKey, pts) in looseByAxis where !pts.isEmpty {
            let loose = pointCloud(pts, color: color(axisKey), screenRadius: 2.2,
                                   opacity: CGFloat(0.28 * nodesAppear))
            loose.renderingOrder = 10
            connectomeFloat.addChildNode(loose)
        }

        // ── SKIN (prototype) ── After the connectome has resolved into node-limbs, a translucent
        // membrane grows OVER the figure — the stage between the neural web and the solid body.
        // Opacity ramps with maturity; previewMorph forces it visible on the demo. It doesn't
        // write depth, so the nodes keep glowing through the forming skin.
        let previewMorph = 0.9
        let skinForm = smoothstep(0.3, 0.85, max(matur, previewMorph))
        if skinForm > 0.01 {
            func skinPart(_ geo: SCNGeometry, _ pos: SCNVector3, scale: SCNVector3 = SCNVector3(1, 1, 1), euler: SCNVector3 = SCNVector3(0, 0, 0)) {
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = UIColor(red: 0.86, green: 0.80, blue: 0.88, alpha: 1).withAlphaComponent(CGFloat(0.32 * skinForm))
                m.roughness.contents = 0.55
                m.emission.contents = UIColor(white: 0.55, alpha: 1); m.emission.intensity = 0.06
                m.transparency = CGFloat(0.34 * skinForm)
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                geo.materials = [m]
                let n = SCNNode(geometry: geo)
                n.position = pos; n.scale = scale; n.eulerAngles = euler; n.renderingOrder = 1
                bodyFloat.addChildNode(n)
            }
            skinPart(ball(0.15), v(0, 0.82, 0))                                    // head
            skinPart(limb(0.05, 0.14), v(0, 0.63, 0))                              // neck
            skinPart(ball(0.20), v(0, 0.34, 0), scale: v(1.4, 1.05, 0.72))         // chest
            skinPart(ball(0.17), v(0, -0.05, 0), scale: v(1.1, 0.9, 0.72))         // pelvis
            skinPart(limb(0.055, 0.55), v(-0.34, 0.16, 0), euler: v(0, 0, -0.52))  // left arm (down-out)
            skinPart(limb(0.055, 0.55), v( 0.34, 0.16, 0), euler: v(0, 0, 0.52))   // right arm (down-out)
            skinPart(limb(0.078, 0.66), v(-0.11, -0.62, 0))                        // left leg
            skinPart(limb(0.078, 0.66), v( 0.11, -0.62, 0))                        // right leg
        }
        // (hit/label targets + the moving nodes are returned below, wired up on the main thread)

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
            mat.emission.intensity = (e.cross ? 0.38 : 0.24) * linksAppear   // lighter threads
            mat.transparency = CGFloat((e.cross ? 0.42 : 0.28) * linksAppear)
            mat.writesToDepthBuffer = false
            thread(a, b, e.cross ? 0.0026 : 0.0017, mat, name: "link:\(e.a.uuidString):\(e.b.uuidString)")
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
        // A gentle breath: the figure swells and settles on a slow, uneven rhythm (a quicker
        // inhale, a longer exhale) — chest/belly (x,z) expand a touch more than the lift (y),
        // so it reads as breathing rather than pulsing. A model-agnostic "alive" idle that
        // carries over when a rigged model replaces this mesh.
        let breathPeriod = 5.0
        let breathe = SCNAction.customAction(duration: breathPeriod) { node, elapsed in
            let t = Double(elapsed) / breathPeriod                 // 0→1 over a breath
            // Skewed rise/fall: ~40% inhale, ~60% exhale, smoothed.
            let raw = t < 0.4 ? (t / 0.4) : (1 - (t - 0.4) / 0.6)
            let phase = raw * raw * (3 - 2 * raw)                  // smoothstep ease
            node.scale = SCNVector3(Float(1.0 + 0.014 * phase),
                                    Float(1.0 + 0.006 * phase),
                                    Float(1.0 + 0.014 * phase))
        }
        bodyFloat.runAction(.repeatForever(breathe))
        // Connectome drifts on its own, slightly different phase/rate.
        connectomeFloat.runAction(drift(0, 0.05, 0.02, 3.5))
        connectomeFloat.runAction(drift(0.05, 0, 0, 4.4))
        connectomeFloat.runAction(tumble(-0.04, 0.11, 6.3))
        scene.rootNode.addChildNode(figure)
        return BuiltAvatarScene(scene: scene, hits: hitTargets, labels: labelTargets,
                                connectome: connectomeFloat, body: bodyFloat)
    }

    /// Build the scene on a background thread (it's heavy at scale: an O(n²) layout, model
    /// loading, and ~1500 objects), then attach it on the main thread — so tapping into the
    /// avatar stays smooth instead of freezing during the build. A generation token drops a
    /// stale build if a newer one (e.g. a maturity step) started meanwhile.
    private func buildSceneAsync(into view: SCNView, _ coordinator: Coordinator) {
        coordinator.buildGeneration += 1
        let gen = coordinator.buildGeneration
        if view.scene == nil { view.scene = SCNScene() }   // instant, empty placeholder
        let builder = self
        DispatchQueue.global(qos: .userInitiated).async {
            let built = builder.buildScene()
            DispatchQueue.main.async {
                guard coordinator.buildGeneration == gen, let v = coordinator.view else { return }
                v.scene = built.scene
                v.pointOfView = built.scene.rootNode.childNode(withName: "camera", recursively: false)
                v.pointOfView?.camera?.orthographicScale = Self.baseOrtho / max(0.1, builder.zoom)
                coordinator.nodeHitTargets = built.hits
                coordinator.labelTargets = built.labels
                coordinator.nodeName = Dictionary(built.labels.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                coordinator.connectomeNode = built.connectome
                coordinator.bodyFloatNode = built.body
                coordinator.builtMaturity = builder.maturity
                coordinator.lastNodeScale = -1   // force a re-thin of link threads for the new scene
                coordinator.resetFocusState()    // old scene's highlight refs are gone
                builder.onFocus?(nil)
                // Apply a focus requested before the scene was ready (opened from a note/folder).
                let pending = coordinator.pendingFocus ?? builder.focusRequest
                if let pending { coordinator.pendingFocus = nil; coordinator.applyFocus(pending) }
            }
        }
    }
}
