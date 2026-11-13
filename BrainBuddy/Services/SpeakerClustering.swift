import Foundation

/// Decides how many people are talking in a recording, and which utterance
/// is whose.
///
/// Average-linkage agglomerative clustering over `SpeakerFeatures` voice
/// descriptions, with one fixed threshold: two groups of utterances are the
/// same person until they sound further apart than `threshold`. Because the
/// distance has a fixed scale, "everybody here is one person" is an answer it
/// can give — the common case of a note to yourself must not come back as a
/// conversation.
///
/// **What it was tuned on, and how well it does.** The constants were chosen in
/// a prototype against recordings with known speakers: AMI meeting excerpts
/// (real meetings, far microphones, people talking over each other) and
/// speakers taken from public speech datasets. There, it never split one
/// person into two, and it was never less accurate than calling everybody one
/// person; voices that clearly differ — a man and a woman, a deep voice and a
/// light one — were separated almost perfectly. Two similar voices in a short
/// recording are often left together. It leans that way on purpose: a
/// transcript with no names is what you had before, while a transcript that
/// puts your words in someone else's mouth is worse than none.
enum SpeakerClustering {
    /// Pooled within-recording spread of each of the thirteen numbers. Dividing
    /// by it puts timbre and pitch on one scale.
    static let scale: [Float] = [
        4.408, 3.995, 3.685, 2.852, 1.939, 1.961, 2.016,
        1.455, 1.514, 1.361, 1.228, 0.8745, 0.1471
    ]
    /// Pitch counts double: it separates voices best of all thirteen.
    static let pitchWeight: Float = 2.0
    /// Mean distance, per dimension, beyond which two groups are two people.
    static let threshold: Float = 1.7
    /// What an utterance needs before it may found a group of its own.
    static let reliableFrames = 40
    static let reliableDuration: TimeInterval = 1.2
    /// A "person" heard for less than this is folded into the nearest one.
    static let minimumSpeakerSeconds: TimeInterval = 6
    static let minimumSpeakerShare = 0.08
    /// The most utterances that found groups; the rest join the nearest.
    static let maximumFounders = 400

    struct Utterance {
        var voice: SpeakerFeatures.Voice?
        var duration: TimeInterval
    }

    struct Result: Equatable {
        /// Speaker index per utterance, numbered in order of first appearance.
        var labels: [Int]
        var speakerCount: Int
    }

    static func assign(_ utterances: [Utterance]) -> Result {
        let count = utterances.count
        guard count > 0 else { return Result(labels: [], speakerCount: 0) }

        let dimension = scale.count
        let root = Float(dimension).squareRoot()
        let points: [[Float]?] = utterances.map { utterance in
            guard let vector = utterance.voice?.vector, vector.count == dimension else { return nil }
            return (0..<dimension).map { index in
                vector[index] / scale[index] * (index == dimension - 1 ? pitchWeight : 1)
            }
        }

        func isReliable(_ index: Int) -> Bool {
            guard points[index] != nil, let voice = utterances[index].voice else { return false }
            return voice.voicedFrames >= reliableFrames && utterances[index].duration >= reliableDuration
        }

        var founders = (0..<count).filter(isReliable)
        if founders.count > maximumFounders {
            // The longest say the most about a voice.
            founders = Array(founders.sorted { utterances[$0].duration > utterances[$1].duration }
                .prefix(maximumFounders))
                .sorted()
        }
        guard founders.count >= 2 else {
            return Result(labels: Array(repeating: 0, count: count), speakerCount: 1)
        }

        // Average linkage: the distance between two groups is the mean of the
        // distances between their members, kept up to date as groups merge.
        var clusters: [[Int]] = founders.map { [$0] }
        var distance: [[Float]] = founders.map { a in
            founders.map { b in euclidean(points[a]!, points[b]!) / root }
        }
        while clusters.count > 1 {
            var best: (value: Float, i: Int, j: Int)?
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count where best == nil || distance[i][j] < best!.value {
                    best = (distance[i][j], i, j)
                }
            }
            guard let best, best.value <= threshold else { break }
            let (i, j) = (best.i, best.j)
            let sizeI = Float(clusters[i].count), sizeJ = Float(clusters[j].count)
            for k in 0..<clusters.count where k != i && k != j {
                let merged = (sizeI * distance[i][k] + sizeJ * distance[j][k]) / (sizeI + sizeJ)
                distance[i][k] = merged
                distance[k][i] = merged
            }
            clusters[i] += clusters[j]
            clusters.remove(at: j)
            distance.remove(at: j)
            for row in distance.indices { distance[row].remove(at: j) }
        }

        // Too little speech to be somebody: fold it into whoever is nearest.
        let seconds = { (members: [Int]) in members.reduce(0.0) { $0 + utterances[$1].duration } }
        let total = seconds(founders)
        let floor = max(minimumSpeakerSeconds, minimumSpeakerShare * total)
        var speakers = clusters.filter { seconds($0) >= floor }
        if speakers.isEmpty, let largest = clusters.max(by: { seconds($0) < seconds($1) }) {
            speakers = [largest]
        }

        let centres: [[Float]] = speakers.map { members in
            var centre = [Float](repeating: 0, count: dimension)
            var weight: Float = 0
            for member in members {
                let w = Float(utterances[member].duration)
                for index in 0..<dimension { centre[index] += points[member]![index] * w }
                weight += w
            }
            return centre.map { $0 / max(weight, 1e-9) }
        }

        // Every utterance goes to the nearest voice. A short one is too thin
        // to overrule the conversation's flow: unless it is clearly someone
        // else, it stays with whoever was talking.
        var raw: [Int] = []
        var previous: Int?
        for index in 0..<count {
            guard let point = points[index] else {
                raw.append(previous ?? 0)
                continue
            }
            let distances = centres.map { euclidean(point, $0) }
            var nearest = 0
            for candidate in distances.indices where distances[candidate] < distances[nearest] {
                nearest = candidate
            }
            if !isReliable(index), let previous, distances[previous] - distances[nearest] < 0.5 * root {
                nearest = previous
            }
            raw.append(nearest)
            previous = nearest
        }

        var order: [Int: Int] = [:]
        let labels = raw.map { label -> Int in
            if let known = order[label] { return known }
            order[label] = order.count
            return order[label]!
        }
        return Result(labels: labels, speakerCount: order.count)
    }

    static func euclidean(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var sum: Float = 0
        for index in lhs.indices { sum += (lhs[index] - rhs[index]) * (lhs[index] - rhs[index]) }
        return sum.squareRoot()
    }
}
