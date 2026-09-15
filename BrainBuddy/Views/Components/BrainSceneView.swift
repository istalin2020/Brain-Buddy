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

/// The brain: a holographic model you turn, zoom into, and tap.
///
/// Everything you have saved is wired to it — one glowing node per document,
/// sitting *on* the cortex, on a filament running back to the part of it the
/// document was filed under. Zoomed out that reads as a brain with a nervous
/// system. Zoom in and the nodes nearest the camera put their names up, because
/// that is the moment you are actually looking for one thing rather than
/// looking at everything.
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
        // The stage is always dark, whatever the app's appearance. A lit,
        // glowing model on a white page looked like a mistake — the glow is
        // *additive*, and adding light to white is invisible.
        view.backgroundColor = BrainSceneBuilder.Palette.stage
        view.antialiasingMode = .multisampling4X
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
///
/// **Why it looks the way it does.** The first version drew the brain as
/// additive lines on a transparent background — the film idea of a hologram —
/// and it did not read as a brain, for a reason that is obvious in hindsight:
/// a fold you cannot *shade* is a fold nobody sees. Lines show an outline; only
/// light shows a surface. So the tissue is now a lit, translucent solid that
/// writes depth, with the wireframe drawn over it as detail rather than as the
/// whole thing. The far side is hidden by the near side, the gyri catch the
/// key light, the fissure falls into shadow, and the shape stops being a blob.
enum BrainSceneBuilder {
    static let cameraName = "camera"
    static let filesName = "files"
    static let labelName = "label"
    private static let filePrefix = "file."
    private static let wirePrefix = "wire."

    /// How close the camera has to get before a node says what it is.
    static let labelRevealDistance: Float = 3.2

    /// Past this many nodes the scene stops being readable long before it stops
    /// being fast, so the model shows the newest and the list below shows the
    /// rest.
    static let maximumNodes = 120

    /// Where the cerebellum sits, under and behind the cerebrum.
    static let cerebellumOffset = SIMD3<Float>(0, -0.46, -0.66)

    /// How far above the cortex a document sits, as a multiple of the surface
    /// radius. Just enough to clear the folds; a node buried in a sulcus is a
    /// node you cannot tap.
    static let nodeLift: Float = 1.07
    /// Filaments run a hair above the surface, so the tissue never hides them.
    static let wireLift: Float = 1.02

    // MARK: - The brain

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = Palette.stage

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

    /// Two passes over the same surface: a lit translucent solid so the shape
    /// reads as tissue, and the wireframe over it so it reads as *drawn*.
    private static func cerebrum() -> SCNNode {
        surfaceNode(for: BrainMesh.geometry(.cerebrum))
    }

    private static func cerebellum() -> SCNNode {
        let node = surfaceNode(for: BrainMesh.geometry(.cerebellum))
        node.position = SCNVector3(cerebellumOffset.x, cerebellumOffset.y, cerebellumOffset.z)
        return node
    }

    private static func surfaceNode(for geometry: SCNGeometry) -> SCNNode {
        let node = SCNNode()

        let solid = SCNNode(geometry: volume(of: geometry))
        solid.renderingOrder = RenderOrder.tissue
        node.addChildNode(solid)

        let lines = SCNNode(geometry: wireframe(of: geometry))
        // A whisker larger than the tissue, so the lines sit on the surface
        // instead of fighting it for the same depth.
        lines.scale = SCNVector3(1.008, 1.008, 1.008)
        lines.renderingOrder = RenderOrder.wire
        node.addChildNode(lines)
        return node
    }

    private static func stem() -> SCNNode {
        let geometry = BrainMesh.stem()
        geometry.firstMaterial = tissueMaterial()

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, -0.70, -0.40)
        node.eulerAngles = SCNVector3(0.55, 0, 0)
        node.renderingOrder = RenderOrder.tissue
        return node
    }

    /// The light in the middle. Seen faintly through the tissue, breathing —
    /// it is what says *this thing is on* rather than a museum piece.
    private static func core() -> SCNNode {
        let geometry = SCNSphere(radius: 0.13)
        geometry.segmentCount = 24

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.emission.contents = Palette.core
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        // Drawn before the tissue, so the tissue blends over it and it glows
        // from inside rather than sitting in front.
        node.renderingOrder = RenderOrder.core
        node.runAction(
            .repeatForever(
                .sequence([
                    .scale(to: 1.16, duration: 1.9),
                    .scale(to: 0.92, duration: 1.9)
                ])
            )
        )
        return node
    }

    // MARK: - Documents

    /// One node per document, on the cortex, on a filament back to its region.
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
            let root = anchor(for: region)

            for (index, file) in regionFiles.enumerated() {
                let direction = self.direction(for: index, in: regionFiles.count, region: region)
                let position = cortex(toward: direction, region: region, lift: nodeLift)
                container.addChildNode(node(for: file, at: position))
                appendFilament(from: root, to: direction, region: region, into: &wire)
            }

            if let filaments = filaments(wire, tint: UIColor(region.tint)) {
                filaments.name = wirePrefix + region.rawValue
                container.addChildNode(filaments)
            }
        }
    }

    private static func node(for file: BrainSceneFile, at position: SIMD3<Float>) -> SCNNode {
        let geometry = SCNSphere(radius: 0.034)
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
        let plane = SCNPlane(width: 0.56, height: 0.14)
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
        node.position = SCNVector3(0, 0.11, 0)
        node.isHidden = true
        node.renderingOrder = RenderOrder.label
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

    /// One filament, as an arc that hugs the cortex from the region's anchor to
    /// the document.
    ///
    /// A straight line between two points on a sphere is a chord through the
    /// middle of it, and now that the tissue hides what is behind it, a chord
    /// would vanish into the brain and come out the other side. So the wire
    /// follows the surface instead — a few short segments, each looked up on
    /// the mesh — and lifts slightly in the middle so it visibly *runs over*
    /// the folds rather than through them.
    private static func appendFilament(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        region: BrainRegion,
        into points: inout [SCNVector3]
    ) {
        let steps = 6
        var previous = cortex(toward: start, region: region, lift: wireLift)
        for step in 1...steps {
            let progress = Float(step) / Float(steps)
            let direction = slerp(start, end, progress)
            let lift = step == steps
                ? nodeLift
                : wireLift + 0.05 * sin(progress * .pi)
            let point = cortex(toward: direction, region: region, lift: lift)
            points.append(SCNVector3(previous.x, previous.y, previous.z))
            points.append(SCNVector3(point.x, point.y, point.z))
            previous = point
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
        material.diffuse.contents = tint.withAlphaComponent(0.55)
        material.emission.contents = tint.withAlphaComponent(0.55)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = RenderOrder.filament
        return node
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
            node.scale = isSelected ? SCNVector3(1.9, 1.9, 1.9) : SCNVector3(1, 1, 1)
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
    ///
    /// General's direction is relative to the cerebellum, which is where it
    /// lives; the others are relative to the cerebrum.
    static func anchor(for region: BrainRegion) -> SIMD3<Float> {
        switch region {
        case .work: return normalize(SIMD3<Float>(0.40, 0.42, 1.00))
        case .friends: return normalize(SIMD3<Float>(-0.46, 0.96, -0.30))
        case .media: return normalize(SIMD3<Float>(1.00, -0.18, 0.12))
        case .images: return normalize(SIMD3<Float>(0.10, 0.30, -1.05))
        case .family: return normalize(SIMD3<Float>(-1.00, -0.10, 0.34))
        case .general: return normalize(SIMD3<Float>(0.30, -0.50, -1.00))
        }
    }

    /// The direction of the `index`th document in a region: a golden-angle
    /// spiral around the region's direction. Deterministic, so a document keeps
    /// its place between visits — which is the entire point of arranging them
    /// in space at all.
    static func direction(for index: Int, in total: Int, region: BrainRegion) -> SIMD3<Float> {
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
        let spread = 0.55 * sqrt(Float(index + 1) / Float(max(total, 1)))
        let offset = right * (cos(angle) * spread) + forward * (sin(angle) * spread)
        return normalize(axis + offset)
    }

    /// Where a document sits: on the cortex, in its direction, lifted clear of
    /// the folds.
    static func position(for index: Int, in total: Int, region: BrainRegion) -> SIMD3<Float> {
        cortex(toward: direction(for: index, in: total, region: region), region: region, lift: nodeLift)
    }

    /// The surface in a given direction, in scene coordinates — the cerebellum
    /// for General, the cerebrum for everything else.
    static func cortex(toward direction: SIMD3<Float>, region: BrainRegion, lift: Float) -> SIMD3<Float> {
        if region == .general {
            return cerebellumOffset + BrainMesh.surfacePoint(toward: direction, shape: .cerebellum) * lift
        }
        return BrainMesh.surfacePoint(toward: direction, shape: .cerebrum) * lift
    }

    /// Spherical interpolation between two unit vectors — the path a wire takes
    /// over a curved surface.
    private static func slerp(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ progress: Float) -> SIMD3<Float> {
        let cosine = max(-1, min(1, dot(from, to)))
        let omega = acos(cosine)
        guard omega > 1e-4 else { return from }
        let sine = sin(omega)
        return (from * sin((1 - progress) * omega) + to * sin(progress * omega)) / sine
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
        camera.fieldOfView = 40
        camera.zNear = 0.05
        camera.zFar = 120
        // The glow is part of the look, so let the bright parts bloom — but
        // not so much that the lit tissue washes out.
        camera.bloomIntensity = 0.55
        camera.bloomBlurRadius = 10
        camera.bloomThreshold = 0.62
        node.camera = camera
        node.transform = defaultCameraTransform()
        return node
    }

    /// Three-quarter view, slightly above: enough to see the front, the side and
    /// the cerebellum at once, so no cluster is hidden when the screen opens.
    private static func defaultCameraTransform() -> SCNMatrix4 {
        let node = SCNNode()
        node.position = SCNVector3(2.5, 1.35, 3.6)
        node.look(
            at: SCNVector3(0, -0.08, 0),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 0, -1)
        )
        return node.transform
    }

    /// A three-point rig. The key from the front-top-right makes the gyri read;
    /// the fill keeps the shadow side from going black; the rim, from behind,
    /// draws the silhouette in cyan so the outline is there even where nothing
    /// else is.
    private static func lights() -> [SCNNode] {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.color = Palette.key
        key.position = SCNVector3(3, 4, 5)
        key.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.light?.color = Palette.fill
        fill.position = SCNVector3(-4, 1, 2)
        fill.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 500
        rim.light?.color = Palette.rim
        rim.position = SCNVector3(-2, -1, -4)
        rim.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 140
        ambient.light?.color = Palette.ambient

        return [key, fill, rim, ambient]
    }

    // MARK: - Materials

    private static func volume(of geometry: SCNGeometry) -> SCNGeometry {
        let copy = (geometry.copy() as? SCNGeometry) ?? geometry
        copy.firstMaterial = tissueMaterial()
        return copy
    }

    /// Lit, translucent, and depth-writing. Translucent so the core and the far
    /// nodes show through faintly, as they would in glass; depth-writing so the
    /// near surface hides the far one, which is what makes it a solid.
    /// `.singleLayer` draws only the nearest surface, so the inside of the mesh
    /// never darkens the outside.
    private static func tissueMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = Palette.tissue
        material.specular.contents = UIColor.white.withAlphaComponent(0.55)
        material.shininess = 0.30
        material.emission.contents = Palette.wire.withAlphaComponent(0.08)
        material.transparency = 0.66
        material.transparencyMode = .singleLayer
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        return material
    }

    private static func wireframe(of geometry: SCNGeometry) -> SCNGeometry {
        let copy = (geometry.copy() as? SCNGeometry) ?? geometry
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.fillMode = .lines
        material.diffuse.contents = Palette.wire.withAlphaComponent(0.34)
        material.emission.contents = Palette.wire.withAlphaComponent(0.34)
        material.blendMode = .add
        // Reads depth, so the lines on the far side are hidden by the tissue
        // in front — a wireframe you can see through is the tangle that
        // didn't look like a brain.
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        copy.firstMaterial = material
        return copy
    }

    /// The order things are drawn in. Transparent parts are sorted by this
    /// before distance, and everything here shares the same centre, so leaving
    /// it to distance would shuffle the layers between frames.
    private enum RenderOrder {
        static let core = 5
        static let tissue = 10
        static let wire = 20
        static let filament = 30
        static let label = 100
    }

    /// One place to change the whole look.
    enum Palette {
        /// Deep navy. The stage is this colour in both appearances.
        static let stage = UIColor(red: 0.035, green: 0.050, blue: 0.125, alpha: 1)
        static let tissue = UIColor(red: 0.30, green: 0.50, blue: 0.96, alpha: 1)
        static let wire = UIColor(red: 0.58, green: 0.86, blue: 1.00, alpha: 1)
        static let core = UIColor(red: 0.72, green: 0.92, blue: 1.00, alpha: 1)
        static let key = UIColor(red: 0.88, green: 0.93, blue: 1.00, alpha: 1)
        static let fill = UIColor(red: 0.55, green: 0.42, blue: 1.00, alpha: 1)
        static let rim = UIColor(red: 0.30, green: 0.90, blue: 1.00, alpha: 1)
        static let ambient = UIColor(red: 0.18, green: 0.24, blue: 0.48, alpha: 1)
    }
}
