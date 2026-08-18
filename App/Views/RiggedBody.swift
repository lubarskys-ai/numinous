import Foundation
import SceneKit
import UIKit

/// Loads the rigged, animated body (Mixamo → DAE → USDZ) NATIVELY via SceneKit, so it
/// keeps its skeleton and baked idle/motion animation — unlike the static `GLTFBody`
/// mesh. It's re-skinned to the avatar's translucent grey→axis-color glow and gated by
/// maturity, then plays its looping animation. Returns nil when the model isn't bundled,
/// so the caller falls back to the static body.
enum RiggedBody {

    static func load(dominantColor: UIColor, growth01: CGFloat, maturity: Double) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: "BodyRigged", withExtension: "usdz")
                ?? Bundle.main.url(forResource: "BodyRigged", withExtension: "usdz", subdirectory: "HumanBody"),
              let scene = try? SCNScene(url: url, options: nil)
        else { return nil }

        // Re-parent the model under our own node so we control its transform.
        let model = SCNNode()
        for child in scene.rootNode.childNodes { model.addChildNode(child) }

        // Loop whatever animation is baked in (Mixamo's idle/motion) so it plays forever.
        model.enumerateChildNodes { node, _ in
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.animation.autoreverses = false
                player.play()
            }
        }

        // Normalize into our canonical figure space: ~1.7 tall, centred in x/z, feet at
        // y ≈ -0.85 — matching the region anchors the connectome uses.
        let (mn, mx) = worldBounds(model)
        let height = max(0.001, mx.y - mn.y)
        let s = Float(1.7) / height
        model.scale = SCNVector3(s, s, s)
        model.position = SCNVector3(-(mn.x + mx.x) / 2 * s, -mn.y * s - 0.85, -(mn.z + mx.z) / 2 * s)

        // Translucent glow, grey→axis-color by growth, opacity earned by maturity (below
        // ~0.4 it's pure stardust). A fresnel rim gives the ethereal edge-light.
        let form = maturity <= 0.4 ? 0.0 : (maturity - 0.4) / 0.6
        let eased = form * form * (3 - 2 * form)
        let tint = GLTFBody.blend(UIColor(white: 0.62, alpha: 1), dominantColor, min(1, max(0, growth01)) * 0.85)
        let base = String(format: "%.4f", 0.55 * eased)
        let rim = String(format: "%.4f", 0.6 * eased)
        model.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = tint
            m.roughness.contents = 0.5
            m.emission.contents = dominantColor
            m.emission.intensity = CGFloat(0.03 + 0.3 * growth01)
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.shaderModifiers = [.fragment: """
            #pragma transparent
            float _f = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));
            _f = pow(_f, 2.0) * \(rim);
            _output.color.rgb += float3(0.72, 0.83, 1.0) * _f;
            _output.color.a = min(1.0, \(base) + _f * 0.9);
            """]
            geo.materials = geo.materials.isEmpty ? [m] : geo.materials.map { _ in m }
        }

        let wrapper = SCNNode()
        wrapper.addChildNode(model)
        return wrapper
    }

    /// World-space AABB of a node hierarchy (skinned meshes can't be flattened without
    /// losing the rig, so union each geometry's transformed bounding box by hand).
    private static func worldBounds(_ root: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        var mn = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var mx = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        func pt(_ m: SCNMatrix4, _ v: SCNVector3) -> SCNVector3 {
            SCNVector3(m.m11 * v.x + m.m21 * v.y + m.m31 * v.z + m.m41,
                       m.m12 * v.x + m.m22 * v.y + m.m32 * v.z + m.m42,
                       m.m13 * v.x + m.m23 * v.y + m.m33 * v.z + m.m43)
        }
        func recurse(_ node: SCNNode, _ parent: SCNMatrix4) {
            let world = SCNMatrix4Mult(node.transform, parent)
            if node.geometry != nil {
                let (lmin, lmax) = node.boundingBox
                let corners = [
                    SCNVector3(lmin.x, lmin.y, lmin.z), SCNVector3(lmax.x, lmin.y, lmin.z),
                    SCNVector3(lmin.x, lmax.y, lmin.z), SCNVector3(lmin.x, lmin.y, lmax.z),
                    SCNVector3(lmax.x, lmax.y, lmin.z), SCNVector3(lmax.x, lmin.y, lmax.z),
                    SCNVector3(lmin.x, lmax.y, lmax.z), SCNVector3(lmax.x, lmax.y, lmax.z),
                ]
                for c in corners {
                    let p = pt(world, c)
                    mn = SCNVector3(min(mn.x, p.x), min(mn.y, p.y), min(mn.z, p.z))
                    mx = SCNVector3(max(mx.x, p.x), max(mx.y, p.y), max(mx.z, p.z))
                }
            }
            for ch in node.childNodes { recurse(ch, world) }
        }
        recurse(root, SCNMatrix4Identity)
        // Guard against an empty/degenerate hierarchy.
        if mn.y > mx.y { return (SCNVector3(-0.5, -0.85, -0.5), SCNVector3(0.5, 0.85, 0.5)) }
        return (mn, mx)
    }
}
