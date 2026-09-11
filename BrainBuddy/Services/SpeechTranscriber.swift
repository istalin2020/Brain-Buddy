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
    ///
    /// Two screens dictate through this one recognizer — the Ask field and the
    /// capture editor — so both handlers are assigned at *start of listening*
    /// rather than when a view appears. Otherwise a tab switch silently steals
    /// the other screen's result.
    var onFinalTranscript: ((String) -> Void)?

    /// Called when a session ends however it ended: final text delivered, no
    /// speech recognized, or cancelled outright. Callers that hold state for the
    /// duration of a session need a signal that fires on every path, not only
    /// the happy one.
    var onSessionEnd: (() -> Void)?

    /// Stop listening automatically after this much silence. `nil` disables it.
    var autoStopAfterSilence: TimeInterval? = 2.5

    /// The window in force for the session currently running.
    private var silenceWindow: TimeInterval?

    private let engine = AVAudioEngine()
    /// Lets the audio tap — which runs on a real-time thread — feed whichever
    /// recognition pass is current without knowing when one was swapped out.
    private let requestBox = RecognitionRequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWatcher: Task<Void, Never>?
    private var lastTranscriptChange = Date()
    /// Starts `true`: before any session has run there is nothing left to
    /// deliver, so an early `cancelListening` has no session to end.
    private var didDeliverFinalTranscript = true

    /// Whether a finalized utterance rolls into a new recognition pass instead of
    /// ending the session. See `startListening(autoStop:)`.
    private var isContinuous = false
    /// Text from recognition passes that have already finalized in this session.
    private var committedTranscript = ""
    /// The pass currently in progress, still being revised by the recognizer.
    private var currentPass = ""
    /// Consecutive failures to start a replacement pass, so a broken recognizer
    /// can't spin restarting forever.
    private var consecutiveRestartFailures = 0

    /// Rebuilt only when the language preference changes.
    private var cachedRecognizer: (identifier: String, recognizer: SFSpeechRecognizer)?

    private var recognizer: SFSpeechRecognizer? {
        let locale = Self.preferredLocale
        if let cached = cachedRecognizer, cached.identifier == locale.identifier {
            return cached.recognizer
        }
        guard let built = Self.makeRecognizer(for: locale) else { return nil }
        cachedRecognizer = (locale.identifier, built)
        return built
    }

    // MARK: - Language and accuracy

    /// The language to recognize in.
    ///
    /// Defaults to the device language, which is wrong often enough to be worth a
    /// setting: a recognizer told to expect British English will transcribe Tamil
    /// or Hindi phonetically into English words, producing text that looks like a
    /// transcript and means nothing. For code-switched speech — English technical
    /// vocabulary inside another language, which is how a great many people
    /// actually talk — picking the regional variant (`en-IN`, `ta-IN`) is the
    /// single biggest thing that improves the result.
    nonisolated static var preferredLocale: Locale {
        let identifier = UserDefaults.standard.string(forKey: PreferenceKey.transcriptionLocale) ?? ""
        return identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    }

    /// Whether recognition may leave the device.
    ///
    /// The on-device model is built for short commands and dictation. On a long
    /// multi-speaker recording it degrades badly, and no amount of segmenting
    /// fixes that. Apple's server model is substantially better, at the cost of
    /// the recording leaving the phone — so it is opt-in, and named plainly.
    nonisolated static var allowsServerTranscription: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.serverTranscription)
    }

    /// Languages this device can recognize, for the Settings picker.
    nonisolated static func supportedLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .map { Locale(identifier: $0.identifier) }
            .sorted {
                let left = Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                let right = Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
                return left == right ? $0.identifier < $1.identifier : left < right
            }
    }

    nonisolated private static func makeRecognizer(for locale: Locale) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Applies the accuracy and language preferences to one request.
    nonisolated private static func configure(_ request: SFSpeechRecognitionRequest, using recognizer: SFSpeechRecognizer) {
        // `false` lets the system pick, which means the server model when it can
        // reach it. Only forced on-device when the user hasn't opted in.
        request.requiresOnDeviceRecognition = allowsServerTranscription
            ? false
            : recognizer.supportsOnDeviceRecognition
        // Continuous speech rather than a short command or a search query; the
        // hint measurably changes how the model segments what it hears.
        request.taskHint = .dictation
        // Long transcripts are read, not heard. Without punctuation they're a wall.
        request.addsPunctuation = true
    }

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

    /// - Parameter autoStop: whether a pause ends the session.
    ///
    /// This one flag separates two genuinely different jobs.
    ///
    /// **Asking a question** (`true`) is one utterance: you stop talking, the
    /// recognizer finalizes, the question is asked. That's the Ask tab.
    ///
    /// **Dictating a note** (`false`) is not. `SFSpeechRecognizer` finalizes a
    /// recognition pass whenever you pause — and every pass reports its
    /// transcript from the beginning of *that pass*, so treating a finalized
    /// pass as the end of the session makes dictation appear to erase what you
    /// said and start over the moment you draw breath. In continuous mode a
    /// finalized pass is banked into `committedTranscript` and a fresh pass
    /// starts immediately, over the same still-running audio engine. The session
    /// then ends only when the caller says so.
    ///
    /// The same rollover covers the recognizer's roughly one-minute ceiling on a
    /// single pass, which is otherwise a hard limit on how long you can dictate.
    func startListening(autoStop: Bool = true) async throws {
        guard !isListening else { return }
        guard await Self.requestAuthorization() else { throw TranscriberError.notAuthorized }
        guard await AudioRecorder.requestPermission() else { throw TranscriberError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.recognizerUnavailable }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.default` rather than `.measurement`: measurement mode strips the
            // system's input processing — gain control, noise handling — which is
            // right for taking readings off a signal and wrong for a person
            // talking at a phone lying on a desk. Recognition of quieter or more
            // distant speech is noticeably better with it left on.
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw TranscriberError.engineFailure(error.localizedDescription)
        }

        liveTranscript = ""
        committedTranscript = ""
        currentPass = ""
        consecutiveRestartFailures = 0
        isContinuous = !autoStop
        didDeliverFinalTranscript = false
        lastTranscriptChange = Date()

        try beginRecognitionPass()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            tearDownEngine()
            throw TranscriberError.engineFailure("no audio input is available")
        }

        // The tap outlives any single recognition pass, feeding whichever one is
        // current. Keeping the engine running across a rollover is what keeps the
        // gap between passes down to milliseconds.
        input.removeTap(onBus: 0)
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            box.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDownEngine()
            throw TranscriberError.engineFailure(error.localizedDescription)
        }

        isListening = true
        silenceWindow = autoStop ? autoStopAfterSilence : nil
        startSilenceWatcher()
    }

    /// Starts one recognition pass over the audio the engine is already capturing.
    private func beginRecognitionPass() throws {
        guard let recognizer else { throw TranscriberError.recognizerUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        Self.configure(request, using: recognizer)

        self.request = request
        requestBox.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The handler fires on a private queue; hop back before touching state.
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isListening else { return }

        if let result {
            let incoming = result.bestTranscription.formattedString

            // A pass's transcript is supposed to grow. When it comes back shorter
            // and unrelated instead, the recognizer has silently begun a new
            // utterance *inside the same task* — no `isFinal`, no error, just a
            // fresh transcript. On-device recognition does this after a pause,
            // and it is what made everything already dictated disappear the
            // moment you carried on speaking.
            //
            // So the bank happens here, on the evidence of the text itself,
            // rather than waiting for a signal that never comes.
            if !Self.continues(incoming, from: currentPass) {
                commitCurrentPass()
            }

            currentPass = incoming
            liveTranscript = Self.joined(committedTranscript, currentPass)
            lastTranscriptChange = Date()
            consecutiveRestartFailures = 0

            if result.isFinal {
                rollOverOrFinish()
                return
            }
        }

        if error != nil {
            rollOverOrFinish()
        }
    }

    /// Whether `incoming` extends `previous` rather than replacing it.
    ///
    /// Compared as words, and tolerant of the last couple changing, because a
    /// recognizer legitimately revises its own tail as it hears more — "two" to
    /// "to", "by" to "buy". A transcript that loses more than that, or whose
    /// stable prefix no longer matches, is a different utterance.
    nonisolated static func continues(_ incoming: String, from previous: String) -> Bool {
        let previousWords = words(in: previous)
        guard !previousWords.isEmpty else { return true }

        let incomingWords = words(in: incoming)
        guard !incomingWords.isEmpty else { return false }

        // Once the recognizer has settled on how an utterance opens it doesn't
        // change its mind about the first word. A different one means it is
        // transcribing something else.
        guard incomingWords[0] == previousWords[0] else { return false }

        let revisionSlack = 2
        guard incomingWords.count + revisionSlack >= previousWords.count else { return false }

        let stable = max(1, min(previousWords.count, incomingWords.count) - revisionSlack)
        return Array(incomingWords.prefix(stable)) == Array(previousWords.prefix(stable))
    }

    nonisolated private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// A pass ended. In continuous mode that's a comma, not a full stop.
    private func rollOverOrFinish() {
        commitCurrentPass()
        guard isContinuous else {
            finishListening()
            return
        }

        task = nil
        requestBox.set(nil)
        request = nil

        do {
            try beginRecognitionPass()
        } catch {
            // A recognizer that can't be restarted won't fix itself by being
            // asked again in a tight loop; give it a few spaced attempts, then
            // stop with everything banked so far intact.
            consecutiveRestartFailures += 1
            guard consecutiveRestartFailures < Self.maximumRestartFailures else {
                finishListening()
                return
            }
            // Nothing else would ever try again: rollovers are driven by a live
            // task's callbacks, and right now there isn't one.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isListening, self.isContinuous, self.task == nil else { return }
                self.rollOverOrFinish()
            }
        }
    }

    private static let maximumRestartFailures = 3

    /// Banks the pass in progress so the next one can start from empty without
    /// the transcript appearing to reset.
    private func commitCurrentPass() {
        let text = currentPass.trimmingCharacters(in: .whitespacesAndNewlines)
        currentPass = ""
        guard !text.isEmpty else { return }
        committedTranscript = Self.joined(committedTranscript, text)
        liveTranscript = committedTranscript
    }

    nonisolated private static func joined(_ committed: String, _ pass: String) -> String {
        let addition = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return committed }
        guard !committed.isEmpty else { return addition }
        return committed + " " + addition
    }

    /// Ends audio capture and waits for the recognizer's final pass.
    func stopListening() {
        guard isListening else { return }
        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        request?.endAudio()
        // No more rollovers: the last pass has to be allowed to finalize the
        // session rather than starting another one.
        isContinuous = false

        // `isListening` deliberately stays true until the final result lands.
        // The result handler ignores anything arriving after a session ends, and
        // the whole point of the wait below is to catch that last, better
        // punctuated pass — so the session is not over yet.

        // Give the recognizer a moment to emit its final, punctuated result; if
        // it does not, deliver whatever we already have.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.finishListening()
        }
    }

    func cancelListening() {
        let wasRunning = isListening || !didDeliverFinalTranscript
        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        isContinuous = false
        silenceWindow = nil
        didDeliverFinalTranscript = true
        committedTranscript = ""
        currentPass = ""
        liveTranscript = ""
        if wasRunning { endSession() }
    }

    private func finishListening() {
        guard !didDeliverFinalTranscript else { return }
        didDeliverFinalTranscript = true

        silenceWatcher?.cancel()
        silenceWatcher = nil
        tearDownEngine()
        task?.finish()
        task = nil
        requestBox.set(nil)
        request = nil
        isListening = false
        isContinuous = false
        silenceWindow = nil

        // Whatever the last pass had reached counts too, even if it never got to
        // report itself as final.
        commitCurrentPass()
        let text = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Delivered before the session is torn down, so a handler can commit the
        // text and then clean up in that order.
        if !text.isEmpty { onFinalTranscript?(text) }
        endSession()
    }

    private func endSession() {
        let handler = onSessionEnd
        onFinalTranscript = nil
        onSessionEnd = nil
        handler?()
    }

    private func tearDownEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        requestBox.set(nil)
    }

    private func startSilenceWatcher() {
        guard let window = silenceWindow else { return }
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

    nonisolated private static func makeRecognizer() throws -> SFSpeechRecognizer {
        guard let recognizer = makeRecognizer(for: preferredLocale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        return recognizer
    }

    private static func recognize(fileAt url: URL, using recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        configure(request, using: recognizer)

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

/// Hands the current recognition request to the audio tap.
///
/// The tap runs on a real-time audio thread, so it can't read main-actor state,
/// and it outlives any single recognition pass — continuous dictation swaps the
/// request underneath it every time a pass finalizes. A lock is the honest cost
/// of that: uncontended it's a few tens of nanoseconds against a buffer that
/// represents ~23 ms of audio.
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request = value
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
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
