import AVFoundation
import Foundation
import Observation
import UIKit

/// Records voice notes to a temporary AAC file and publishes a live level meter
/// for the waveform in the capture UI.
///
/// Built for the long case as well as the short one: a ten-second reminder to
/// yourself and a forty-minute conversation between two other people go through
/// the same path. That means surviving the screen locking, the app being
/// backgrounded, and a phone call arriving in the middle.
///
/// **A recording is a series of pieces.** Every pause closes the current file
/// properly and every resume starts a new one; `stop()` hands back all of them,
/// in order, and they are joined when the note is saved. Resuming used to mean
/// asking the same recorder to carry on after iOS had taken the microphone
/// away, and when that failed — "Session activation failed" — the recording
/// was stuck. A fresh piece needs nothing from the old one, and a piece that is
/// closed can't be damaged by whatever happens next.
///
/// **And it comes back by itself.** After a call or another app takes the
/// microphone, it keeps trying to get it back (`reclaim`) — when the
/// interruption ends, when you return to the app, and every few seconds in
/// between — so a forty-minute meeting doesn't depend on you noticing a pause.
@MainActor
@Observable
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case sessionUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is off. Turn it on in Settings › Brain Buddy."
            case .sessionUnavailable(let reason):
                return "Couldn't start recording: \(reason)"
            }
        }
    }

    private(set) var isRecording = false
    private(set) var duration: TimeInterval = 0
    /// Rolling window of normalized levels (0...1) for the waveform view.
    private(set) var levels: [Double] = []

    /// Set when recording is suspended but the file is still open, with a
    /// sentence explaining why — a paused recorder that looks identical to a
    /// running one is how people lose an hour of audio.
    private(set) var pauseReason: String?
    var isPaused: Bool { pauseReason != nil }

    /// Whether recording continues once the app is no longer on screen — the
    /// screen locking, or you switching to another app.
    ///
    /// Mirrored from Settings. When this is off, leaving the app *pauses* rather
    /// than stops: no audio is captured while you're away, which is the honest
    /// meaning of "off", but what you already recorded is never thrown away.
    var allowsBackgroundRecording = true

    /// Seconds of wall-clock time that passed off screen without being recorded.
    ///
    /// Measured rather than assumed. If iOS suspends the process the recorder
    /// simply stops advancing, with no error and no notification — the only
    /// evidence is that time away exceeds audio captured. Reporting the gap turns
    /// "it didn't record in the background" into a number, and distinguishes
    /// being suspended from every other reason a recording can come up short.
    private(set) var secondsLostWhileAway: TimeInterval = 0

    /// The piece being recorded now; `nil` while paused.
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var fileURL: URL?
    /// Finished pieces, in order, and how much audio they hold.
    private var pieces: [URL] = []
    private var piecesDuration: TimeInterval = 0
    /// Whether the pause is one to come back from by itself: the microphone was
    /// taken, as opposed to you leaving the app with background recording off.
    private var resumesByItself = false
    private var reclaimTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var leftScreenAt: Date?
    private var recordedTimeOnLeaving: TimeInterval = 0

    private let maximumLevelSamples = 48

    // MARK: - Capability

    /// Whether this build actually declares the `audio` background mode.
    ///
    /// Read back out of the running bundle rather than trusted from the project
    /// file. This one plist key is the difference between recording through a
    /// locked screen and being suspended within seconds of leaving the app, it
    /// produces no build error when it's wrong, and the failure looks identical
    /// to a dozen unrelated causes: recording appears to stop and then "resume"
    /// when you reopen the app, because the process was frozen the whole time.
    ///
    /// Surfaced in Settings and on the recording screen so that a build without
    /// it says so, instead of quietly losing a conversation.
    static var declaresBackgroundAudio: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            // A non-array value means the key was injected as a scalar, which iOS
            // ignores — so "not declared" is the honest reading.
            return false
        }
        return modes.contains("audio")
    }

    // MARK: - Session configuration

    /// Recording route options.
    ///
    /// `allowBluetooth` was renamed to `allowBluetoothHFP`; the old spelling is
    /// deprecated. Below iOS 26 we simply don't opt into Bluetooth capture, so
    /// a paired headset records through the built-in mic instead of HFP. That
    /// matches what the dictation path in `SpeechTranscriber` already does, and
    /// it costs headset quality on older systems rather than costing a
    /// recording — which is the trade worth making here.
    ///
    /// `mixWithOthers` is what keeps a long recording going when another app
    /// plays a sound — a video, a voice message, a notification. Without it
    /// every one of those interrupts the recording, and a session that isn't
    /// mixable may not take the microphone back while the app is in the
    /// background. A phone call still interrupts; nothing can prevent that.
    private static var categoryOptions: AVAudioSession.CategoryOptions {
        if #available(iOS 26.0, *) {
            return [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP]
        }
        return [.defaultToSpeaker, .mixWithOthers]
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions)
        try session.setActive(true, options: [])
    }

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Recording

    func start() async throws {
        guard !isRecording else { return }
        guard await Self.requestPermission() else { throw RecorderError.permissionDenied }

        do {
            try activateSession()
        } catch {
            throw RecorderError.sessionUnavailable(error.localizedDescription)
        }

        pieces = []
        piecesDuration = 0
        do {
            try startPiece()
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.sessionUnavailable(error.localizedDescription)
        }

        isRecording = true
        pauseReason = nil
        resumesByItself = false
        duration = 0
        levels = []
        secondsLostWhileAway = 0
        leftScreenAt = nil
        startObserving()
        startMetering()
    }

    /// Opens a new piece and starts recording into it.
    private func startPiece() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: AudioJoiner.fileSettings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.sessionUnavailable("the recorder refused to start")
        }
        self.recorder = recorder
        self.fileURL = url
    }

    /// Closes the piece being recorded, keeping it if it holds any audio.
    private func finishPiece() {
        guard let recorder, let fileURL else { return }
        let reported = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil

        // Measured from the closed file: after an interruption the recorder's
        // own clock can read zero.
        let measured = (try? AVAudioFile(forReading: fileURL)).map {
            Double($0.length) / $0.fileFormat.sampleRate
        } ?? 0
        let length = max(reported, measured)
        if length > 0.05 {
            pieces.append(fileURL)
            piecesDuration += length
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Everything recorded so far, across pieces.
    private var recordedDuration: TimeInterval {
        piecesDuration + (recorder?.currentTime ?? 0)
    }

    /// Stops recording and returns the pieces, in order, plus their total
    /// length. Usually one piece; more if the recording was interrupted.
    @discardableResult
    func stop() -> (urls: [URL], duration: TimeInterval)? {
        guard isRecording else { return nil }
        finishPiece()
        stopReclaiming()
        stopMetering()
        stopObserving()

        let result: (urls: [URL], duration: TimeInterval) = (pieces, piecesDuration)
        pieces = []
        piecesDuration = 0
        isRecording = false
        pauseReason = nil
        resumesByItself = false
        duration = result.duration

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard !result.urls.isEmpty else { return nil }
        return result
    }

    /// Aborts and deletes the partial recording.
    func cancel() {
        guard isRecording else { return }
        finishPiece()
        stopReclaiming()
        stopMetering()
        stopObserving()
        for url in pieces { try? FileManager.default.removeItem(at: url) }

        pieces = []
        piecesDuration = 0
        isRecording = false
        pauseReason = nil
        resumesByItself = false
        duration = 0
        levels = []
        secondsLostWhileAway = 0
        leftScreenAt = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Pause / resume

    /// Suspends capture, closing the current piece. `reason` is shown to the user.
    func pause(reason: String, resumesByItself: Bool = false) {
        guard isRecording, !isPaused else { return }
        finishPiece()
        duration = piecesDuration
        pauseReason = reason
        self.resumesByItself = resumesByItself
        if resumesByItself { startReclaiming() }
    }

    /// Carries on recording in a new piece. Returns `false` when the
    /// microphone is still busy — and then, if the pause came from losing the
    /// microphone, it keeps trying by itself.
    @discardableResult
    func resume() -> Bool {
        guard isRecording, isPaused else { return false }
        do {
            try activateSession()
            try startPiece()
        } catch {
            pauseReason = Self.busyMessage
            if !resumesByItself {
                // You asked for it, so a failure now is worth retrying for you.
                resumesByItself = true
                startReclaiming()
            }
            return false
        }
        pauseReason = nil
        resumesByItself = false
        stopReclaiming()
        return true
    }

    static let interruptedMessage =
        "Paused — a call or another app took the microphone. Recording carries on by itself as soon as it's free."
    static let busyMessage =
        "Waiting for the microphone — a call or another app is still using it. Recording carries on by itself as soon as it's free, or tap Resume."

    /// Tries to get the microphone back every two seconds for the first half
    /// minute, then every five — for as long as you leave the recording
    /// running. A call can last an hour; the meeting after it still counts.
    private func startReclaiming() {
        guard reclaimTask == nil else { return }
        reclaimTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (attempt < 15 ? 2 : 5) * 1_000_000_000)
                attempt += 1
                guard let self, self.isRecording, self.isPaused, self.resumesByItself else { return }
                // Background recording turned off means no recording off
                // screen, even to resume.
                if !self.allowsBackgroundRecording, UIApplication.shared.applicationState != .active { continue }
                if self.resume() { return }
            }
        }
    }

    private func stopReclaiming() {
        reclaimTask?.cancel()
        reclaimTask = nil
    }

    // MARK: - Interruptions and lifecycle

    /// Two things take a long recording away: another app claiming the microphone
    /// (a phone call), and this app leaving the screen when the user has asked us
    /// not to record in the background. Both are handled by pausing — never by
    /// discarding what was already captured.
    private func startObserving() {
        stopObserving()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Unpack the payload here, on the main queue, so the isolated
            // handler below is handed nothing but plain values.
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false

            // `queue: .main` is why asserting main-actor isolation here is true
            // rather than hopeful.
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.allowsBackgroundRecording {
                    self.pause(reason: "Paused when you left the app — background recording is off in Settings.")
                } else if !Self.declaresBackgroundAudio {
                    // Without the capability iOS suspends the process in a moment
                    // and the recording stops mid-word with no notice. Pausing on
                    // purpose keeps what we have and gives the user a reason.
                    self.pause(reason: "Paused: this build can't record off screen — the Background Modes › Audio capability is missing.")
                } else {
                    self.noteLeavingScreen()
                }
            }
        })

        // Coming back is when the damage can be measured.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteReturningToScreen()
                // Back on screen is the most likely moment the microphone is free.
                if self.isPaused, self.resumesByItself { self.resume() }
            }
        })

        // A headset being unplugged mid-recording stops the engine on some routes;
        // reclaiming the session keeps the rest of the conversation.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard let self, self.isRecording, self.isPaused, self.resumesByItself else { return }
                self.resume()
            }
        })

        // The audio system restarting invalidates every recorder in the app.
        // What was recorded is in the pieces already closed; start a new one.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                if !self.isPaused {
                    self.pause(reason: Self.interruptedMessage, resumesByItself: true)
                }
                self.resume()
            }
        })
    }

    private func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            pause(reason: Self.interruptedMessage, resumesByItself: true)
        case .ended:
            guard isPaused, resumesByItself else { return }
            // `shouldResume` is a hint, and not every interruption sets it —
            // locking the screen and some route changes end without it. This
            // recording was in progress before something took the microphone, so
            // try to reclaim it either way; if it is still busy, the retries
            // carry on.
            _ = shouldResume
            if !allowsBackgroundRecording, UIApplication.shared.applicationState != .active { return }
            resume()
        default:
            break
        }
    }

    // MARK: - Measuring time off screen

    private func noteLeavingScreen() {
        guard isRecording, !isPaused else { return }
        leftScreenAt = Date()
        recordedTimeOnLeaving = recordedDuration
    }

    /// Compares wall-clock time away against audio actually captured.
    ///
    /// A suspended process leaves no trace except this discrepancy: the recorder
    /// is still "recording" and its file is intact, it just stopped advancing
    /// while the app was frozen.
    private func noteReturningToScreen() {
        guard let away = leftScreenAt else { return }
        leftScreenAt = nil
        guard isRecording, !isPaused else { return }

        let elapsed = Date().timeIntervalSince(away)
        let captured = recordedDuration - recordedTimeOnLeaving
        let missed = elapsed - captured
        // A second of slack absorbs the ordinary lag around backgrounding; more
        // than that means audio genuinely went missing.
        if missed > 1.5 { secondsLostWhileAway += missed }
    }

    // MARK: - Metering

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self else { return }
                // Paused between pieces there is no recorder, and nothing to meter.
                guard !self.isPaused, let recorder = self.recorder else { continue }
                recorder.updateMeters()
                self.duration = self.recordedDuration
                self.append(level: Self.normalize(decibels: recorder.averagePower(forChannel: 0)))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func append(level: Double) {
        levels.append(level)
        if levels.count > maximumLevelSamples {
            levels.removeFirst(levels.count - maximumLevelSamples)
        }
    }

    /// Maps AVFoundation's dBFS range onto 0...1 with a floor at -50 dB, which
    /// reads better than a linear conversion of the full -160 dB range.
    static func normalize(decibels: Float) -> Double {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        guard decibels > floor else { return 0 }
        return Double((decibels - floor) / -floor)
    }
}
