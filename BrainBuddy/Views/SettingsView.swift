import SwiftData
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query private var allMemories: [MemoryItem]
    @Query private var allAttachments: [MemoryAttachment]

    @AppStorage(PreferenceKey.speakAnswers) private var speakAnswers = true
    @AppStorage(PreferenceKey.semanticSearch) private var semanticSearch = true
    @AppStorage(PreferenceKey.autoStopDictation) private var autoStopDictation = true

    @State private var reindexProgress: Double?
    @State private var pendingSharedItems = 0

    var body: some View {
        NavigationStack {
            List {
                syncSection
                searchSection
                sharingSection
                storageSection
                maintenanceSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task {
                pendingSharedItems = SharedInbox.pendingFiles().count
                await services.syncMonitor.refresh()
            }
            .onChange(of: semanticSearch) { _, _ in services.applyPreferences() }
            .onChange(of: autoStopDictation) { _, _ in services.applyPreferences() }
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

    private var searchSection: some View {
        Section {
            Toggle("Speak answers aloud", isOn: $speakAnswers)
            Toggle("Match by meaning", isOn: $semanticSearch)
            Toggle("Stop listening after a pause", isOn: $autoStopDictation)
        } header: {
            Text("Search & voice")
        } footer: {
            Text(semanticSearch
                 ? "Meaning matching uses Apple's on-device language models, so questions work even when you don't remember your exact words. Nothing is sent anywhere."
                 : "Only keyword matching is used. Faster on very large libraries, but you'll need to recall the wording you saved.")
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
                    Label("Rebuild all search indexes", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Useful after restoring from iCloud on a new device, or if search results look stale. Nothing is deleted.")
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
