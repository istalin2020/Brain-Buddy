import Foundation

/// Small vector helpers plus the on-disk encoding for cached embeddings.
enum VectorMath {
    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }

    static func mean(of vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first else { return nil }
        let dimension = first.count
        guard vectors.allSatisfy({ $0.count == dimension }) else { return nil }
        var total = [Double](repeating: 0, count: dimension)
        for vector in vectors {
            for index in 0..<dimension { total[index] += vector[index] }
        }
        let count = Double(vectors.count)
        return total.map { $0 / count }
    }

    static func normalized(_ vector: [Double]) -> [Double] {
        let magnitude = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// Stores as `Float32` — half the bytes of `Double` with no measurable
    /// effect on cosine ranking, and these are mirrored to CloudKit.
    static func encode(_ vector: [Double]) -> Data {
        var floats = vector.map { Float($0) }
        return floats.withUnsafeMutableBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func decode(_ data: Data) -> [Double]? {
        let stride = MemoryLayout<Float>.size
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        var floats = [Float](repeating: 0, count: data.count / stride)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map { Double($0) }
    }
}
