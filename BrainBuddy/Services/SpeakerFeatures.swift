import Accelerate
import Foundation

/// A short description of what a voice sounds like, taken from one utterance.
///
/// Thirteen numbers: the average shape of the voice's spectrum (twelve
/// mel-frequency cepstral coefficients — the standard "timbre" measure in
/// speech processing) and its typical pitch. Two people rarely match on both.
/// It is not a voiceprint and is never stored; it exists for the length of one
/// transcription, to tell the voices in a recording apart.
///
/// Every constant here was chosen and checked in a prototype against recorded
/// meetings with known speakers (`SpeakerClustering` explains the results), and
/// the unit tests pin this code to that prototype's numbers. Change a constant
/// here and the clustering threshold no longer means what it was tuned to mean.
///
/// Audio is 16 kHz mono, the format `RecordingTranscriber` decodes to.
enum SpeakerFeatures {
    static let sampleRate = 16_000

    /// 10 ms between frames.
    static let hop = 160
    /// 25 ms spectrum frames, zero-padded to 512 points.
    static let spectrumWindow = 400
    static let fftSize = 512
    static let melBands = 26
    static let cepstra = 12
    /// 40 ms pitch frames: two periods of the lowest voice it looks for.
    static let pitchWindow = 640
    static let minimumLag = 16_000 / 400   // 400 Hz
    static let maximumLag = 16_000 / 70    // 70 Hz
    /// How periodic a frame must be to count as voiced speech.
    static let voicing: Float = 0.55
    /// At most this many frames per utterance, spread evenly across it.
    static let frameCap = 300

    /// One utterance's description, and how many voiced frames it rests on.
    struct Voice: Equatable {
        /// Twelve cepstra averaged over the voiced frames, then the median
        /// natural log of the pitch in hertz.
        var vector: [Float]
        var voicedFrames: Int
    }

    /// Describes the voice in `samples[range]`, or `nil` when it holds fewer
    /// than five voiced frames — too little to say anything about.
    static func voice(in samples: [Float], range: Range<Int>) -> Voice? {
        let frames = voicedFrames(in: samples, range: range)
        guard frames.count >= 5 else { return nil }

        var vector = [Float](repeating: 0, count: cepstra + 1)
        for frame in frames {
            for index in 0..<cepstra { vector[index] += frame.cepstra[index] }
        }
        for index in 0..<cepstra { vector[index] /= Float(frames.count) }
        vector[cepstra] = median(frames.map { log($0.pitch) })
        return Voice(vector: vector, voicedFrames: frames.count)
    }

    struct Frame {
        var cepstra: [Float]
        /// Hertz.
        var pitch: Float
    }

    /// The voiced frames in `samples[range]`, at most `frameCap` of them.
    static func voicedFrames(in samples: [Float], range: Range<Int>) -> [Frame] {
        let lower = max(0, range.lowerBound)
        let upper = min(samples.count, range.upperBound)
        guard upper - pitchWindow > lower else { return [] }

        var starts = Array(stride(from: lower, to: upper - pitchWindow, by: hop))
        if starts.count > frameCap {
            // `np.linspace(0, n - 1, cap).astype(int)` in the prototype.
            let last = Double(starts.count - 1)
            starts = (0..<frameCap).map { index in
                starts[Int(Double(index) * last / Double(frameCap - 1))]
            }
        }

        let analyzer = Analyzer.shared
        return starts.compactMap { analyzer.frame(in: samples, at: $0) }
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - The arithmetic

    /// The transforms and tables, built once.
    final class Analyzer: @unchecked Sendable {
        static let shared = Analyzer()

        private let spectrumDFT: vDSP.DiscreteFourierTransform<Float>
        private let pitchForward: vDSP.DiscreteFourierTransform<Float>
        private let pitchInverse: vDSP.DiscreteFourierTransform<Float>
        private let pitchSize = 2048
        private let hamming: [Float]
        /// Per band: the first bin it covers and its weights from there.
        private let filters: [(start: Int, weights: [Float])]
        private let cosines: [[Float]]
        /// The transforms keep scratch state, so one frame at a time.
        private let lock = NSLock()

        private init() {
            // Sizes are powers of two, which these transforms always accept.
            spectrumDFT = try! vDSP.DiscreteFourierTransform(
                previous: nil, count: SpeakerFeatures.fftSize,
                direction: .forward, transformType: .complexComplex, ofType: Float.self
            )
            pitchForward = try! vDSP.DiscreteFourierTransform(
                previous: nil, count: 2048,
                direction: .forward, transformType: .complexComplex, ofType: Float.self
            )
            pitchInverse = try! vDSP.DiscreteFourierTransform(
                previous: nil, count: 2048,
                direction: .inverse, transformType: .complexComplex, ofType: Float.self
            )

            let window = SpeakerFeatures.spectrumWindow
            hamming = (0..<window).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(window - 1)) }

            filters = Self.melFilters()
            let bands = SpeakerFeatures.melBands
            cosines = (1...SpeakerFeatures.cepstra).map { order in
                (0..<bands).map { band in
                    Float(cos(Double.pi * Double(order) * (Double(band) + 0.5) / Double(bands)))
                }
            }
        }

        private static func mel(_ hertz: Double) -> Double { 2595 * log10(1 + hertz / 700) }
        private static func hertz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        /// Triangular filters evenly spaced on the mel scale, 100 Hz to 7 kHz.
        private static func melFilters() -> [(start: Int, weights: [Float])] {
            let bands = SpeakerFeatures.melBands
            let size = SpeakerFeatures.fftSize
            let low = mel(100), high = mel(7000)
            let edges = (0..<(bands + 2)).map { index -> Double in
                let m = low + (high - low) * Double(index) / Double(bands + 1)
                return hertz(m) * Double(size) / Double(SpeakerFeatures.sampleRate)
            }
            return (0..<bands).map { band in
                let left = edges[band], centre = edges[band + 1], right = edges[band + 2]
                var start = -1
                var weights: [Float] = []
                for bin in 0...(size / 2) {
                    let k = Double(bin)
                    var weight = 0.0
                    if left < k, k <= centre {
                        weight = (k - left) / (centre - left)
                    } else if centre < k, k < right {
                        weight = (right - k) / (right - centre)
                    }
                    guard weight > 0 else { continue }
                    if start < 0 { start = bin }
                    // Bins inside one triangle are contiguous.
                    weights.append(Float(weight))
                }
                return (max(start, 0), weights)
            }
        }

        func frame(in samples: [Float], at start: Int) -> Frame? {
            let window = SpeakerFeatures.pitchWindow
            guard start >= 0, start + window <= samples.count else { return nil }

            var segment = Array(samples[start..<(start + window)])
            let mean = vDSP.mean(segment)
            segment = vDSP.add(-mean, segment)
            let energy = vDSP.sumOfSquares(segment)
            guard energy >= 1e-6 * Float(window) else { return nil }

            lock.lock()
            defer { lock.unlock() }

            guard let pitch = pitch(of: segment) else { return nil }

            // The spectrum frame sits in the middle of the pitch frame.
            let centre = start + (window - SpeakerFeatures.spectrumWindow) / 2
            let cepstra = self.cepstra(of: Array(samples[centre..<(centre + SpeakerFeatures.spectrumWindow)]))
            return Frame(cepstra: cepstra, pitch: pitch)
        }

        /// Normalised autocorrelation between 70 and 400 Hz; the strongest lag
        /// wins, if it is periodic enough to be a voice.
        private func pitch(of segment: [Float]) -> Float? {
            let n = segment.count
            var real = segment + [Float](repeating: 0, count: pitchSize - n)
            var imaginary = [Float](repeating: 0, count: pitchSize)
            let spectrum = pitchForward.transform(inputReal: real, inputImaginary: imaginary)
            real = vDSP.add(vDSP.square(spectrum.real), vDSP.square(spectrum.imaginary))
            imaginary = [Float](repeating: 0, count: pitchSize)
            // The inverse is unscaled: it returns the autocorrelation times N.
            let correlation = vDSP.divide(
                pitchInverse.transform(inputReal: real, inputImaginary: imaginary).real,
                Float(pitchSize)
            )

            // Running energy, so each lag's normalisation is two lookups.
            var prefix = [Float](repeating: 0, count: n + 1)
            for index in 0..<n { prefix[index + 1] = prefix[index] + segment[index] * segment[index] }
            let total = prefix[n]

            var best: Float = 0
            var bestLag = 0
            for lag in SpeakerFeatures.minimumLag...SpeakerFeatures.maximumLag where lag < n {
                let head = prefix[n - lag]
                let tail = total - prefix[lag]
                let value = correlation[lag] / ((head * tail).squareRoot() + 1e-12)
                if value > best {
                    best = value
                    bestLag = lag
                }
            }
            guard best >= SpeakerFeatures.voicing, bestLag > 0 else { return nil }
            return Float(SpeakerFeatures.sampleRate) / Float(bestLag)
        }

        private func cepstra(of frame: [Float]) -> [Float] {
            let size = SpeakerFeatures.fftSize
            let windowed = vDSP.multiply(frame, hamming) + [Float](repeating: 0, count: size - frame.count)
            let spectrum = spectrumDFT.transform(
                inputReal: windowed,
                inputImaginary: [Float](repeating: 0, count: size)
            )
            let power = vDSP.add(
                vDSP.square(Array(spectrum.real[0...(size / 2)])),
                vDSP.square(Array(spectrum.imaginary[0...(size / 2)]))
            )

            let logEnergies: [Float] = filters.map { filter in
                var sum: Float = 0
                for (offset, weight) in filter.weights.enumerated() where filter.start + offset < power.count {
                    sum += weight * power[filter.start + offset]
                }
                return log(sum + 1e-10)
            }
            return cosines.map { row in vDSP.dot(row, logEnergies) }
        }
    }
}
