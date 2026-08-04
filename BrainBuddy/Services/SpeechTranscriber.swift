import AVFoundation
import Foundation
import Observation
import Speech

/// Speech-to-text for both halves of the app: transcribing recorded voice notes
/// so they become searchable, and live dictation so you can *ask* your brain a
/// question out loud.
@MainActor
@Observable
final class SpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case engineFailure(String)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is off. Turn it on in Settings › Brain Buddy."
            case .recognizerUnavailable:
                return "Speech recognition isn't available for this language right now."
            case .engineFailure(let reason):
                return "Couldn't listen: \(reason)"
            case .transcriptionFailed(let reason):
                return "Couldn't transcribe the recording: \(reason)"
            }
        }
    }

    private(set) var isListening = false
    private(set) var liveTranscript = ""

    /// Called once with the final text when a dictation session ends.
    var onFinalTranscript: ((String) -> Void)?

    /// Stop listening automatically after this much silence. `nil` disables it.
    var autoStopAfterSilence: TimeInterval? = 2.5

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWatcher: Task<Void, Never>?
    private var lastTranscriptChange = Date()
    private var didDeliverFinalTranscript = false

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    // MARK: - Authorization

    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Live dictation

    func startListening() async throws {
        guard !isListening else { return }
        guard await Self.requestAuthorization() else { throw TranscriberError.notAuthorized }
        guard await AudioRecorder.requestPermission() else { throw TranscriberError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.recognizerUnavailable }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw TranscriberError.engineFailure(error.localizedDescription)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer the on-device model when the OS has one: nothing you say leaves
        // the phone, and it keeps working without a connection.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        liveTranscript = ""
        didDeliverFinalTranscript = false
        lastTranscriptChange = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The handler fires on a private queue; hop back before touching state.
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    self.lastTranscriptChange = Date()
                    if result.isFinal { self.finishListening() }
                }
                if error != nil { self.finishListening() }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            tearDownEngine()
            throw TranscriberError.engineFailure("no audio input is available")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDownEngine()
            throw TranscriberError.engineFailure(error.localizedDescription)
        }

        isListening = true
        startSilenceWatcher()
    }

    /// Ends audio capture and waits for the recognizer's final pass.
    func stopListening() {
        guard isListening else { return }
        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        request?.endAudio()
        isListening = false

        // Give the recognizer a moment to emit its final, punctuated result; if
        // it does not, deliver whatever we already have.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.finishListening()
        }
    }

    func cancelListening() {
        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        didDeliverFinalTranscript = true
        liveTranscript = ""
    }

    private func finishListening() {
        guard !didDeliverFinalTranscript else { return }
        didDeliverFinalTranscript = true

        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        task?.finish()
        task = nil
        request = nil
        isListening = false

        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinalTranscript?(text) }
    }

    private func tearDownEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func startSilenceWatcher() {
        guard let window = autoStopAfterSilence else { return }
        silenceWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isListening else { return }
                // Only auto-stop once something has actually been said.
                guard !self.liveTranscript.isEmpty else { continue }
                if Date().timeIntervalSince(self.lastTranscriptChange) >= window {
                    self.stopListening()
                    return
                }
            }
        }
    }

    // MARK: - File transcription

    /// Longest slice handed to the recognizer in one request.
    ///
    /// `SFSpeechURLRecognitionRequest` is built for utterances, not hour-long
    /// conversations: past roughly a minute it starts returning a truncated
    /// result or nothing at all. Splitting the audio is what lets a recorded
    /// discussion be transcribed in full rather than for its first minute.
    static let segmentLength: TimeInterval = 45

    /// Transcribes a finished recording. Used right after a voice note is saved
    /// so the note is searchable by its words, not just its date.
    ///
    /// - Parameters:
    ///   - duration: known length in seconds; read from the file when omitted.
    ///   - progress: called with `(completed, total)` segments for long
    ///     recordings, so the UI can say something better than "Transcribing…"
    ///     for several minutes.
    static func transcribe(
        fileAt url: URL,
        duration: TimeInterval = 0,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> String {
        guard await requestAuthorization() else { throw TranscriberError.notAuthorized }
        let recognizer = try makeRecognizer()

        let asset = AVURLAsset(url: url)
        let length = duration > 0
            ? duration
            : ((try? await asset.load(.duration))?.seconds ?? 0)

        // The overwhelming majority of voice notes are short; those go straight
        // through in one request, exactly as before.
        guard length > segmentLength * 1.25 else {
            progress?(0, 1)
            let text = try await recognize(fileAt: url, using: recognizer)
            progress?(1, 1)
            return text
        }

        return try await transcribeInSegments(
            asset: asset,
            length: length,
            recognizer: recognizer,
            progress: progress
        )
    }

    /// Walks a long recording in `segmentLength` slices, exporting each to a
    /// temporary file and transcribing it.
    ///
    /// A failed slice is skipped rather than fatal: one unintelligible minute in
    /// the middle of a meeting must not cost the other thirty-nine.
    private static func transcribeInSegments(
        asset: AVURLAsset,
        length: TimeInterval,
        recognizer: SFSpeechRecognizer,
        progress: ((Int, Int) -> Void)?
    ) async throws -> String {
        let total = max(1, Int((length / segmentLength).rounded(.up)))
        var pieces: [String] = []
        var failures: [String] = []

        for index in 0..<total {
            progress?(index, total)
            let start = Double(index) * segmentLength
            let span = min(segmentLength, length - start)
            guard span > 0.5 else { break }

            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: span, preferredTimescale: 600)
            )

            do {
                let segmentURL = try await exportSegment(of: asset, range: range)
                defer { try? FileManager.default.removeItem(at: segmentURL) }
                let piece = try await recognize(fileAt: segmentURL, using: recognizer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        progress?(total, total)

        guard !pieces.isEmpty else {
            throw TranscriberError.transcriptionFailed(
                failures.first ?? "no speech was recognized in it"
            )
        }
        return pieces.joined(separator: " ")
    }

    /// Copies one time range out to its own m4a file for the recognizer to read.
    private static func exportSegment(of asset: AVURLAsset, range: CMTimeRange) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.transcriptionFailed("this recording can't be split")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-segment-\(UUID().uuidString).m4a")
        session.timeRange = range

        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
            return output
        }

        // `exportAsynchronously` is deprecated in iOS 18, which is why the modern
        // call above is preferred when it exists.
        session.outputURL = output
        session.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw TranscriberError.transcriptionFailed(
                session.error?.localizedDescription ?? "a piece of the recording couldn't be read"
            )
        }
        return output
    }

    private static func makeRecognizer() throws -> SFSpeechRecognizer {
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.recognizerUnavailable }
        return recognizer
    }

    private static func recognize(fileAt url: URL, using recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Punctuation is what makes a long transcript readable — and it's what
        // lets the summarizer find sentence boundaries at all.
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            // `recognitionTask` can call back more than once; make sure the
            // continuation is resumed exactly once.
            let hasResumed = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if hasResumed.claim() { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                if hasResumed.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

/// Tiny thread-safe latch guarding single-resume of a continuation.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
