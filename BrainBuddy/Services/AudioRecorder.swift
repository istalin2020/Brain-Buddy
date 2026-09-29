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

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var fileURL: URL?
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
    private static var categoryOptions: AVAudioSession.CategoryOptions {
        if #available(iOS 26.0, *) {
            return [.defaultToSpeaker, .allowBluetoothHFP]
        }
        return [.defaultToSpeaker]
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

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw RecorderError.sessionUnavailable(error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")

        // Mono AAC at 44.1 kHz: speech-quality, small enough that a long note
        // still syncs to iCloud quickly. An hour lands around 28 MB.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw RecorderError.sessionUnavailable("the recorder refused to start")
            }
            self.recorder = recorder
            self.fileURL = url
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.sessionUnavailable(error.localizedDescription)
        }

        isRecording = true
        pauseReason = nil
        duration = 0
        levels = []
        secondsLostWhileAway = 0
        leftScreenAt = nil
        startObserving()
        startMetering()
    }

    /// Stops recording and returns the finished file plus its length.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let fileURL else { return nil }
        // A paused recorder reports `currentTime` as 0, so trust the length we
        // banked at pause time instead.
        let length = isPaused ? duration : recorder.currentTime
        recorder.stop()
        stopMetering()
        stopObserving()

        self.recorder = nil
        self.fileURL = nil
        isRecording = false
        pauseReason = nil
        duration = length

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileURL, length)
    }

    /// Aborts and deletes the partial recording.
    func cancel() {
        guard let recorder, let fileURL else { return }
        recorder.stop()
        stopMetering()
        stopObserving()
        try? FileManager.default.removeItem(at: fileURL)

        self.recorder = nil
        self.fileURL = nil
        isRecording = false
        pauseReason = nil
        duration = 0
        levels = []
        secondsLostWhileAway = 0
        leftScreenAt = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Pause / resume

    /// Suspends capture without closing the file. `reason` is shown to the user.
    func pause(reason: String) {
        guard let recorder, isRecording, !isPaused else { return }
        duration = recorder.currentTime
        recorder.pause()
        pauseReason = reason
    }

    /// Resumes a paused recording, reactivating the session if an interruption
    /// took it away. Returns `false` when the microphone couldn't be reclaimed.
    @discardableResult
    func resume() -> Bool {
        guard let recorder, isRecording, isPaused else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            pauseReason = "Couldn't get the microphone back: \(error.localizedDescription)"
            return false
        }
        guard recorder.record() else {
            pauseReason = "Couldn't restart the recording. Stop to keep what you have."
            return false
        }
        pauseReason = nil
        return true
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
            MainActor.assumeIsolated { self?.noteReturningToScreen() }
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
                guard let self, self.isRecording, self.isPaused else { return }
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
            pause(reason: "Paused — something else is using the microphone.")
        case .ended:
            guard isPaused, allowsBackgroundRecording else { return }
            // `shouldResume` is a hint, and not every interruption sets it —
            // locking the screen and some route changes end without it. This
            // recording was in progress before something took the microphone, so
            // try to reclaim it either way and let `resume()` report a failure.
            _ = shouldResume
            resume()
        default:
            break
        }
    }

    // MARK: - Measuring time off screen

    private func noteLeavingScreen() {
        guard let recorder, isRecording, !isPaused else { return }
        leftScreenAt = Date()
        recordedTimeOnLeaving = recorder.currentTime
    }

    /// Compares wall-clock time away against audio actually captured.
    ///
    /// A suspended process leaves no trace except this discrepancy: the recorder
    /// is still "recording" and its file is intact, it just stopped advancing
    /// while the app was frozen.
    private func noteReturningToScreen() {
        guard let away = leftScreenAt else { return }
        leftScreenAt = nil
        guard let recorder, isRecording, !isPaused else { return }

        let elapsed = Date().timeIntervalSince(away)
        let captured = recorder.currentTime - recordedTimeOnLeaving
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
                guard let self, let recorder = self.recorder else { return }
                guard !self.isPaused else { continue }
                recorder.updateMeters()
                self.duration = recorder.currentTime
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
