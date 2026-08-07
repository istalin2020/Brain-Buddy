import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Preference keys, kept in one place so `@AppStorage` call sites can't drift.
enum PreferenceKey {
    static let speakAnswers = "settings.speakAnswers"
    static let semanticSearch = "settings.semanticSearch"
    static let autoStopDictation = "settings.autoStopDictation"
    static let backgroundRecording = "settings.backgroundRecording"
    static let morningBrief = "settings.morningBrief"
    static let morningBriefHour = "settings.morningBriefHour"
    static let morningBriefMinute = "settings.morningBriefMinute"
    /// Locale identifier for speech recognition; empty means the device language.
    static let transcriptionLocale = "settings.transcriptionLocale"
    /// Whether transcription may use Apple's servers instead of the on-device
    /// model, which is markedly more accurate on long, multi-speaker audio.
    static let serverTranscription = "settings.serverTranscription"
}

/// Where a tapped notification wants to land.
enum AppDestination: String {
    case today
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
    let brief = BriefService()
    let notifications = NotificationScheduler()

    /// Set when a notification asks for a particular screen; `RootView` consumes
    /// it and clears it.
    var pendingDestination: AppDestination?

    /// `UNUserNotificationCenter.delegate` is weak, so something has to hold it.
    private var notificationRouter: NotificationRouter?

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
            PreferenceKey.backgroundRecording: true,
            PreferenceKey.morningBrief: true,
            PreferenceKey.morningBriefHour: 8,
            PreferenceKey.morningBriefMinute: 0,
            PreferenceKey.transcriptionLocale: "",
            // Off by default: everything else in this app stays on the device,
            // and sending recordings to a server should be a decision, not a
            // surprise. It is offered because for a long bilingual conversation
            // the accuracy difference is not subtle.
            PreferenceKey.serverTranscription: false
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

    var morningBriefTime: DateComponents {
        let defaults = UserDefaults.standard
        return DateComponents(
            hour: defaults.integer(forKey: PreferenceKey.morningBriefHour),
            minute: defaults.integer(forKey: PreferenceKey.morningBriefMinute)
        )
    }

    /// Re-applies the notification preference at launch, without prompting.
    func synchronizeMorningBrief() async {
        let defaults = UserDefaults.standard
        let time = morningBriefTime
        await notifications.synchronize(
            enabled: defaults.bool(forKey: PreferenceKey.morningBrief),
            hour: time.hour ?? 8,
            minute: time.minute ?? 0
        )
    }

    /// Applies the preference *with* a prompt if one is needed. For the Settings
    /// toggle, where flipping the switch is the request.
    func applyMorningBriefPreference() async {
        let time = morningBriefTime
        if UserDefaults.standard.bool(forKey: PreferenceKey.morningBrief) {
            await notifications.scheduleMorningBrief(hour: time.hour ?? 8, minute: time.minute ?? 0)
        } else {
            notifications.cancelMorningBrief()
        }
    }

    /// Asks for notification permission the first time the brief is on screen.
    ///
    /// Deliberately not at first launch: a permission prompt before the user has
    /// seen what it's for is how you get a "Don't Allow" you can never take back.
    /// Here, the thing the reminder is about is already visible behind the sheet.
    func offerMorningBriefIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.morningBrief) else { return }
        await notifications.refresh()
        guard notifications.authorization == .notDetermined, !notifications.hasRequestedPermission else { return }
        await applyMorningBriefPreference()
    }

    /// Warms the embedding model so the first search isn't the slow one.
    func prepare() {
        Task.detached(priority: .utility) {
            _ = EmbeddingService.shared.vector(for: "warm up the embedding model")
        }
        installNotificationRouter()
        Task { await syncMonitor.refresh() }
        Task { await synchronizeMorningBrief() }
    }

    private func installNotificationRouter() {
        guard notificationRouter == nil else { return }
        let router = NotificationRouter { [weak self] destination in
            self?.pendingDestination = AppDestination(rawValue: destination)
        }
        notificationRouter = router
        UNUserNotificationCenter.current().delegate = router
    }
}
