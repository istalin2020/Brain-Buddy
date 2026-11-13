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
/// - **Every utterance is kept** (`PassCollector`). Apple's recognizer quietly
///   starts a new utterance inside the same request after a pause, and its
///   final result holds only the last one. Taking just that result is how a
///   fourteen-minute meeting came back as 118 words — one sentence from each
///   slice. Partial results are followed instead, and each utterance is banked
///   as the next one begins.
/// - **Slices are short** — about fourteen seconds, ending in a pause — so a
///   request rarely spans more than a couple of utterances, and the timing of
///   each is known closely even when the recognizer doesn't report it.
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
    static let sliceLength: TimeInterval = 14
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
        // Partial results are how the utterances before the last one are seen
        // at all: see `PassCollector`.
        request.shouldReportPartialResults = true
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

        let duration = Double(samples.count) / sampleRate
        let run = RecognitionRun(duration: duration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.begin(continuation)
                run.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let transcription = result.bestTranscription
                        run.receive(
                            text: transcription.formattedString,
                            words: RecordingTranscriber.words(in: transcription)
                        )
                        if result.isFinal {
                            run.finishWithWords()
                            return
                        }
                    }
                    // An error after words were heard — often "no speech" for
                    // the silence at the end — still keeps the words.
                    if let error { run.finishWithWords(orFail: error) }
                }
                // A recognizer that never answers must not hang the note forever.
                let limit = UInt64((duration * 2 + 60) * 1_000_000_000)
                Task {
                    try? await Task.sleep(nanoseconds: limit)
                    run.finishWithWords(orFail: Failure.unreadable("the recognizer took too long"))
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

/// Collects every utterance a recognition request reports.
///
/// The recognizer starts a new utterance inside the same request after a
/// pause — no signal, no `isFinal`, just a transcript that suddenly reads as
/// something else — and the final result carries only the last utterance.
/// `SpeechTranscriber.continues` recognises the switch from the text, as live
/// dictation does; the utterance that was running is banked then.
///
/// Timings are repaired as well (`words(duration:)`): an utterance may come
/// with no timings, or with timings counted from its own start rather than
/// the request's. Either way it is placed after the one before it, so the
/// words stay in order and voices can still be measured.
struct PassCollector {
    typealias Word = SpeakerTranscript.Word

    private(set) var passes: [[Word]] = []
    private var current: [Word] = []
    private var currentText = ""

    mutating func receive(text: String, words: [Word]) {
        if !SpeechTranscriber.continues(text, from: currentText), !Self.revises(text, currentText) {
            bank()
        }
        current = words
        currentText = text
    }

    /// The same utterance with its first word changed — "Sun drawings are
    /// late" becoming "The drawings are late" — rather than a new one.
    static func revises(_ incoming: String, _ previous: String) -> Bool {
        let new = normalizedWords(incoming), old = normalizedWords(previous)
        guard new.count >= 4, old.count >= 4 else { return false }
        return Array(new.dropFirst().prefix(3)) == Array(old.dropFirst().prefix(3))
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    mutating func bank() {
        if !current.isEmpty { passes.append(current) }
        current = []
        currentText = ""
    }

    var isEmpty: Bool { passes.isEmpty && current.isEmpty }

    /// Every word heard, in order, timed within `0...duration`.
    func words(duration: TimeInterval) -> [Word] {
        var all = passes
        if !current.isEmpty { all.append(current) }

        var result: [Word] = []
        var index = 0
        while index < all.count {
            let pass = all[index]
            let lastEnd = result.last?.end ?? 0
            let isTimed = pass.contains { $0.end > 0 }

            if isTimed {
                var shift: TimeInterval = 0
                if let first = pass.first, !result.isEmpty, first.start < lastEnd - 0.25 {
                    // Counted from its own start: place it after the last one.
                    shift = lastEnd + 0.3 - first.start
                }
                result += pass.map { Word(text: $0.text, start: $0.start + shift, end: $0.end + shift) }
                index += 1
                continue
            }

            // Untimed: share out the time until the next timed utterance, or
            // the end of the slice, among this and any untimed ones after it.
            var untimed: [[Word]] = []
            while index < all.count, !all[index].contains(where: { $0.end > 0 }) {
                untimed.append(all[index])
                index += 1
            }
            let nextStart = index < all.count ? (all[index].first?.start ?? duration) : duration
            let from = result.isEmpty ? 0 : lastEnd + 0.1
            let until = max(from, min(duration, nextStart > from ? nextStart : duration))
            let count = untimed.reduce(0) { $0 + $1.count }
            let step = count > 0 ? (until - from) / Double(count) : 0
            var at = from
            for pass in untimed {
                for word in pass {
                    result.append(Word(text: word.text, start: at, end: at + step * 0.9))
                    at += step
                }
            }
        }
        return result.map { word in
            let start = min(max(0, word.start), duration)
            return Word(text: word.text, start: start, end: min(max(start, word.end), duration))
        }
    }
}

/// One recognition request's outcome, delivered exactly once whichever of the
/// recognizer, the time limit or cancellation gets there first.
private final class RecognitionRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[SpeakerTranscript.Word], Error>?
    private var isFinished = false
    private var collector = PassCollector()
    private let duration: TimeInterval
    var task: SFSpeechRecognitionTask?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func receive(text: String, words: [SpeakerTranscript.Word]) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        collector.receive(text: text, words: words)
    }

    /// Finishes with everything heard; with nothing heard, fails with `error`
    /// (or returns no words when there is no error).
    func finishWithWords(orFail error: Error? = nil) {
        lock.lock()
        let collected = collector.isEmpty ? nil : collector.words(duration: duration)
        lock.unlock()
        if let collected {
            finish(.success(collected))
        } else if let error {
            finish(.failure(error))
        } else {
            finish(.success([]))
        }
    }

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

        // Harmless after a final result; stops one that timed out.
        task?.cancel()
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
