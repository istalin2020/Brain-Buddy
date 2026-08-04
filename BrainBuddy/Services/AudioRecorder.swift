import AVFoundation
import Foundation
import Observation

/// Records voice notes to a temporary AAC file and publishes a live level meter
/// for the waveform in the capture UI.
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

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var fileURL: URL?

    private let maximumLevelSamples = 48

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
        // still syncs to iCloud quickly.
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
        duration = 0
        levels = []
        startMetering()
    }

    /// Stops recording and returns the finished file plus its length.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let fileURL else { return nil }
        let length = recorder.currentTime
        recorder.stop()
        stopMetering()

        self.recorder = nil
        self.fileURL = nil
        isRecording = false
        duration = length

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileURL, length)
    }

    /// Aborts and deletes the partial recording.
    func cancel() {
        guard let recorder, let fileURL else { return }
        recorder.stop()
        stopMetering()
        try? FileManager.default.removeItem(at: fileURL)

        self.recorder = nil
        self.fileURL = nil
        isRecording = false
        duration = 0
        levels = []

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Metering

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self, let recorder = self.recorder else { return }
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
