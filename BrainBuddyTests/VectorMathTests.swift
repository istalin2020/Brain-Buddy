import XCTest
@testable import BrainBuddy

final class VectorMathTests: XCTestCase {
    func testCosineOfIdenticalVectorsIsOne() {
        let vector = [0.2, -0.5, 0.9, 0.1]
        XCTAssertEqual(VectorMath.cosineSimilarity(vector, vector), 1.0, accuracy: 0.0001)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
    }

    func testCosineHandlesMismatchedAndEmptyInput() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(VectorMath.cosineSimilarity([], []), 0)
        XCTAssertEqual(VectorMath.cosineSimilarity([0, 0], [1, 1]), 0)
    }

    func testMeanRequiresMatchingDimensions() {
        XCTAssertNil(VectorMath.mean(of: []))
        XCTAssertNil(VectorMath.mean(of: [[1, 2], [1, 2, 3]]))
        XCTAssertEqual(VectorMath.mean(of: [[0, 4], [2, 0]]) ?? [], [1, 2])
    }

    func testNormalizedVectorHasUnitLength() {
        let normalized = VectorMath.normalized([3, 4])
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)
    }

    func testNormalizingZeroVectorDoesNotDivideByZero() {
        XCTAssertEqual(VectorMath.normalized([0, 0]), [0, 0])
    }

    /// Embeddings survive the round trip through the `Data` blob that CloudKit
    /// mirrors, within `Float32` precision.
    func testEncodeDecodeRoundTrip() {
        let original = [0.125, -0.5, 0.75, 1.0]
        guard let decoded = VectorMath.decode(VectorMath.encode(original)) else {
            return XCTFail("decode returned nil")
        }
        XCTAssertEqual(decoded.count, original.count)
        for (lhs, rhs) in zip(decoded, original) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.0001)
        }
    }

    func testDecodeRejectsMisalignedData() {
        XCTAssertNil(VectorMath.decode(Data([0x01, 0x02, 0x03])))
        XCTAssertNil(VectorMath.decode(Data()))
    }
}
