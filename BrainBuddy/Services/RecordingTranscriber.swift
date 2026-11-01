import AVFoundation
import Foundation
import Speech

/// Turns a finished recording into text, and says who spoke when it can tell.
///
/// **Why it reads the audio itself.** It used to hand the recognizer 45-second
/// m4a slices exported from the file. A long recording could come back as
/// "No speech detected" for every slice — a meeting recorded across a room is
/// quiet, and the recognizer gives up on quiet audio — and the whole note then
/// had no transcript at all. Now the audio is decoded to 16 kHz samples here,
/// so that:
///
/// - **Quiet audio is brought up** to a level the recognizer accepts
///   (`gain(for:)`), without clipping a loud one.
/// - **Slices end in a pause** (`quietestCut`), so a word is never cut in half
///   at a slice boundary and lost from both.
/// - **A slice with nothing in it is skipped**, and a slice where the
///   recognizer hears nothing is an empty slice — not a failure of the whole
///   recording.
/// - **The same samples tell the voices apart** (`SpeakerFeatures`,
///   `SpeakerClustering`), using the word timings the recognizer reports.
///
/// A recording made of several pieces — it was interrupted and carried on — is
/// read as one continuous stream.
enum RecordingTranscriber {
    struct Transcript: Equatable {
        /// Plain text, or `SpeakerTranscript` turns when there were two or more voices.
        var text: String
        var speakerCount: Int
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case noSpeech(heardSound: Bool)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return "the recording couldn't be read (\(reason))"
            case .noSpeech(let heardSound):
                return heardSound
                    ? "it has sound in it but no words were recognised. Check that Settings › Transcription language matches the language spoken, then use “Transcribe again” on the note."
                    : "no speech could be heard in it — the recording is silent or nearly so"
            }
        }
    }

    static let sampleRate = Double(SpeakerFeatures.sampleRate)
    /// Aim for slices this long…
    static let sliceLength: TimeInterval = 45
    /// …ending in the quietest moment from this long before the aim…
    static let cutLookBack: TimeInterval = 8
    /// …to this long after it.
    static let cutLookAhead: TimeInterval = 4

    /// - Parameter progress: `(slices done, slices expected)`.
    static func transcribe(
        files: [URL],
        recognizer: SFSpeechRecognizer,
        configure: (SFSpeechAudioBufferRecognitionRequest) -> Void,
        progress: @escaping (Int, Int) async -> Void
    ) async throws -> Transcript {
        let reader = try PCMReader(files: files)
        let expected = max(1, Int((reader.duration / sliceLength).rounded(.up)))

        var pending: [Float] = []
        var offset: TimeInterval = 0
        var done = 0
        var utterances: [SpeakerTranscript.Utterance] = []
        var voices: [SpeakerClustering.Utterance] = []
        var failures: [String] = []
        var heardSound = false

        let target = Int(sliceLength * sampleRate)
        let reach = Int((sliceLength + cutLookAhead) * sampleRate)

        while true {
            while pending.count < reach, !reader.isFinished {
                pending += try reader.read(frames: Int(10 * sampleRate))
            }
            guard !pending.isEmpty else { break }

            let cut: Int
            if reader.isFinished, pending.count <= reach {
                cut = pending.count
            } else {
                cut = quietestCut(
                    in: pending,
                    from: target - Int(cutLookBack * sampleRate),
                    to: min(pending.count, target + Int(cutLookAhead * sampleRate))
                )
            }
            let slice = Array(pending[0..<cut])
            pending.removeFirst(cut)

            await progress(done, max(expected, done + 1))
            if let gain = gain(for: slice) {
                heardSound = heardSound || loudness(of: slice) > 0.02
                // The voice measures read the boosted audio too: their
                // "is anyone speaking" floor was set at this level.
                let boosted = slice.map { $0 * gain }
                do {
                    let words = try await recognize(boosted, recognizer: recognizer, configure: configure)
                    for utterance in SpeakerTranscript.utterances(from: words) {
                        let range = Int(utterance.start * sampleRate)..<Int(utterance.end * sampleRate)
                        voices.append(SpeakerClustering.Utterance(
                            voice: SpeakerFeatures.voice(in: boosted, range: range),
                            duration: utterance.end - utterance.start
                        ))
                        utterances.append(SpeakerTranscript.Utterance(
                            text: utterance.text,
                            start: utterance.start + offset,
                            end: utterance.end + offset
                        ))
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            offset += Double(cut) / sampleRate
            done += 1
        }
        await progress(done, done)

        guard !utterances.isEmpty else {
            if let first = failures.first { throw SpeechTranscriber.TranscriberError.transcriptionFailed(first) }
            throw Failure.noSpeech(heardSound: heardSound)
        }

        let speakers = SpeakerClustering.assign(voices)
        guard speakers.speakerCount >= 2 else {
            return Transcript(text: utterances.map(\.text).joined(separator: " "), speakerCount: 1)
        }
        let turns = SpeakerTranscript.turns(utterances, labels: speakers.labels)
        return Transcript(text: SpeakerTranscript.text(of: turns), speakerCount: speakers.speakerCount)
    }

    // MARK: - Slicing and level

    /// The start of the quietest 100 ms between `from` and `to` — where a
    /// slice can end without cutting a word.
    static func quietestCut(in samples: [Float], from: Int, to: Int) -> Int {
        let frame = Int(0.1 * sampleRate)
        let lower = max(frame, from)
        let upper = min(samples.count, to)
        guard upper - frame > lower else { return min(samples.count, max(1, to)) }

        var best = (index: upper, energy: Float.greatestFiniteMagnitude)
        var index = lower
        while index + frame <= upper {
            var energy: Float = 0
            for sample in samples[index..<(index + frame)] { energy += sample * sample }
            if energy < best.energy { best = (index, energy) }
            index += frame / 2
        }
        return best.index
    }

    /// Near-peak level, ignoring the odd click: the 99.9th percentile of
    /// absolute sample values, read off every eighth sample.
    static func loudness(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sampled = stride(from: 0, to: samples.count, by: 8).map { abs(samples[$0]) }.sorted()
        return sampled[min(sampled.count - 1, Int(Double(sampled.count) * 0.999))]
    }

    /// How much to amplify a slice for the recognizer, or `nil` if it is silent.
    ///
    /// Raised so its near-peak sits at 0.7, never by more than 20× (26 dB) —
    /// past that it is mostly amplifying the room — and never turned down.
    static func gain(for samples: [Float]) -> Float? {
        let level = loudness(of: samples)
        guard level >= 0.003 else { return nil }
        return min(20, max(1, 0.7 / level))
    }

    // MARK: - Recognition

    /// One slice through the recognizer, as timed words.
    ///
    /// "No speech detected" is an answer, not an error: one silent minute in a
    /// meeting is ordinary. Anything else is tried once more before it counts.
    private static func recognize(
        _ samples: [Float],
        recognizer: SFSpeechRecognizer,
        configure: (SFSpeechAudioBufferRecognitionRequest) -> Void
    ) async throws -> [SpeakerTranscript.Word] {
        var lastError: Error?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            do {
                return try await recognizeOnce(samples, recognizer: recognizer, configure: configure)
            } catch {
                if isNoSpeech(error) { return [] }
                lastError = error
            }
        }
        throw lastError ?? Failure.unreadable("the recognizer stopped")
    }

    static func isNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == "kAFAssistantErrorDomain", error.code == 1110 { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("no speech")
    }

    private static func recognizeOnce(
        _ samples: [Float],
        recognizer: SFSpeechRecognizer,
        configure: (SFSpeechAudioBufferRecognitionRequest) -> Void
    ) async throws -> [SpeakerTranscript.Word] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw Failure.unreadable("no audio format") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        configure(request)

        // Fed a second at a time, the way live audio arrives.
        let chunk = Int(sampleRate)
        var start = 0
        while start < samples.count {
            let length = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
                  let channel = buffer.floatChannelData?[0] else { break }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: length)
            }
            buffer.frameLength = AVAudioFrameCount(length)
            request.append(buffer)
            start += length
        }
        request.endAudio()

        let run = RecognitionRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.begin(continuation)
                run.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        run.finish(.failure(error))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    run.finish(.success(RecordingTranscriber.words(in: result.bestTranscription)))
                }
                // A recognizer that never answers must not hang the note forever.
                let limit = UInt64((Double(samples.count) / sampleRate * 2 + 60) * 1_000_000_000)
                Task {
                    try? await Task.sleep(nanoseconds: limit)
                    run.finish(.failure(Failure.unreadable("the recognizer took too long")))
                }
            }
        } onCancel: {
            run.finish(.failure(CancellationError()))
        }
    }

    /// Timed words, with the punctuation the recognizer added where it lines up.
    private static func words(in transcription: SFTranscription) -> [SpeakerTranscript.Word] {
        let segments = transcription.segments
        let formatted = transcription.formattedString.split(whereSeparator: \.isWhitespace).map(String.init)
        let useFormatted = formatted.count == segments.count
        var words = segments.enumerated().map { index, segment in
            SpeakerTranscript.Word(
                text: useFormatted ? formatted[index] : segment.substring,
                start: segment.timestamp,
                end: segment.timestamp + segment.duration
            )
        }
        // No timings at all: keep the words, as one stretch.
        if words.isEmpty, !formatted.isEmpty {
            words = [SpeakerTranscript.Word(text: formatted.joined(separator: " "), start: 0, end: 0)]
        }
        return words
    }
}

/// One recognition request's outcome, delivered exactly once whichever of the
/// recognizer, the time limit or cancellation gets there first.
private final class RecognitionRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[SpeakerTranscript.Word], Error>?
    private var isFinished = false
    var task: SFSpeechRecognitionTask?

    func begin(_ continuation: CheckedContinuation<[SpeakerTranscript.Word], Error>) {
        lock.lock()
        defer { lock.unlock() }
        if isFinished {
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<[SpeakerTranscript.Word], Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        lock.unlock()

        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }
}

/// Decodes one or more audio files, in order, to 16 kHz mono samples.
final class PCMReader {
    private var files: [URL]
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let format: AVAudioFormat
    private(set) var isFinished = false
    /// Total length of all the files, in seconds.
    let duration: TimeInterval

    init(files: [URL], sampleRate: Double = RecordingTranscriber.sampleRate) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw RecordingTranscriber.Failure.unreadable("no audio format") }
        self.format = format
        self.files = files
        var total: TimeInterval = 0
        for url in files {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            total += Double(file.length) / file.fileFormat.sampleRate
        }
        guard total > 0 else { throw RecordingTranscriber.Failure.unreadable("it has no audio in it") }
        duration = total
        try openNext()
    }

    private func openNext() throws {
        file = nil
        converter = nil
        while !files.isEmpty {
            let url = files.removeFirst()
            guard let next = try? AVAudioFile(forReading: url), next.length > 0,
                  let converter = AVAudioConverter(from: next.processingFormat, to: format)
            else { continue }
            file = next
            self.converter = converter
            return
        }
        isFinished = true
    }

    /// Up to `frames` samples; fewer only at the very end.
    func read(frames: Int) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(frames)
        while output.count < frames, !isFinished {
            guard let file, let converter else {
                try openNext()
                continue
            }
            let wanted = frames - output.count
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else { break }

            var sourceEnded = false
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { packets, inputStatus in
                let capacity = max(packets, 1024)
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                    inputStatus.pointee = .endOfStream
                    sourceEnded = true
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: capacity)
                } catch {
                    inputStatus.pointee = .endOfStream
                    sourceEnded = true
                    return nil
                }
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    sourceEnded = true
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw RecordingTranscriber.Failure.unreadable(conversionError?.localizedDescription ?? "decoding failed")
            }
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                output += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            }
            if sourceEnded || status == .endOfStream || buffer.frameLength == 0 {
                try openNext()
            }
        }
        return output
    }
}
