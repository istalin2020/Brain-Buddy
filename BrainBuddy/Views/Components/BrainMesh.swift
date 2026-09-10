import SceneKit
import simd

/// The brain, as maths.
///
/// There is no mesh file in this repository and there shouldn't be: a scanned
/// brain is tens of megabytes, needs a licence, and has to be re-exported every
/// time the look changes. This builds the surface from a formula instead — an
/// ellipsoid, folded.
///
/// Four things turn a sphere into something recognisable as a brain:
///
/// 1. **Proportion.** Longer front-to-back than it is tall, and taller than it
///    is wide. Get this wrong and no amount of detail rescues it.
/// 2. **Gyri.** Layered sine waves at different frequencies along both axes,
///    which is enough to read as folded tissue once it's drawn as a wireframe.
/// 3. **The longitudinal fissure** — the deep groove down the middle separating
///    the hemispheres. This is the single feature that makes a blob look like a
///    brain, so it is cut deliberately rather than left to the noise.
/// 4. **A flat underside and a tapered front**, because a brain sits on a base
///    and narrows towards the forehead.
enum BrainMesh {
    /// Everything adjustable, in one place, so the shape can be tuned without
    /// reading the generator.
    struct Shape {
        /// Latitude bands. More is smoother and costs triangles.
        var rings = 56
        /// Longitude divisions.
        var segments = 88
        /// Width, height, depth. A human cerebrum is roughly 14 × 9 × 17 cm.
        var size = SIMD3<Float>(0.80, 0.68, 1.02)
        /// How deep the folds are cut.
        var gyriDepth: Float = 0.052
        /// How deep the midline groove is.
        var fissureDepth: Float = 0.20
        /// How wide the midline groove is, as a fraction of the width.
        var fissureWidth: Float = 0.20
        /// 0 for the cerebrum; the cerebellum uses tight parallel ridges.
        var ridged = false

        static let cerebrum = Shape()

        static let cerebellum = Shape(
            rings: 28,
            segments: 44,
            size: SIMD3<Float>(0.46, 0.26, 0.34),
            gyriDepth: 0.05,
            fissureDepth: 0.06,
            fissureWidth: 0.16,
            ridged: true
        )
    }

    // MARK: - Surface

    /// One point of the surface, for `u` around and `v` from top to bottom.
    ///
    /// Pure and `static` so the same function draws the mesh and places anything
    /// that needs to sit *on* it.
    static func point(u: Float, v: Float, shape: Shape) -> SIMD3<Float> {
        let theta = u * 2 * .pi
        let phi = v * .pi

        let sinPhi = sin(phi)
        var direction = SIMD3<Float>(
            sinPhi * cos(theta),
            cos(phi),
            sinPhi * sin(theta)
        )
        direction = normalizedOrUp(direction)

        var radius: Float = 1

        // Folds. Three frequencies, deliberately not harmonics of each other, so
        // the pattern doesn't visibly repeat around the surface.
        if shape.ridged {
            radius += shape.gyriDepth * sin(26 * phi) * 0.8
            radius += shape.gyriDepth * 0.35 * sin(9 * theta + 2 * phi)
        } else {
            let coarse = sin(9 * phi + 2.6 * cos(4 * theta))
            let medium = sin(7.5 * theta + 1.7 * phi)
            let fine = sin(15 * phi + 4.5 * theta)
            radius += shape.gyriDepth * (0.55 * coarse * medium + 0.28 * fine)
        }

        // The midline groove, cut on the top half only — underneath, the two
        // hemispheres are joined.
        let acrossMidline = direction.x / max(shape.fissureWidth, 0.001)
        let midline = exp(-acrossMidline * acrossMidline)
        let topHalf = max(0, direction.y)
        radius -= shape.fissureDepth * midline * topHalf

        var point = direction * radius * shape.size

        // The front narrows towards the forehead; the back is rounder but
        // pulls in low.
        let front = max(0, point.z)
        point.x *= 1 - 0.20 * front
        point.y *= 1 - 0.10 * front

        let back = max(0, -point.z)
        point.x *= 1 - 0.14 * back

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

        return point
    }

    // MARK: - Geometry

    static func geometry(_ shape: Shape) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity((shape.rings + 1) * (shape.segments + 1))
        normals.reserveCapacity(vertices.capacity)

        let step: Float = 0.0025

        for ring in 0...shape.rings {
            let v = Float(ring) / Float(shape.rings)
            for segment in 0...shape.segments {
                let u = Float(segment) / Float(shape.segments)
                let position = point(u: u, v: v, shape: shape)
                vertices.append(SCNVector3(position.x, position.y, position.z))

                // Central differences. Cheaper than deriving the analytic
                // normal of a surface this fiddly, and accurate enough for
                // lighting a hologram.
                let along = point(u: u + step, v: v, shape: shape)
                    - point(u: u - step, v: v, shape: shape)
                let down = point(u: u, v: min(1, v + step), shape: shape)
                    - point(u: u, v: max(0, v - step), shape: shape)

                let normal = normalizedOrUp(cross(down, along), fallback: normalizedOrUp(position))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }

        var indices: [Int32] = []
        indices.reserveCapacity(shape.rings * shape.segments * 6)
        let stride = shape.segments + 1

        for ring in 0..<shape.rings {
            for segment in 0..<shape.segments {
                let topLeft = Int32(ring * stride + segment)
                let topRight = topLeft + 1
                let bottomLeft = Int32((ring + 1) * stride + segment)
                let bottomRight = bottomLeft + 1
                indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }

    /// The brain stem, tapering as it leaves the base.
    static func stem() -> SCNGeometry {
        SCNCone(topRadius: 0.13, bottomRadius: 0.06, height: 0.62)
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
