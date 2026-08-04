import Foundation
import Observation
import SwiftUI

/// Preference keys, kept in one place so `@AppStorage` call sites can't drift.
enum PreferenceKey {
    static let speakAnswers = "settings.speakAnswers"
    static let semanticSearch = "settings.semanticSearch"
    static let autoStopDictation = "settings.autoStopDictation"
    static let backgroundRecording = "settings.backgroundRecording"
}

/// The long-lived objects the whole app shares. Injected once at the root so
/// views never construct a recorder or a synthesizer of their own.
@MainActor
@Observable
final class AppServices {
    let ingest = IngestService()
    let recorder = AudioRecorder()
    let transcriber = SpeechTranscriber()
    let speaker = SpeechSpeaker()
    let syncMonitor = CloudSyncMonitor()
    let search = SearchEngine()

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            // Answers are silent unless you ask for sound. A second brain that
            // starts talking the moment you look something up is unusable in a
            // meeting, on a train, or next to someone who is asleep — so
            // speaking is a button you press, not something that happens to you.
            PreferenceKey.speakAnswers: false,
            PreferenceKey.semanticSearch: true,
            PreferenceKey.autoStopDictation: true,
            PreferenceKey.backgroundRecording: true
        ])
        applyPreferences()
    }

    /// Mirrors user preferences into the services that need them.
    func applyPreferences() {
        let defaults = UserDefaults.standard
        search.isSemanticEnabled = defaults.bool(forKey: PreferenceKey.semanticSearch)
        transcriber.autoStopAfterSilence = defaults.bool(forKey: PreferenceKey.autoStopDictation) ? 2.5 : nil
        recorder.allowsBackgroundRecording = defaults.bool(forKey: PreferenceKey.backgroundRecording)
    }

    /// Warms the embedding model so the first search isn't the slow one.
    func prepare() {
        Task.detached(priority: .utility) {
            _ = EmbeddingService.shared.vector(for: "warm up the embedding model")
        }
        Task { await syncMonitor.refresh() }
    }
}
