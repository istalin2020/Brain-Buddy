import AVFoundation
import Foundation
import Observation

/// Reads answers back out loud, which is what makes "talking to your brain"
/// feel like a conversation instead of a search box with a microphone.
@MainActor
@Observable
final class SpeechSpeaker {
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var monitor: Task<Void, Never>?

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        // Playback mixes with whatever else is going on rather than stopping it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        synthesizer.speak(utterance)
        isSpeaking = true
        startMonitoring()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// `AVSpeechSynthesizer` reports completion through a delegate; polling its
    /// `isSpeaking` flag keeps this type a plain `@Observable` value instead of
    /// dragging in an `NSObject` delegate just to flip one boolean.
    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if !self.synthesizer.isSpeaking {
                    self.isSpeaking = false
                    return
                }
            }
        }
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return AVSpeechSynthesisVoice(language: identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
