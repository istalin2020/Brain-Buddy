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
        /// Latitude bands. Fewer than you'd think: the wireframe is drawn from
        /// these, and a fine mesh blurs into haze while a coarser one reads as
        /// folds.
        var rings = 44
        /// Longitude divisions.
        var segments = 72
        /// Width, height, depth. A human cerebrum is roughly 14 × 9 × 17 cm.
        var size = SIMD3<Float>(0.84, 0.70, 1.06)
        /// How deep the folds are cut. Deep enough to shade — a fold that only
        /// shows in the wireframe is a fold nobody sees.
        var gyriDepth: Float = 0.078
        /// How deep the midline groove is. This is what makes two hemispheres.
        var fissureDepth: Float = 0.36
        /// How wide the midline groove is, as a fraction of the width.
        var fissureWidth: Float = 0.24
        /// 0 for the cerebrum; the cerebellum uses tight parallel ridges.
        var ridged = false

        static let cerebrum = Shape()

        static let cerebellum = Shape(
            rings: 26,
            segments: 40,
            size: SIMD3<Float>(0.50, 0.28, 0.36),
            gyriDepth: 0.06,
            fissureDepth: 0.10,
            fissureWidth: 0.18,
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
            // The bands run roughly front-to-back and curve, the way sulci do,
            // with a finer wrinkle on top so no two folds look alike.
            let coarse = sin(8.0 * phi + 2.4 * cos(3.0 * theta))
            let medium = sin(6.5 * theta + 1.9 * phi)
            let fine = sin(13.0 * phi + 4.0 * theta + 0.8 * sin(5.0 * theta))
            radius += shape.gyriDepth * (0.60 * coarse * medium + 0.40 * fine)
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
