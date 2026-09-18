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

/// The brain: a holographic scan you turn, zoom into, and tap.
///
/// Everything you have saved is wired to it — one glowing node per document,
/// sitting *on* the cortex, on a filament running back to the part of it the
/// document was filed under. Each region carries a callout: a line from the
/// cortex out to a tag naming what is stored there and how much. Zoomed out
/// that reads as an annotated scan. Zoom in and the nodes nearest the camera
/// put their names up, because that is the moment you are actually looking
/// for one thing rather than looking at everything.
///
/// Drag to turn · pinch to zoom · tap a node.
@MainActor
struct BrainSceneView: UIViewRepresentable {
    let files: [BrainSceneFile]
    /// How much is filed under each region, for the callouts.
    var counts: [BrainRegion: Int] = [:]
    /// Work's rooms, for the second line of its callout — "where it stores
    /// the reminders" is a question the map should answer without a tap.
    var workSections: [WorkSection: Int] = [:]
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
        // The stage is always dark, whatever the app's appearance: everything
        // in the scene is drawn by *adding* light, and adding light to a white
        // page is invisible.
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

        let countSignature = BrainRegion.display.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined()
            + WorkSection.allCases.map { "\($0.rawValue)=\(workSections[$0] ?? 0)" }.joined()
        if context.coordinator.lastCountSignature != countSignature {
            context.coordinator.lastCountSignature = countSignature
            BrainSceneBuilder.rebuildCallouts(counts: counts, workSections: workSections, in: uiView.scene)
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
        var lastCountSignature = ""
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
/// **Why it looks the way it does.** Two earlier versions failed in opposite
/// directions. Additive lines on a transparent page were a tangle, because a
/// wireframe you can see through has no near and far. A lit translucent solid
/// was a blob, because its folds were too shallow to shade and shading is the
/// only thing a solid has. The reference the look is now built to is a
/// *scan*: glowing ridges on dark, the far side fading, the rim lit, the
/// crests sparkling. Four things make that:
///
/// - the fold pattern is baked into **vertex colour**, so a ridge is bright
///   and a sulcus is nearly black whatever the lighting;
/// - the tissue is drawn **additively, nearest layer only**, so the far side
///   is hidden and the near side glows;
/// - a **Fresnel rim** in a fragment shader lights the silhouette, which is
///   what every hologram in every film has and what makes a translucent
///   thing look like it has an edge;
/// - the ridge crests are also drawn as a **point cloud**, which is where
///   the sparkle comes from.
enum BrainSceneBuilder {
    static let cameraName = "camera"
    static let filesName = "files"
    static let calloutsName = "callouts"
    static let labelName = "label"
    private static let filePrefix = "file."
    private static let wirePrefix = "wire."

    /// How close the camera has to get before a node says what it is.
    static let labelRevealDistance: Float = 2.7

    /// Past this many nodes the scene stops being readable long before it stops
    /// being fast, so the model shows the newest and the list below shows the
    /// rest.
    static let maximumNodes = 120

    /// Where the cerebellum sits, under and behind the cerebrum.
    static let cerebellumOffset = SIMD3<Float>(0, -0.48, -0.66)

    /// How far above the cortex a document sits, as a multiple of the surface
    /// radius. Just enough to clear the folds; a node buried in a sulcus is a
    /// node you cannot tap.
    static let nodeLift: Float = 1.06
    /// Filaments run a hair above the surface, so the tissue never hides them.
    static let wireLift: Float = 1.02
    /// How far out a region's callout tag sits from the cortex.
    static let calloutReach: Float = 0.62

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

        let callouts = SCNNode()
        callouts.name = calloutsName
        scene.rootNode.addChildNode(callouts)

        scene.rootNode.addChildNode(camera())
        scene.rootNode.addChildNode(ambient())
        return scene
    }

    private static func cerebrum() -> SCNNode {
        surfaceNode(for: BrainMesh.surface(.cerebrum))
    }

    private static func cerebellum() -> SCNNode {
        let node = surfaceNode(for: BrainMesh.surface(.cerebellum))
        node.position = SCNVector3(cerebellumOffset.x, cerebellumOffset.y, cerebellumOffset.z)
        return node
    }

    /// Three passes over the same vertices: the glowing tissue, a faint
    /// wireframe that shows through to the far side, and the ridge points.
    private static func surfaceNode(for surface: BrainMesh.Surface) -> SCNNode {
        let node = SCNNode()

        let tissue = SCNNode(geometry: BrainMesh.tissue(from: surface, tint: Palette.tissueTint))
        tissue.geometry?.firstMaterial = tissueMaterial()
        tissue.renderingOrder = RenderOrder.tissue
        node.addChildNode(tissue)

        let wire = SCNNode(geometry: BrainMesh.wire(from: surface))
        wire.geometry?.firstMaterial = wireMaterial()
        // A whisker larger than the tissue, so the lines sit on the surface
        // instead of fighting it for the same depth.
        wire.scale = SCNVector3(1.006, 1.006, 1.006)
        wire.renderingOrder = RenderOrder.wire
        node.addChildNode(wire)

        if let cloud = BrainMesh.ridgePoints(from: surface, tint: Palette.sparkTint) {
            let points = SCNNode(geometry: cloud)
            points.geometry?.firstMaterial = pointMaterial()
            points.scale = SCNVector3(1.012, 1.012, 1.012)
            points.renderingOrder = RenderOrder.points
            node.addChildNode(points)
        }
        return node
    }

    private static func stem() -> SCNNode {
        let geometry = BrainMesh.stem()
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Palette.wire.withAlphaComponent(0.22)
        material.emission.contents = Palette.wire.withAlphaComponent(0.22)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: fresnelShader]
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, -0.72, -0.40)
        node.eulerAngles = SCNVector3(0.55, 0, 0)
        node.renderingOrder = RenderOrder.tissue
        return node
    }

    /// The light in the middle. Seen faintly through the tissue, breathing —
    /// it is what says *this thing is on* rather than a museum piece.
    private static func core() -> SCNNode {
        let geometry = SCNSphere(radius: 0.11)
        geometry.segmentCount = 24

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.emission.contents = Palette.core.withAlphaComponent(0.7)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, -0.05, 0.05)
        node.renderingOrder = RenderOrder.core
        node.runAction(
            .repeatForever(
                .sequence([
                    .scale(to: 1.18, duration: 1.9),
                    .scale(to: 0.90, duration: 1.9)
                ])
            )
        )
        return node
    }

    // MARK: - Callouts

    /// One tag per region: a dot on the cortex, a line out from it, and a
    /// label at the end naming what is stored there and how much.
    ///
    /// This is what turns a model into a *map*. Without it you have to already
    /// know that the frontal lobe is Work; with it, the brain tells you — and
    /// the Work tag's second line answers "where are my reminders" without a
    /// tap.
    static func rebuildCallouts(
        counts: [BrainRegion: Int],
        workSections: [WorkSection: Int],
        in scene: SCNScene?
    ) {
        guard let container = scene?.rootNode.childNode(withName: calloutsName, recursively: true) else {
            return
        }
        container.childNodes.forEach { $0.removeFromParentNode() }

        for region in BrainRegion.display {
            let direction = anchor(for: region)
            let base = cortex(toward: direction, region: region, lift: wireLift)
            let tip = base + direction * calloutReach
            let tint = UIColor(region.tint)

            let dot = SCNNode(geometry: SCNSphere(radius: 0.022))
            dot.geometry?.firstMaterial = glowMaterial(tint, alpha: 1)
            dot.position = SCNVector3(base.x, base.y, base.z)
            dot.renderingOrder = RenderOrder.callout
            container.addChildNode(dot)

            if let line = filaments(
                [SCNVector3(base.x, base.y, base.z), SCNVector3(tip.x, tip.y, tip.z)],
                tint: tint,
                alpha: 0.85
            ) {
                line.renderingOrder = RenderOrder.callout
                container.addChildNode(line)
            }

            var detail = ""
            if region == .work {
                detail = WorkSection.allCases
                    .map { "\($0.title.uppercased()) \(workSections[$0] ?? 0)" }
                    .joined(separator: "  ·  ")
            } else {
                detail = region.anatomy.uppercased()
            }
            let tag = calloutTag(
                title: "\(region.title.uppercased())  \(counts[region] ?? 0)",
                detail: detail,
                tint: tint
            )
            // Sits just past the end of the line, offset upward so the line
            // points at its lower-left corner rather than through its middle.
            tag.position = SCNVector3(tip.x, tip.y + 0.09, tip.z)
            container.addChildNode(tag)
        }
    }

    /// A HUD tag: a bracket, a title line, a smaller detail line. Billboarded
    /// and drawn over everything, because a label you can't read is noise.
    private static func calloutTag(title: String, detail: String, tint: UIColor) -> SCNNode {
        let plane = SCNPlane(width: 0.86, height: 0.215)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = calloutImage(title: title, detail: detail, tint: tint)
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material

        let node = SCNNode(geometry: plane)
        node.renderingOrder = RenderOrder.label
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func calloutImage(title: String, detail: String, tint: UIColor) -> UIImage {
        let size = CGSize(width: 688, height: 172)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let box = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            UIColor.black.withAlphaComponent(0.62).setFill()
            UIBezierPath(rect: box).fill()

            // The bracket: a bright bar down the left and short ticks at the
            // corners, which is the visual grammar of every scan overlay.
            tint.setFill()
            UIBezierPath(rect: CGRect(x: box.minX, y: box.minY, width: 6, height: box.height)).fill()
            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: box.maxX - 34, y: box.minY))
            tick.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            tick.addLine(to: CGPoint(x: box.maxX, y: box.minY + 34))
            tick.move(to: CGPoint(x: box.maxX - 34, y: box.maxY))
            tick.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            tick.addLine(to: CGPoint(x: box.maxX, y: box.maxY - 34))
            tint.withAlphaComponent(0.9).setStroke()
            tick.lineWidth = 4
            tick.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail

            let titleFont = UIFont.monospacedSystemFont(ofSize: 52, weight: .semibold)
            (title as NSString).draw(
                in: CGRect(x: box.minX + 28, y: box.minY + 22, width: box.width - 60, height: 64),
                withAttributes: [.font: titleFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
            )

            let detailFont = UIFont.monospacedSystemFont(ofSize: 32, weight: .regular)
            (detail as NSString).draw(
                in: CGRect(x: box.minX + 28, y: box.minY + 96, width: box.width - 60, height: 48),
                withAttributes: [.font: detailFont, .foregroundColor: tint, .paragraphStyle: paragraph]
            )
            _ = context
        }
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

            if let filaments = filaments(wire, tint: UIColor(region.tint), alpha: 0.5) {
                filaments.name = wirePrefix + region.rawValue
                filaments.renderingOrder = RenderOrder.filament
                container.addChildNode(filaments)
            }
        }
    }

    private static func node(for file: BrainSceneFile, at position: SIMD3<Float>) -> SCNNode {
        let geometry = SCNSphere(radius: 0.03)
        geometry.segmentCount = 12
        geometry.firstMaterial = glowMaterial(UIColor(file.region.tint), alpha: 1)

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
            let path = UIBezierPath(roundedRect: box, cornerRadius: 12)
            UIColor.black.withAlphaComponent(0.74).setFill()
            path.fill()
            tint.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 3
            path.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .medium),
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
    /// middle of it, and since the tissue hides what is behind it, a chord
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

    /// A run of line segments as a single geometry — one node per wire would
    /// be a hundred draw calls for something nobody taps.
    private static func filaments(_ points: [SCNVector3], tint: UIColor, alpha: CGFloat) -> SCNNode? {
        guard points.count >= 2 else { return nil }
        let indices = (0..<Int32(points.count)).map { $0 }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: points)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        geometry.firstMaterial = glowMaterial(tint, alpha: alpha)
        geometry.firstMaterial?.writesToDepthBuffer = false
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
        case .work: return simd_normalize(SIMD3<Float>(0.40, 0.42, 1.00))
        case .friends: return simd_normalize(SIMD3<Float>(-0.46, 0.96, -0.30))
        case .media: return simd_normalize(SIMD3<Float>(1.00, -0.18, 0.12))
        case .images: return simd_normalize(SIMD3<Float>(0.10, 0.30, -1.05))
        case .family: return simd_normalize(SIMD3<Float>(-1.00, -0.10, 0.34))
        case .general: return simd_normalize(SIMD3<Float>(0.30, -0.50, -1.00))
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
        let right = simd_normalize(simd_cross(reference, axis))
        let forward = simd_cross(axis, right)

        let goldenAngle: Float = 2.39996
        let angle = Float(index) * goldenAngle
        // Spread grows with the square root of the index, which is what keeps a
        // spiral evenly dense rather than crowded in the middle.
        let spread = 0.55 * sqrt(Float(index + 1) / Float(max(total, 1)))
        let offset = right * (cos(angle) * spread) + forward * (sin(angle) * spread)
        return simd_normalize(axis + offset)
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
        let cosine = max(-1, min(1, simd_dot(from, to)))
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
        camera.fieldOfView = 38
        camera.zNear = 0.05
        camera.zFar = 120
        // The glow is the look, so let the bright ridges and rim bloom.
        camera.bloomIntensity = 0.85
        camera.bloomBlurRadius = 14
        camera.bloomThreshold = 0.45
        node.camera = camera
        node.transform = defaultCameraTransform()
        return node
    }

    /// In profile, from slightly front and above: the view a brain is
    /// recognised in, with the frontal lobe, the temporal lobe under its
    /// fissure, the occipital lobe and the cerebellum all in silhouette.
    private static func defaultCameraTransform() -> SCNMatrix4 {
        let node = SCNNode()
        node.position = SCNVector3(4.0, 0.8, 1.3)
        node.look(
            at: SCNVector3(0, -0.08, -0.05),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 0, -1)
        )
        return node.transform
    }

    /// Everything in the scene is unlit and additive, so the only light that
    /// does anything is a faint ambient that keeps SceneKit from complaining.
    private static func ambient() -> SCNNode {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = .ambient
        node.light?.intensity = 200
        node.light?.color = UIColor.white
        return node
    }

    // MARK: - Materials

    /// The tissue: unlit, so the vertex colour *is* the surface; additive, so
    /// it glows on the dark stage; nearest layer only, so the far side is
    /// hidden and the shape has a front and a back; with a Fresnel rim in the
    /// fragment shader so the silhouette lights up.
    private static func tissueMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.blendMode = .add
        material.transparency = 0.82
        material.transparencyMode = .singleLayer
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.shaderModifiers = [.fragment: fresnelShader]
        return material
    }

    /// The mesh as lines, faint, and drawn *without* a depth test so the far
    /// side shows through — that faint far side is what gives a hologram its
    /// volume, and at this alpha it never becomes the tangle it was when the
    /// lines were the whole drawing.
    private static func wireMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.fillMode = .lines
        material.diffuse.contents = Palette.wire.withAlphaComponent(0.10)
        material.emission.contents = Palette.wire.withAlphaComponent(0.10)
        material.blendMode = .add
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    /// The ridge crests as points, near side only.
    private static func pointMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.blendMode = .add
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    /// Nodes, dots and lines: unlit and self-luminous.
    private static func glowMaterial(_ tint: UIColor, alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = tint.withAlphaComponent(alpha)
        material.emission.contents = tint.withAlphaComponent(alpha)
        if alpha < 1 { material.blendMode = .add }
        return material
    }

    /// Brightens the surface where it turns away from the camera.
    ///
    /// The one effect a translucent thing cannot fake with colour: its edge.
    /// `_surface.view` and `_surface.normal` are both in view space, so their
    /// dot product is how squarely this fragment faces the camera; the rim is
    /// the complement of that, sharpened. If SceneKit rejects the modifier on
    /// some device it logs and draws the material without it, which is a
    /// duller brain rather than no brain.
    private static let fresnelShader = """
    #pragma transparent
    #pragma body
    float facing = clamp(dot(normalize(_surface.view), _surface.normal), 0.0, 1.0);
    float rim = pow(1.0 - facing, 2.4);
    _output.color.rgb += vec3(0.34, 0.86, 1.0) * rim * 1.1;
    _output.color.a = clamp(_output.color.a + rim * 0.5, 0.0, 1.0);
    """

    /// The order things are drawn in. Transparent parts are sorted by this
    /// before distance, and everything here shares the same centre, so leaving
    /// it to distance would shuffle the layers between frames.
    private enum RenderOrder {
        static let core = 5
        static let tissue = 10
        static let wire = 20
        static let points = 25
        static let filament = 30
        static let callout = 40
        static let label = 100
    }

    /// One place to change the whole look.
    enum Palette {
        /// Near-black navy. The stage is this colour in both appearances.
        static let stage = UIColor(red: 0.020, green: 0.032, blue: 0.075, alpha: 1)
        static let wire = UIColor(red: 0.42, green: 0.86, blue: 1.00, alpha: 1)
        static let core = UIColor(red: 0.72, green: 0.94, blue: 1.00, alpha: 1)
        /// The ridge colour, as the vertex shader wants it.
        static let tissueTint = SIMD3<Float>(0.30, 0.78, 1.00)
        static let sparkTint = SIMD3<Float>(0.75, 0.96, 1.00)
    }
}
