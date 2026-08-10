import SwiftData
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query private var allMemories: [MemoryItem]
    @Query private var allAttachments: [MemoryAttachment]

    @AppStorage(PreferenceKey.speakAnswers) private var speakAnswers = false
    @AppStorage(PreferenceKey.semanticSearch) private var semanticSearch = true
    @AppStorage(PreferenceKey.autoStopDictation) private var autoStopDictation = true
    @AppStorage(PreferenceKey.backgroundRecording) private var backgroundRecording = true
    @AppStorage(PreferenceKey.morningBrief) private var morningBrief = true
    @AppStorage(PreferenceKey.morningBriefHour) private var briefHour = 8
    @AppStorage(PreferenceKey.morningBriefMinute) private var briefMinute = 0
    @AppStorage(PreferenceKey.transcriptionLocale) private var transcriptionLocale = ""
    @AppStorage(PreferenceKey.serverTranscription) private var serverTranscription = false

    @State private var reindexProgress: Double?
    @State private var pendingSharedItems = 0

    var body: some View {
        NavigationStack {
            List {
                syncSection
                briefSection
                searchSection
                transcriptionSection
                recordingSection
                sharingSection
                storageSection
                maintenanceSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task {
                pendingSharedItems = SharedInbox.pendingFiles().count
                await services.syncMonitor.refresh()
                await services.notifications.refresh()
            }
            .onChange(of: morningBrief) { _, _ in rescheduleBrief() }
            .onChange(of: briefHour) { _, _ in rescheduleBrief() }
            .onChange(of: briefMinute) { _, _ in rescheduleBrief() }
            .onChange(of: semanticSearch) { _, _ in services.applyPreferences() }
            .onChange(of: autoStopDictation) { _, _ in services.applyPreferences() }
            .onChange(of: backgroundRecording) { _, _ in services.applyPreferences() }
        }
    }

    // MARK: - Sections

    private var syncSection: some View {
        Section {
            let status = services.syncMonitor.status
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.systemImage)
                    .font(.title2)
                    .foregroundStyle(status.isHealthy ? Color.accentColor : Color.orange)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title).font(.subheadline.weight(.semibold))
                    Text(status.detail).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let last = services.syncMonitor.lastChangeReceived {
                LabeledContent("Last change received", value: last.formatted(date: .omitted, time: .shortened))
            }

            LabeledContent("Storage mode", value: PersistenceController.shared.mode.rawValue.capitalized)

            if let warning = PersistenceController.shared.setupWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Check iCloud again") {
                Task { await services.syncMonitor.refresh() }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(PersistenceController.shared.mode.description)
        }
    }

    private var briefSection: some View {
        Section {
            Toggle("Daily reminder", isOn: $morningBrief)

            if morningBrief {
                DatePicker("Time", selection: briefTimeBinding, displayedComponents: .hourAndMinute)

                if let next = services.notifications.nextTrigger {
                    LabeledContent(
                        "Next reminder",
                        value: next.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }

            if services.notifications.isDenied {
                Text("Notifications are off for Brain Buddy in iOS Settings, so the reminder can't be delivered. Your brief still builds when you open the app.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Morning brief")
        } footer: {
            Text("A notification at this time every day, and the Today tab shows what's on, what you said you'd do, and the key points from recent discussions.\n\niOS gives no app a guaranteed slot to run at a fixed time, so the notification is the alarm and the brief is built the moment you open the app — stamped with when that was. Nothing is computed on a server; it all comes from what's already on this device.")
        }
    }

    /// The stored hour and minute, surfaced as the `Date` a `DatePicker` wants.
    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: briefHour,
                    minute: briefMinute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                briefHour = parts.hour ?? 8
                briefMinute = parts.minute ?? 0
            }
        )
    }

    /// Flipping the switch *is* the permission request, so this path prompts —
    /// unlike the silent reapply at launch.
    private func rescheduleBrief() {
        Task { await services.applyMorningBriefPreference() }
    }

    private var searchSection: some View {
        Section {
            Toggle("Read answers aloud automatically", isOn: $speakAnswers)
            Toggle("Match by meaning", isOn: $semanticSearch)
            Toggle("Stop listening after a pause", isOn: $autoStopDictation)
        } header: {
            Text("Search & voice")
        } footer: {
            Text(speakAnswers
                 ? "Answers are spoken as soon as they appear. Every answer also has a Read aloud button, so you can leave this off and choose per answer."
                 : "Answers stay silent. Tap Read aloud on an answer when you want to hear it.\n\n"
                   + (semanticSearch
                      ? "Meaning matching uses Apple's on-device language models, so questions work even when you don't remember your exact words. Nothing is sent anywhere."
                      : "Only keyword matching is used. Faster on very large libraries, but you'll need to recall the wording you saved."))
        }
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Spoken language", selection: $transcriptionLocale) {
                Text("Device language").tag("")
                ForEach(Self.recognitionLocales, id: \.identifier) { locale in
                    Text(Self.name(of: locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.navigationLink)

            Toggle("Higher accuracy transcription", isOn: $serverTranscription)
        } header: {
            Text("Transcription")
        } footer: {
            Text("""
            Pick the language you actually speak in recordings. A recognizer set to \
            the wrong one doesn't fail — it spells what it hears as words from the \
            language it expects, which reads like a transcript and means nothing. If \
            you mix English into another language, the regional variant usually wins.

            \(serverTranscription
              ? "Higher accuracy sends the audio to Apple's speech servers. It is much better on long, multi-speaker recordings — and it is the one thing in this app that leaves your device."
              : "Transcription runs entirely on this iPhone. That keeps recordings private, but the on-device model is built for short dictation and struggles with long conversations. Turn on higher accuracy to use Apple's servers instead.")
            """)
        }
    }

    /// Built once: the list runs to dozens of entries and never changes at runtime.
    private static let recognitionLocales = SpeechTranscriber.supportedLocales()

    private static func name(of locale: Locale) -> String {
        let described = Locale.current.localizedString(forIdentifier: locale.identifier)
        return described ?? locale.identifier
    }

    private var recordingSection: some View {
        Section {
            Toggle("Keep recording in the background", isOn: $backgroundRecording)

            // The one thing that can silently defeat the toggle above, reported
            // from the running bundle rather than assumed.
            LabeledContent(
                "Off-screen recording",
                value: AudioRecorder.declaresBackgroundAudio ? "Allowed" : "Blocked by this build"
            )

            if !AudioRecorder.declaresBackgroundAudio {
                Text("The app is missing the Background Modes › Audio capability, so iOS suspends it seconds after it leaves the screen. Add it on the BrainBuddy target under Signing & Capabilities, or check that Configuration/BrainBuddy-Info.plist is the target's Info.plist file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Voice recording")
        } footer: {
            Text(backgroundRecording
                 ? "Recording continues when the screen locks or you switch apps, so you can capture a long discussion without keeping Brain Buddy open. A phone call pauses it and it resumes afterwards."
                 : "Recording pauses when you leave the app and waits for you to come back. Nothing already recorded is lost — but nothing is captured while you're away.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Memories", value: "\(allMemories.filter { !$0.isTrashed }.count)")
            LabeledContent("In trash", value: "\(allMemories.filter(\.isTrashed).count)")
            LabeledContent("Attachments", value: "\(allAttachments.count)")
            LabeledContent("Attachment size", value: formattedAttachmentSize)
            LabeledContent("Indexed for meaning", value: "\(allMemories.filter { $0.embeddingData != nil }.count)")
        } header: {
            Text("Your brain")
        }
    }

    private var sharingSection: some View {
        Section {
            LabeledContent(
                "Share sheet",
                value: SharedInbox.isAvailable ? "Ready" : "App Group not configured"
            )
            if pendingSharedItems > 0 {
                LabeledContent("Waiting to import", value: "\(pendingSharedItems)")
                Button("Import now") {
                    Task { await services.ingest.drainSharedInbox(into: modelContext) }
                }
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text(SharedInbox.isAvailable
                 ? "Share a link, photo, PDF or selection from any app and pick Brain Buddy. Items are imported — and text-recognized — the next time you open the app."
                 : "The share extension needs the App Group group.com.brainbuddy.app enabled on both targets. Until then, sharing from other apps won't reach your brain.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            if let progress = reindexProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text("Rebuilding search index… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    reindexAll()
                } label: {
                    Label("Rebuild subjects and search indexes", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Re-derives the subject of everything you haven't titled yourself and rebuilds the search index. Useful after restoring from iCloud on a new device, or if subjects and results look stale. Nothing is deleted, and titles you typed are left alone.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.shortVersionString)
            Text("Brain Buddy keeps everything on your device and in your private iCloud database. Transcription, text recognition and meaning-matching all run locally on this iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var formattedAttachmentSize: String {
        let total = allAttachments.reduce(0) { $0 + $1.byteCount }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private func reindexAll() {
        let items = allMemories
        guard !items.isEmpty else { return }
        reindexProgress = 0
        Task {
            for (index, item) in items.enumerated() {
                // Subjects are derived once at capture, so improving the
                // derivation does nothing for what's already saved.
                services.ingest.refreshSubject(of: item)
                await services.ingest.finalize(item, in: modelContext)
                reindexProgress = Double(index + 1) / Double(items.count)
            }
            services.search.invalidateCache()
            reindexProgress = nil
        }
    }
}

extension Bundle {
    var shortVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
