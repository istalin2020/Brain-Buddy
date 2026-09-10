import SceneKit
import SwiftUI
import UIKit
import simd

/// One document, as the scene needs it.
struct BrainSceneFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let region: BrainRegion
}

/// The brain: a holographic wireframe you turn, zoom into, and tap.
///
/// Everything you have saved is wired to it — one glowing node per document,
/// on a filament running back to the part of the cortex it was filed under.
/// Zoomed out that reads as a shape with a nervous system. Zoom in and the
/// nodes nearest the camera put their names up, because that is the moment you
/// are actually looking for one thing rather than looking at everything.
///
/// Drag to turn · pinch to zoom · tap a node.
@MainActor
struct BrainSceneView: UIViewRepresentable {
    let files: [BrainSceneFile]
    /// When set, that region's nodes stay lit and the rest fall back.
    var highlight: BrainRegion?
    @Binding var selectedFile: UUID?
    var resetToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = BrainSceneBuilder.makeScene()
        view.pointOfView = view.scene?.rootNode.childNode(
            withName: BrainSceneBuilder.cameraName,
            recursively: true
        )
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        // The core breathes, and labels appear and disappear as the camera
        // moves, so the scene needs to be running rather than drawn on demand.
        view.isPlaying = true
        view.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // The camera controller owns drag and pinch; a single tap is free, and
        // letting the touch through keeps them working.
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        context.coordinator.view = view
        context.coordinator.lastResetToken = resetToken
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self

        let signature = files.map(\.id.uuidString).joined(separator: ",")
        if context.coordinator.lastSignature != signature {
            context.coordinator.lastSignature = signature
            BrainSceneBuilder.rebuildFiles(files, in: uiView.scene)
        }

        context.coordinator.selected.name = selectedFile.map(BrainSceneBuilder.nodeName(for:))
        BrainSceneBuilder.emphasize(
            files: files,
            highlight: highlight,
            selected: selectedFile,
            in: uiView.scene
        )

        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            BrainSceneBuilder.resetCamera(in: uiView)
        }
    }

    /// What the render thread is allowed to read.
    ///
    /// The coordinator is main-actor bound — it holds a `View` and a `Binding` —
    /// but `renderer(_:willRenderScene:atTime:)` is called on SceneKit's own
    /// thread, sixty times a second. A reference box is the honest way across:
    /// one word, written on main, read on the render thread, where a value one
    /// frame stale is invisible and a lock on that path is not free.
    final class SelectedNode: @unchecked Sendable {
        var name: String?
    }

    @MainActor
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var parent: BrainSceneView
        weak var view: SCNView?
        var lastResetToken = 0
        var lastSignature = ""
        let selected = SelectedNode()

        init(_ parent: BrainSceneView) {
            self.parent = parent
        }

        // MARK: Tapping

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])

            let tapped = hits.compactMap { BrainSceneBuilder.fileIdentifier(of: $0.node) }.first
            // Tapping the same node again closes it; tapping the space around
            // the brain clears the selection, which is the gesture everybody
            // tries first.
            parent.selectedFile = (tapped == parent.selectedFile) ? nil : tapped
        }

        // MARK: Per-frame

        /// Names appear on the nodes nearest the camera.
        ///
        /// Distance rather than a zoom level, so it behaves the same whether you
        /// pinched in or simply turned the brain so a node came forward — and so
        /// a crowded region reveals itself gradually instead of all at once.
        nonisolated func renderer(
            _ renderer: SCNSceneRenderer,
            willRenderScene scene: SCNScene,
            atTime time: TimeInterval
        ) {
            guard let camera = renderer.pointOfView else { return }
            let eye = camera.presentation.simdWorldPosition
            guard let container = scene.rootNode.childNode(
                withName: BrainSceneBuilder.filesName,
                recursively: true
            ) else { return }

            let selected = self.selected.name
            for node in container.childNodes {
                guard let label = node.childNode(withName: BrainSceneBuilder.labelName, recursively: false) else {
                    continue
                }
                let distance = simd_distance(node.presentation.simdWorldPosition, eye)
                label.isHidden = distance > BrainSceneBuilder.labelRevealDistance && node.name != selected
            }
        }
    }
}

/// Builds the scene, and updates the parts of it that change.
enum BrainSceneBuilder {
    static let cameraName = "camera"
    static let filesName = "files"
    static let labelName = "label"
    private static let filePrefix = "file."
    private static let wirePrefix = "wire."

    /// How close the camera has to get before a node says what it is.
    static let labelRevealDistance: Float = 3.4

    /// Past this many nodes the scene stops being readable long before it stops
    /// being fast, so the model shows the newest and the list below shows the
    /// rest.
    static let maximumNodes = 120

    // MARK: - The brain

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let brain = SCNNode()
        brain.name = "brain"
        brain.addChildNode(cerebrum())
        brain.addChildNode(cerebellum())
        brain.addChildNode(stem())
        brain.addChildNode(core())
        scene.rootNode.addChildNode(brain)

        let files = SCNNode()
        files.name = filesName
        scene.rootNode.addChildNode(files)

        scene.rootNode.addChildNode(camera())
        for light in lights() { scene.rootNode.addChildNode(light) }
        return scene
    }

    /// Two passes over the same surface: a translucent volume so the shape reads
    /// as solid, and the wireframe over it so it reads as *drawn*. Either alone
    /// looks like a mistake; together they look like a hologram.
    private static func cerebrum() -> SCNNode {
        let node = SCNNode()
        let geometry = BrainMesh.geometry(.cerebrum)

        node.addChildNode(SCNNode(geometry: volume(of: geometry, tint: Palette.tissue)))
        node.addChildNode(SCNNode(geometry: wireframe(of: geometry, tint: Palette.wire)))
        return node
    }

    private static func cerebellum() -> SCNNode {
        let node = SCNNode()
        let geometry = BrainMesh.geometry(.cerebellum)

        node.addChildNode(SCNNode(geometry: volume(of: geometry, tint: Palette.tissue)))
        node.addChildNode(SCNNode(geometry: wireframe(of: geometry, tint: Palette.wire)))
        node.position = SCNVector3(0, -0.40, -0.62)
        return node
    }

    private static func stem() -> SCNNode {
        let geometry = BrainMesh.stem()
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Palette.tissue.withAlphaComponent(0.30)
        material.emission.contents = Palette.wire.withAlphaComponent(0.35)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, -0.62, -0.40)
        node.eulerAngles = SCNVector3(0.55, 0, 0)
        return node
    }

    /// The light in the middle. Every hologram in every film has one, and it
    /// does real work here: it separates the near surface from the far one when
    /// the whole thing is drawn in lines.
    private static func core() -> SCNNode {
        let geometry = SCNSphere(radius: 0.17)
        geometry.segmentCount = 24

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.emission.contents = Palette.core
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.addChildNode(coreLight())
        node.runAction(
            .repeatForever(
                .sequence([
                    .scale(to: 1.14, duration: 1.9),
                    .scale(to: 0.94, duration: 1.9)
                ])
            )
        )
        return node
    }

    private static func coreLight() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .omni
        light.color = Palette.core
        light.intensity = 620
        light.attenuationEndDistance = 4
        node.light = light
        return node
    }

    // MARK: - Documents

    /// One node per document, on a filament back to its region.
    static func rebuildFiles(_ files: [BrainSceneFile], in scene: SCNScene?) {
        guard let container = scene?.rootNode.childNode(withName: filesName, recursively: true) else {
            return
        }
        container.childNodes.forEach { $0.removeFromParentNode() }

        var byRegion: [BrainRegion: [BrainSceneFile]] = [:]
        for file in files.prefix(maximumNodes) {
            byRegion[file.region, default: []].append(file)
        }

        for (region, regionFiles) in byRegion {
            var wire: [SCNVector3] = []
            let root = anchor(for: region) * 0.98

            for (index, file) in regionFiles.enumerated() {
                let position = self.position(for: index, in: regionFiles.count, region: region)
                container.addChildNode(node(for: file, at: position))
                wire.append(SCNVector3(root.x, root.y, root.z))
                wire.append(SCNVector3(position.x, position.y, position.z))
            }

            if let filaments = filaments(wire, tint: UIColor(region.tint)) {
                filaments.name = wirePrefix + region.rawValue
                container.addChildNode(filaments)
            }
        }
    }

    private static func node(for file: BrainSceneFile, at position: SIMD3<Float>) -> SCNNode {
        let geometry = SCNSphere(radius: 0.042)
        geometry.segmentCount = 12

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(file.region.tint)
        material.emission.contents = UIColor(file.region.tint)
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.name = nodeName(for: file.id)
        node.position = SCNVector3(position.x, position.y, position.z)
        node.addChildNode(label(file.title, tint: UIColor(file.region.tint)))
        return node
    }

    /// The name, as a billboarded panel. Hidden until the camera is close —
    /// see the renderer delegate.
    private static func label(_ text: String, tint: UIColor) -> SCNNode {
        let plane = SCNPlane(width: 0.62, height: 0.155)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = labelImage(text, tint: tint)
        material.isDoubleSided = true
        // Always legible: a label behind a filament is a label you can't read.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material

        let node = SCNNode(geometry: plane)
        node.name = labelName
        node.position = SCNVector3(0, 0.13, 0)
        node.isHidden = true
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func labelImage(_ text: String, tint: UIColor) -> UIImage {
        let size = CGSize(width: 512, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let trimmed = text.count > 34 ? String(text.prefix(33)) + "…" : text

        return renderer.image { _ in
            let box = CGRect(x: 8, y: 26, width: size.width - 16, height: 76)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 20)
            UIColor.black.withAlphaComponent(0.74).setFill()
            path.fill()
            tint.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 3
            path.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32, weight: .medium),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            (trimmed as NSString).draw(
                in: box.insetBy(dx: 20, dy: 18),
                withAttributes: attributes
            )
        }
    }

    /// All of one region's filaments as a single line geometry — one node per
    /// wire would be a hundred draw calls for something nobody taps.
    private static func filaments(_ points: [SCNVector3], tint: UIColor) -> SCNNode? {
        guard points.count >= 2 else { return nil }
        let indices = (0..<Int32(points.count)).map { $0 }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: points)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = tint.withAlphaComponent(0.42)
        material.emission.contents = tint.withAlphaComponent(0.42)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        return SCNNode(geometry: geometry)
    }

    // MARK: - Emphasis

    /// Dims everything that isn't the region you're looking at, and brightens
    /// the one document you opened.
    ///
    /// Takes the file list rather than reading a region off the node, because a
    /// node's region would otherwise have to be smuggled through its name and
    /// parsed back out — which is the kind of thing that works until somebody
    /// renames a region.
    static func emphasize(
        files: [BrainSceneFile],
        highlight: BrainRegion?,
        selected: UUID?,
        in scene: SCNScene?
    ) {
        guard let container = scene?.rootNode.childNode(withName: filesName, recursively: true) else {
            return
        }
        let regions = Dictionary(
            files.map { (nodeName(for: $0.id), $0.region) },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedName = selected.map(nodeName(for:))

        for node in container.childNodes {
            guard let name = node.name else { continue }

            if name.hasPrefix(wirePrefix) {
                let region = BrainRegion(rawValue: String(name.dropFirst(wirePrefix.count)))
                node.opacity = (highlight == nil || highlight == region) ? 1 : 0.12
                continue
            }

            let isSelected = name == selectedName
            let isDimmed = highlight != nil && regions[name] != highlight
            node.opacity = isDimmed && !isSelected ? 0.18 : 1
            node.scale = isSelected ? SCNVector3(1.8, 1.8, 1.8) : SCNVector3(1, 1, 1)
        }
    }

    static func nodeName(for id: UUID) -> String { filePrefix + id.uuidString }

    /// Labels are children of their node, so a tap on a name opens the document
    /// it belongs to.
    static func fileIdentifier(of node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, name.hasPrefix(filePrefix) {
                return UUID(uuidString: String(name.dropFirst(filePrefix.count)))
            }
            current = candidate.parent
        }
        return nil
    }

    // MARK: - Where things sit

    /// The direction of each region, spread around the brain so no two clusters
    /// overlap — and placed where that part of the cortex actually is.
    static func anchor(for region: BrainRegion) -> SIMD3<Float> {
        switch region {
        case .work: return normalize(SIMD3<Float>(0.42, 0.34, 1.00))
        case .friends: return normalize(SIMD3<Float>(-0.44, 0.96, -0.22))
        case .media: return normalize(SIMD3<Float>(1.00, -0.26, 0.18))
        case .images: return normalize(SIMD3<Float>(0.06, 0.22, -1.05))
        case .family: return normalize(SIMD3<Float>(-1.00, -0.16, 0.30))
        case .general: return normalize(SIMD3<Float>(0.22, -0.86, -0.58))
        }
    }

    /// A golden-angle spiral around the region's direction, pushed out onto a
    /// shell. Deterministic, so a document keeps its place between visits —
    /// which is the entire point of arranging them in space at all.
    static func position(for index: Int, in total: Int, region: BrainRegion) -> SIMD3<Float> {
        let axis = anchor(for: region)
        let reference: SIMD3<Float> = abs(axis.y) > 0.9
            ? SIMD3<Float>(1, 0, 0)
            : SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(reference, axis))
        let forward = cross(axis, right)

        let goldenAngle: Float = 2.39996
        let angle = Float(index) * goldenAngle
        // Spread grows with the square root of the index, which is what keeps a
        // spiral evenly dense rather than crowded in the middle.
        let spread = 0.62 * sqrt(Float(index + 1) / Float(max(total, 1)))
        let offset = right * (cos(angle) * spread) + forward * (sin(angle) * spread)

        let shell: Float = 1.46 + 0.13 * Float(index % 3)
        return normalize(axis + offset) * shell
    }

    // MARK: - Camera and light

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

    private static func camera() -> SCNNode {
        let node = SCNNode()
        node.name = cameraName
        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.05
        camera.zFar = 120
        // The glow is the point of the look, so let the bright parts bloom.
        camera.bloomIntensity = 0.75
        camera.bloomBlurRadius = 12
        camera.bloomThreshold = 0.55
        node.camera = camera
        node.transform = defaultCameraTransform()
        return node
    }

    /// Three-quarter view, slightly above: enough to see the front, the side and
    /// the cerebellum at once, so no cluster is hidden when the screen opens.
    private static func defaultCameraTransform() -> SCNMatrix4 {
        let node = SCNNode()
        node.position = SCNVector3(2.7, 1.5, 3.9)
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
        key.light?.intensity = 520
        key.light?.color = Palette.wire
        key.position = SCNVector3(3, 4, 5)
        key.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 380
        rim.light?.color = Palette.rim
        rim.position = SCNVector3(-4, -1, -3)
        rim.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 180
        ambient.light?.color = Palette.ambient

        return [key, rim, ambient]
    }

    // MARK: - Materials

    private static func volume(of geometry: SCNGeometry, tint: UIColor) -> SCNGeometry {
        let copy = (geometry.copy() as? SCNGeometry) ?? geometry
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = tint.withAlphaComponent(0.16)
        material.emission.contents = tint.withAlphaComponent(0.10)
        material.blendMode = .add
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        copy.firstMaterial = material
        return copy
    }

    private static func wireframe(of geometry: SCNGeometry, tint: UIColor) -> SCNGeometry {
        let copy = (geometry.copy() as? SCNGeometry) ?? geometry
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.fillMode = .lines
        material.diffuse.contents = tint.withAlphaComponent(0.55)
        material.emission.contents = tint.withAlphaComponent(0.55)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        copy.firstMaterial = material
        return copy
    }

    /// One place to change the whole look.
    enum Palette {
        static let wire = UIColor(red: 0.42, green: 0.72, blue: 1.00, alpha: 1)
        static let tissue = UIColor(red: 0.55, green: 0.45, blue: 1.00, alpha: 1)
        static let core = UIColor(red: 0.65, green: 0.90, blue: 1.00, alpha: 1)
        static let rim = UIColor(red: 0.75, green: 0.40, blue: 1.00, alpha: 1)
        static let ambient = UIColor(red: 0.20, green: 0.30, blue: 0.55, alpha: 1)
    }
}
