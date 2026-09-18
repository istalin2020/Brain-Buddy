import Foundation
import SceneKit
import simd

/// The brain, as maths.
///
/// There is no mesh file in this repository and there shouldn't be: a scanned
/// brain is tens of megabytes, needs a licence, and has to be re-exported every
/// time the look changes. This builds the surface from a formula instead — an
/// ellipsoid, folded — and hands back not just the shape but **how folded each
/// point is**, because that number is what the hologram is drawn with.
///
/// What makes a sphere read as a brain, in order of how much it matters:
///
/// 1. **Gyri you can see.** Real gyri are long, winding ridges, locally
///    parallel, crossing at odd angles — a fingerprint wrapped over a sphere.
///    Three layered sine waves gave ripples; this is a *warped stripe field*
///    that produces ridges of the right shape, sharpened so the crests are
///    narrow and bright and the valleys wide and dark.
/// 2. **The two fissures.** The longitudinal fissure down the middle splits
///    the hemispheres; the sylvian fissure is the deep angled groove on each
///    side that the temporal lobe hangs beneath. Those two grooves are the
///    silhouette of a brain in profile.
/// 3. **Proportion and landmarks.** Longer than tall, taller than wide; a
///    rounded frontal lobe, an occipital lobe that pulls down at the back,
///    the temporal bulge, and a flat base to sit on the stem.
enum BrainMesh {
    /// Everything adjustable, in one place, so the shape can be tuned without
    /// reading the generator.
    struct Shape {
        /// Latitude bands. Fine, because the fold pattern is drawn *through*
        /// the mesh — a coarse mesh smooths the ridges into nothing.
        var rings = 110
        /// Longitude divisions.
        var segments = 180
        /// Width, height, depth. A human cerebrum is roughly 14 × 9 × 17 cm.
        var size = SIMD3<Float>(0.82, 0.72, 1.08)
        /// How far a ridge crest stands above a valley.
        var gyriDepth: Float = 0.065
        /// How deep the midline groove is. This is what makes two hemispheres.
        var fissureDepth: Float = 0.30
        /// How wide the midline groove is, as a fraction of the width.
        var fissureWidth: Float = 0.20
        /// How deep the sylvian groove is cut into each side.
        var sylvianDepth: Float = 0.10
        /// 0 for the cerebrum; the cerebellum uses tight parallel ridges.
        var ridged = false

        static let cerebrum = Shape()

        static let cerebellum = Shape(
            rings: 44,
            segments: 72,
            size: SIMD3<Float>(0.50, 0.30, 0.38),
            gyriDepth: 0.045,
            fissureDepth: 0.08,
            fissureWidth: 0.18,
            sylvianDepth: 0,
            ridged: true
        )
    }

    /// One point of the surface, and how folded the surface is there:
    /// `+1` on a ridge crest, `-1` at the bottom of a sulcus.
    struct Sample {
        var position: SIMD3<Float>
        var fold: Float
    }

    // MARK: - The fold field

    /// Axes the ridge field is laid out along. Three, deliberately not
    /// orthogonal and not aligned with the mesh, so no seam or pole shows in
    /// the pattern.
    private enum Axes {
        static let a = simd_normalize(SIMD3<Float>(0.30, 1.00, 0.20))
        static let b = simd_normalize(SIMD3<Float>(1.00, 0.10, -0.40))
        static let c = simd_normalize(SIMD3<Float>(-0.20, 0.30, 1.00))
    }

    /// How folded the cortex is in a given direction, from −1 to 1.
    ///
    /// A stripe field — `sin(k · a)` for a coordinate `a` across the surface —
    /// gives parallel ridges. Warping `a` with lower-frequency waves in the
    /// other two coordinates makes those ridges wind, branch and merge the way
    /// gyri do. A second, weaker set crosses the first, and a fine wrinkle
    /// sits on top. Then `tanh` sharpens the whole thing: narrow bright crests,
    /// wide dark valleys, which is the proportion real tissue has.
    static func fold(toward direction: SIMD3<Float>, shape: Shape) -> Float {
        let d = normalizedOrUp(direction)

        if shape.ridged {
            // The cerebellum's folia: fine, tightly packed, running around it.
            let phi = acos(max(-1, min(1, d.y)))
            let theta = atan2(d.z, d.x)
            let folia = 0.85 * sin(30 * phi + 1.5 * sin(3 * theta)) + 0.20 * sin(11 * theta)
            return tanh(2.0 * folia)
        }

        let a = simd_dot(d, Axes.a)
        let b = simd_dot(d, Axes.b)
        let c = simd_dot(d, Axes.c)

        let warp = 0.55 * sin(3.1 * b + 0.9)
            + 0.35 * sin(4.7 * c + 2.3)
            + 0.22 * sin(6.9 * a * b + 1.1)
        let primary = sin(11.5 * (a + warp))
        let crossing = sin(8.5 * (c + 0.45 * sin(5.2 * a + 0.4) + 0.30 * sin(3.7 * b)))
        let fine = sin(23.0 * (b + 0.30 * sin(9.0 * c)))

        return tanh(1.7 * (0.70 * primary + 0.38 * crossing + 0.12 * fine))
    }

    // MARK: - Surface

    /// One point of the surface, for `u` around and `v` from top to bottom.
    ///
    /// Pure and `static` so the same function draws the mesh and places
    /// anything that needs to sit *on* it.
    static func sample(u: Float, v: Float, shape: Shape) -> Sample {
        let theta = u * 2 * .pi
        let phi = v * .pi

        let sinPhi = sin(phi)
        let direction = normalizedOrUp(SIMD3<Float>(
            sinPhi * cos(theta),
            cos(phi),
            sinPhi * sin(theta)
        ))

        let fold = self.fold(toward: direction, shape: shape)
        var radius: Float = 1 + shape.gyriDepth * fold

        // The midline groove, cut on the top half only — underneath, the two
        // hemispheres are joined.
        let acrossMidline = direction.x / max(shape.fissureWidth, 0.001)
        let midline = exp(-acrossMidline * acrossMidline)
        radius -= shape.fissureDepth * midline * max(0, direction.y)

        // The sylvian fissure: an angled groove on each side, rising towards
        // the front, with the temporal lobe hanging below it. Cut only on the
        // flanks, and only between the back of the temporal lobe and the
        // forehead.
        if shape.sylvianDepth > 0 {
            let flank = pow(abs(direction.x), 1.4)
            let grooveHeight: Float = -0.02 + 0.25 * direction.z
            let acrossGroove = (direction.y - grooveHeight) / 0.13
            let groove = exp(-acrossGroove * acrossGroove)
            let span = max(0, min(1, (direction.z + 0.60) / 0.30))
                * max(0, min(1, (0.75 - direction.z) / 0.30))
            radius -= shape.sylvianDepth * groove * flank * span
        }

        var point = direction * radius * shape.size

        // The front narrows towards the forehead and rounds off; the back is
        // narrower and pulls down, the way the occipital lobe does.
        let front = max(0, point.z)
        point.x *= 1 - 0.20 * front
        point.y *= 1 - 0.10 * front

        let back = max(0, -point.z)
        point.x *= 1 - 0.16 * back
        point.y -= 0.08 * back * max(0, point.y)

        // Temporal bulge: the lobe that hangs down at the side, above the ear.
        let side = abs(point.x)
        let low = max(0, -point.y - 0.05)
        let forwardOfEar = max(0, point.z + 0.35)
        point.x += (point.x < 0 ? -1 : 1) * 0.30 * side * low * min(1, forwardOfEar)

        // A brain sits on a base rather than coming to a point. Compressed
        // rather than clamped, so no two rings collapse onto each other and
        // leave degenerate triangles.
        let floorLevel: Float = -0.40
        if point.y < floorLevel {
            point.y = floorLevel + (point.y - floorLevel) * 0.42
        }

        return Sample(position: point, fold: fold)
    }

    static func point(u: Float, v: Float, shape: Shape) -> SIMD3<Float> {
        sample(u: u, v: v, shape: shape).position
    }

    /// The surface, looked up by direction rather than by parameter.
    ///
    /// Documents sit *on* the cortex, and to put one there you need to know how
    /// far out the surface is in that direction. Inverting the parameterisation
    /// is close enough — the deformations move points a little off their ray,
    /// but a node a hair above or below a fold still reads as being on it.
    static func surfacePoint(toward direction: SIMD3<Float>, shape: Shape = .cerebrum) -> SIMD3<Float> {
        let unit = normalizedOrUp(direction)
        let phi = acos(max(-1, min(1, unit.y)))
        var theta = atan2(unit.z, unit.x)
        if theta < 0 { theta += 2 * .pi }
        return point(u: theta / (2 * .pi), v: phi / .pi, shape: shape)
    }

    // MARK: - Geometry

    /// The whole surface, computed once and shared by everything drawn from
    /// it: the tissue, the wireframe and the ridge points all come from these
    /// same vertices.
    struct Surface {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var folds: [Float] = []
        var triangles: [Int32] = []
        var rings = 0
        var segments = 0
    }

    static func surface(_ shape: Shape) -> Surface {
        var surface = Surface(rings: shape.rings, segments: shape.segments)
        let count = (shape.rings + 1) * (shape.segments + 1)
        surface.positions.reserveCapacity(count)
        surface.normals.reserveCapacity(count)
        surface.folds.reserveCapacity(count)

        let step: Float = 0.002

        for ring in 0...shape.rings {
            let v = Float(ring) / Float(shape.rings)
            for segment in 0...shape.segments {
                let u = Float(segment) / Float(shape.segments)
                let here = sample(u: u, v: v, shape: shape)
                surface.positions.append(here.position)
                surface.folds.append(here.fold)

                // Central differences. Cheaper than deriving the analytic
                // normal of a surface this fiddly, and exact enough for a rim
                // light.
                let along = point(u: u + step, v: v, shape: shape)
                    - point(u: u - step, v: v, shape: shape)
                let down = point(u: u, v: min(1, v + step), shape: shape)
                    - point(u: u, v: max(0, v - step), shape: shape)
                surface.normals.append(
                    normalizedOrUp(simd_cross(down, along), fallback: normalizedOrUp(here.position))
                )
            }
        }

        surface.triangles.reserveCapacity(shape.rings * shape.segments * 6)
        let stride = shape.segments + 1
        for ring in 0..<shape.rings {
            for segment in 0..<shape.segments {
                let topLeft = Int32(ring * stride + segment)
                let topRight = topLeft + 1
                let bottomLeft = Int32((ring + 1) * stride + segment)
                let bottomRight = bottomLeft + 1
                surface.triangles.append(contentsOf: [topLeft, bottomLeft, topRight])
                surface.triangles.append(contentsOf: [topRight, bottomLeft, bottomRight])
            }
        }
        return surface
    }

    /// The tissue: triangles, with a colour per vertex that carries the fold.
    ///
    /// This is the whole trick of the look. The material is unlit and drawn
    /// additively, so what you see *is* the vertex colour — a ridge crest is
    /// bright, a sulcus is nearly black, and from any distance the surface
    /// reads as glowing folds on dark rather than as a smooth lit egg.
    static func tissue(from surface: Surface, tint: SIMD3<Float>) -> SCNGeometry {
        let colors: [SIMD4<Float>] = surface.folds.map { fold in
            let crest = max(0, fold)
            let brightness = 0.10 + 0.90 * pow(crest, 1.3)
            return SIMD4<Float>(tint * brightness, 1)
        }
        return SCNGeometry(
            sources: [
                vertexSource(surface.positions),
                normalSource(surface.normals),
                colorSource(colors)
            ],
            elements: [SCNGeometryElement(indices: surface.triangles, primitiveType: .triangles)]
        )
    }

    /// The same triangles with no colour, for drawing as lines.
    static func wire(from surface: Surface) -> SCNGeometry {
        SCNGeometry(
            sources: [vertexSource(surface.positions), normalSource(surface.normals)],
            elements: [SCNGeometryElement(indices: surface.triangles, primitiveType: .triangles)]
        )
    }

    /// The ridge crests as a cloud of points — the sparkle along every fold
    /// that the reference footage has, and that a wireframe alone never does.
    /// Every other vertex above the crest threshold, so the cloud is dense on
    /// the gyri and empty in the sulci.
    static func ridgePoints(from surface: Surface, tint: SIMD3<Float>, threshold: Float = 0.45) -> SCNGeometry? {
        var indices: [Int32] = []
        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(surface.positions.count)

        let stride = surface.segments + 1
        for (index, fold) in surface.folds.enumerated() {
            let ring = index / stride
            let segment = index % stride
            let crest = max(0, fold)
            colors.append(SIMD4<Float>(tint * (0.4 + 0.6 * crest), 1))
            guard fold >= threshold, (ring + segment) % 2 == 0 else { continue }
            indices.append(Int32(index))
        }
        guard !indices.isEmpty else { return nil }

        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 2.4
        element.minimumPointScreenSpaceRadius = 0.8
        element.maximumPointScreenSpaceRadius = 3.0

        return SCNGeometry(
            sources: [vertexSource(surface.positions), colorSource(colors)],
            elements: [element]
        )
    }

    /// The brain stem, tapering as it leaves the base.
    static func stem() -> SCNGeometry {
        SCNCone(topRadius: 0.13, bottomRadius: 0.06, height: 0.62)
    }

    // MARK: - Sources

    private static func vertexSource(_ positions: [SIMD3<Float>]) -> SCNGeometrySource {
        SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
    }

    private static func normalSource(_ normals: [SIMD3<Float>]) -> SCNGeometrySource {
        SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
    }

    /// Four floats per vertex, RGBA. Built through the general initializer
    /// because there is no convenience one for colours.
    private static func colorSource(_ colors: [SIMD4<Float>]) -> SCNGeometrySource {
        let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
    }

    // MARK: - Helpers

    /// `simd_normalize` of a zero vector is `NaN`, and one `NaN` vertex takes
    /// the whole mesh with it.
    private static func normalizedOrUp(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared > 1e-9, lengthSquared.isFinite else { return fallback }
        return vector / sqrt(lengthSquared)
    }
}
