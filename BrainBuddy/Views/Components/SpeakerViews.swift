import SwiftData
import SwiftUI

/// A transcript, with each speaker's name in bold at the start of their turn
/// when it says who spoke, and as plain text when it doesn't.
struct TranscriptText: View {
    let text: String

    var body: some View {
        if let turns = SpeakerTranscript.turns(in: text), Set(turns.map(\.speaker)).count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    (Text(turn.speaker + ": ").bold() + Text(turn.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lets you put names to "Person 1", "Person 2"…
///
/// Renaming changes the transcript and the summary together. Giving two people
/// the same name makes them one — the way to correct the app when it heard one
/// voice as two.
@MainActor
struct SpeakerNamesEditor: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    let item: MemoryItem
    @State private var names: [String: String] = [:]

    private var speakers: [String] { SpeakerTranscript.speakers(in: item.text) }

    var body: some View {
        if speakers.count >= 2 || speakers.contains(where: { $0.hasPrefix("Person ") }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Who's speaking")
                    .font(.headline)
                ForEach(speakers, id: \.self) { speaker in
                    HStack(spacing: 10) {
                        Text(speaker)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .leading)
                        TextField("Name", text: binding(for: speaker))
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(apply)
                    }
                }
                Button("Save names", action: apply)
                    .buttonStyle(.bordered)
                    .disabled(!hasChanges)
                Text("Speakers are told apart by their voices, which works best when they sound different. If one person shows up as two, give both the same name and they become one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for speaker: String) -> Binding<String> {
        Binding(
            get: { names[speaker] ?? "" },
            set: { names[speaker] = $0 }
        )
    }

    private var hasChanges: Bool {
        names.contains { old, new in
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != old
        }
    }

    private func apply() {
        guard hasChanges else { return }
        for (old, new) in names {
            services.ingest.renameSpeaker(old, to: new, on: item)
        }
        names = [:]
        Task { await services.applyEdit(to: item, in: modelContext) }
    }
}
