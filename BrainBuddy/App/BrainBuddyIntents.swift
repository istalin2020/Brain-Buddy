import AppIntents
import Foundation

/// A mailbox for requests that arrive from outside the app's own screens.
///
/// An App Intent runs in the app's process but not inside its view tree, so it
/// can't reach `AppServices` — and it may run while the app is asleep, minutes
/// before any view exists to hand a request to. So it leaves the request in
/// defaults and `RootView` collects it on the next foreground pass. Deliberately
/// one-shot: a question you asked yesterday should not re-run every time you
/// open the app.
enum IntentHandOff {
    private static let questionKey = "handoff.pendingQuestion"
    private static let destinationKey = "handoff.pendingDestination"

    static func request(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: questionKey)
    }

    static func takeQuestion() -> String? {
        guard let stored = UserDefaults.standard.string(forKey: questionKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: questionKey)
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func request(destination: AppDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: destinationKey)
    }

    static func takeDestination() -> AppDestination? {
        guard let raw = UserDefaults.standard.string(forKey: destinationKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: destinationKey)
        return AppDestination(rawValue: raw)
    }
}

// MARK: - Remember

/// "Hey Siri, remember this in Brain Buddy."
///
/// The whole point of a second brain is catching the thought at the moment you
/// have it — walking, driving, halfway out the door. That moment does not
/// survive unlocking a phone, finding an app, waiting for a store to open and
/// tapping into a text field. This intent takes the sentence and returns; the
/// app enriches and indexes it later, so nothing you say is ever waiting on a
/// spinner.
struct RememberIntent: AppIntent {
    static var title: LocalizedStringResource = "Remember Something"
    static var description = IntentDescription(
        "Saves a thought, task or reminder to your brain. Works without opening the app.",
        categoryName: "Capture"
    )

    /// Stays closed on purpose. Launching the app to save one sentence is the
    /// friction this exists to remove.
    static var openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What should I remember?")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$note)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try QuickCaptureQueue.enqueue(note)
        return .result(dialog: "Saved to your brain.")
    }
}

// MARK: - Ask

/// "Hey Siri, ask Brain Buddy what my TSH value was."
///
/// Unlike remembering, answering needs the whole retrieval stack — the index,
/// the embeddings, the line picker — so this one opens the app and runs the
/// question on the Ask tab. You still didn't have to type it.
struct AskBrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask My Brain"
    static var description = IntentDescription(
        "Searches everything you've saved and shows the answer.",
        categoryName: "Search"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to know?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask my brain \(\.$question)")
    }

    func perform() async throws -> some IntentResult {
        IntentHandOff.request(question: question)
        return .result()
    }
}

// MARK: - Today

/// "Hey Siri, what's on today in Brain Buddy."
struct TodayBriefIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Today's Brief"
    static var description = IntentDescription(
        "Opens today's brief: what's on, what's still open, and what you closed.",
        categoryName: "Review"
    )

    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        IntentHandOff.request(destination: .today)
        return .result()
    }
}

// MARK: - Shortcuts

/// The phrases Siri and the Shortcuts app offer without the user configuring
/// anything. Kept to three, each one a thing people actually say — a long list
/// of near-identical phrases makes Siri worse at picking, not better.
struct BrainBuddyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RememberIntent(),
            phrases: [
                "Remember this in \(.applicationName)",
                "Add to my \(.applicationName)",
                "Note this in \(.applicationName)"
            ],
            shortTitle: "Remember",
            systemImageName: "brain.head.profile"
        )

        AppShortcut(
            intent: AskBrainIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Search my \(.applicationName)"
            ],
            shortTitle: "Ask",
            systemImageName: "sparkle.magnifyingglass"
        )

        AppShortcut(
            intent: TodayBriefIntent(),
            phrases: [
                "What's on today in \(.applicationName)",
                "Show my \(.applicationName) brief"
            ],
            shortTitle: "Today",
            systemImageName: "sun.horizon"
        )
    }
}
