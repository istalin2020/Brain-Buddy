import SceneKit
import SwiftUI
import UIKit

/// The brain, in 3D, built out of code rather than a downloaded mesh.
///
/// Six soft lobes and a stem, low-poly on purpose. A photoreal brain would be a
/// twenty-megabyte asset, would take a second to appear, and would be *harder*
/// to read: what matters here is telling six regions apart at a glance and being
/// able to point at one with a thumb. Simple shapes in flat colour do that
/// better than anatomy does, and they cost nothing to ship.
///
/// Drag to turn it, pinch to zoom in, tap a lobe to open it.
@MainActor
struct BrainSceneView: UIViewRepresentable {
    /// How many memories are in each region. Fuller regions swell slightly, so
    /// the shape of your own brain is visible before you read a single number.
    let counts: [BrainRegion: Int]
    @Binding var selection: BrainRegion?
    /// Bumped by the caller to put the camera back where it started.
    var resetToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = BrainSceneBuilder.makeScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: BrainSceneBuilder.cameraName, recursively: true)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.rendersContinuously = false

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // The camera controller owns pan, pinch and rotate; a single tap is
        // free, and letting the touch through keeps them working.
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        context.coordinator.view = view
        context.coordinator.lastResetToken = resetToken
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        BrainSceneBuilder.apply(counts: counts, selection: selection, to: uiView.scene)

        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            BrainSceneBuilder.resetCamera(in: uiView)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: BrainSceneView
        weak var view: SCNView?
        var lastResetToken = 0

        init(_ parent: BrainSceneView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue
            ])

            guard let region = hits.compactMap({ Self.region(of: $0.node) }).first else {
                // Tapping the empty space around the brain closes whatever was
                // open, which is the gesture people try first.
                parent.selection = nil
                return
            }
            parent.selection = parent.selection == region ? nil : region
        }

        /// Lobes are unnamed children of a named region node, so walk up.
        private static func region(of node: SCNNode) -> BrainRegion? {
            var current: SCNNode? = node
            while let candidate = current {
                if let name = candidate.name, let region = BrainRegion(rawValue: name) {
                    return region
                }
                current = candidate.parent
            }
            return nil
        }
    }
}

/// Builds and updates the scene. Kept apart from the view so the geometry is one
/// readable list of shapes rather than something buried in a representable.
enum BrainSceneBuilder {
    static let cameraName = "camera"

    /// Where each region sits, as (position, size) for the right hemisphere.
    /// Anything with `mirrored` true is built twice, once on each side.
    struct Lobe {
        let region: BrainRegion
        let position: SCNVector3
        let scale: SCNVector3
        let mirrored: Bool
    }

    /// Rough anatomy, deliberately: front at +z, up at +y, right at +x.
    static let lobes: [Lobe] = [
        // Frontal — forward and high.
        Lobe(
            region: .work,
            position: SCNVector3(0.52, 0.30, 0.92),
            scale: SCNVector3(0.78, 0.72, 0.80),
            mirrored: true
        ),
        // Parietal — up and back of centre.
        Lobe(
            region: .friends,
            position: SCNVector3(0.50, 0.66, -0.18),
            scale: SCNVector3(0.74, 0.62, 0.80),
            mirrored: true
        ),
        // Temporal — low, out to the side.
        Lobe(
            region: .media,
            position: SCNVector3(0.86, -0.34, 0.30),
            scale: SCNVector3(0.52, 0.44, 0.78),
            mirrored: true
        ),
        // Occipital — the back of the head.
        Lobe(
            region: .images,
            position: SCNVector3(0.42, 0.14, -1.02),
            scale: SCNVector3(0.66, 0.62, 0.62),
            mirrored: true
        ),
        // Limbic core — one shape, in the middle, half-hidden by everything
        // else. Which is roughly true of family.
        Lobe(
            region: .family,
            position: SCNVector3(0, 0.02, -0.05),
            scale: SCNVector3(0.62, 0.52, 0.86),
            mirrored: false
        ),
        // Cerebellum — the lump underneath at the back.
        Lobe(
            region: .general,
            position: SCNVector3(0.40, -0.78, -0.80),
            scale: SCNVector3(0.52, 0.40, 0.52),
            mirrored: true
        )
    ]

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let brain = SCNNode()
        brain.name = "brain"

        for lobe in lobes {
            let container = SCNNode()
            container.name = lobe.region.rawValue
            container.addChildNode(sphere(for: lobe.region, at: lobe.position, scale: lobe.scale))
            if lobe.mirrored {
                let mirrored = SCNVector3(-lobe.position.x, lobe.position.y, lobe.position.z)
                container.addChildNode(sphere(for: lobe.region, at: mirrored, scale: lobe.scale))
            }
            brain.addChildNode(container)
        }

        brain.addChildNode(stem())
        scene.rootNode.addChildNode(brain)
        scene.rootNode.addChildNode(camera())
        for light in lights() { scene.rootNode.addChildNode(light) }

        return scene
    }

    // MARK: - Updating

    /// Applies the current counts and selection without rebuilding anything:
    /// a rebuild on every filter change would flash the whole model.
    static func apply(counts: [BrainRegion: Int], selection: BrainRegion?, to scene: SCNScene?) {
        guard let scene else { return }
        let busiest = max(1, counts.values.max() ?? 1)

        for region in BrainRegion.allCases {
            guard let node = scene.rootNode.childNode(withName: region.rawValue, recursively: true) else {
                continue
            }
            let count = counts[region] ?? 0
            let isSelected = selection == region

            // A region with nothing in it recedes rather than disappearing —
            // you still need to see that the room exists.
            node.opacity = count == 0 ? 0.22 : 1
            let fullness = Double(count) / Double(busiest)
            let swell = Float(0.94 + 0.12 * fullness) * (isSelected ? 1.06 : 1)
            node.scale = SCNVector3(swell, swell, swell)

            let colour = UIColor(region.tint)
            node.enumerateChildNodes { child, _ in
                guard let material = child.geometry?.firstMaterial else { return }
                material.emission.contents = isSelected
                    ? colour.withAlphaComponent(0.45)
                    : UIColor.black
            }
        }
    }

    static func resetCamera(in view: SCNView) {
        guard let camera = view.scene?.rootNode.childNode(withName: cameraName, recursively: true) else {
            return
        }
        view.defaultCameraController.stopInertia()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        camera.transform = defaultCameraTransform()
        SCNTransaction.commit()
        view.pointOfView = camera
    }

    // MARK: - Pieces

    private static func sphere(for region: BrainRegion, at position: SCNVector3, scale: SCNVector3) -> SCNNode {
        let geometry = SCNSphere(radius: 1)
        // Low-poly on purpose: fewer triangles, softer read, no shimmer while
        // the model is being turned.
        geometry.segmentCount = 22

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(region.tint)
        material.roughness.contents = 0.92
        material.metalness.contents = 0.0
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.position = position
        node.scale = scale
        return node
    }

    private static func stem() -> SCNNode {
        let geometry = SCNCapsule(capRadius: 0.20, height: 0.95)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(white: 0.62, alpha: 1)
        material.roughness.contents = 0.95
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        // Unnamed and unselectable: it holds the shape together, it isn't a
        // place anything is filed.
        node.position = SCNVector3(0, -0.92, -0.30)
        node.eulerAngles = SCNVector3(0.45, 0, 0)
        return node
    }

    private static func camera() -> SCNNode {
        let node = SCNNode()
        node.name = cameraName
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.1
        camera.zFar = 100
        node.camera = camera
        node.transform = defaultCameraTransform()
        return node
    }

    /// Three-quarter view, slightly above: enough to see the front, the side and
    /// the back lump at once, so no region is hidden when the screen opens.
    private static func defaultCameraTransform() -> SCNMatrix4 {
        let node = SCNNode()
        node.position = SCNVector3(3.6, 1.9, 5.4)
        node.look(
            at: SCNVector3(0, -0.05, 0),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 0, -1)
        )
        return node.transform
    }

    private static func lights() -> [SCNNode] {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 780
        key.position = SCNVector3(3, 4, 5)
        key.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 420
        fill.position = SCNVector3(-4, -1, 3)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 320

        return [key, fill, ambient]
    }
}
