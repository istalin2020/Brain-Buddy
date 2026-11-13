import XCTest
import simd
@testable import BrainBuddy

/// The generated brain. A mesh with one `NaN` in it renders as nothing at
/// all, silently, so the numbers are checked here where a failure can say so.
final class BrainMeshTests: XCTestCase {
    func testEveryVertexIsFinite() {
        for shape in [BrainMesh.Shape.cerebrum, BrainMesh.Shape.cerebellum] {
            let surface = BrainMesh.surface(shape)
            for position in surface.positions {
                XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
            }
            for normal in surface.normals {
                XCTAssertTrue(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
                XCTAssertEqual(simd_length(normal), 1, accuracy: 0.01, "normals are unit length")
            }
        }
    }

    func testTheSurfaceHasTheExpectedTopology() {
        let shape = BrainMesh.Shape.cerebrum
        let surface = BrainMesh.surface(shape)
        XCTAssertEqual(surface.positions.count, (shape.rings + 1) * (shape.segments + 1))
        XCTAssertEqual(surface.normals.count, surface.positions.count)
        XCTAssertEqual(surface.folds.count, surface.positions.count)
        XCTAssertEqual(surface.triangles.count, shape.rings * shape.segments * 6)
        XCTAssertLessThan(Int(surface.triangles.max() ?? 0), surface.positions.count, "every index points at a vertex")
    }

    /// The fold value is what the tissue is coloured with; it has to stay in
    /// range or the colour source overflows.
    func testFoldsStayWithinMinusOneAndOne() {
        let surface = BrainMesh.surface(.cerebrum)
        XCTAssertTrue(surface.folds.allSatisfy { $0 >= -1 && $0 <= 1 })
        XCTAssertTrue(surface.folds.contains { $0 > 0.6 }, "there are ridges")
        XCTAssertTrue(surface.folds.contains { $0 < -0.6 }, "and sulci")
    }

    /// The point cloud only exists where there are ridges.
    func testRidgePointsSitOnCrests() throws {
        let surface = BrainMesh.surface(.cerebrum)
        let cloud = try XCTUnwrap(BrainMesh.ridgePoints(from: surface, tint: SIMD3<Float>(1, 1, 1)))
        XCTAssertEqual(cloud.elements.first?.primitiveType, .point)
        XCTAssertGreaterThan(cloud.elements.first?.primitiveCount ?? 0, 100)
        XCTAssertLessThan(cloud.elements.first?.primitiveCount ?? 0, surface.positions.count / 2)
    }

    /// Documents are placed by direction; every direction has to land on the
    /// surface, including straight up and straight down where the
    /// parameterisation is singular.
    func testSurfacePointIsFiniteInEveryDirection() {
        let directions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0), SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0.3, -0.5, -1),
            SIMD3<Float>(0, 0, 0)
        ]
        for direction in directions {
            let point = BrainMesh.surfacePoint(toward: direction)
            XCTAssertTrue(point.x.isFinite && point.y.isFinite && point.z.isFinite, "\(direction)")
            XCTAssertGreaterThan(simd_length(point), 0.2, "\(direction) is on the surface, not at the centre")
        }
    }

    /// The silhouette: longer than tall, taller than wide, and split down the
    /// middle on top.
    func testTheShapeHasBrainProportionsAndAFissure() {
        let surface = BrainMesh.surface(.cerebrum)
        let xs = surface.positions.map(\.x)
        let ys = surface.positions.map(\.y)
        let zs = surface.positions.map(\.z)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        let length = (zs.max() ?? 0) - (zs.min() ?? 0)
        XCTAssertGreaterThan(length, height)
        XCTAssertGreaterThan(height, width * 0.8)

        let top = BrainMesh.surfacePoint(toward: SIMD3<Float>(0, 1, 0))
        let besideTop = BrainMesh.surfacePoint(toward: simd_normalize(SIMD3<Float>(0.35, 1, 0)))
        XCTAssertLessThan(top.y, besideTop.y, "the midline sits in a groove")
    }
}
