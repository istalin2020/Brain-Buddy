import SwiftData
import SwiftUI

/// Ask your brain a question — by typing or by talking — and get an answer read
/// back out of your own notes.
@MainActor
struct AskView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<MemoryItem> { !$0.isTrashed },
        sort: \MemoryItem.createdAt,
        order: .reverse
    )
    private var memories: [MemoryItem]

    @AppStorage(PreferenceKey.speakAnswers) private var speakAnswers = true

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var answer: AnswerComposer.Answer?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    private var transcriber: SpeechTranscriber { services.transcriber }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                content
            }
            .navigationTitle("Ask")
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            .onAppear {
                transcriber.onFinalTranscript = { text in
                    query = text
                    runSearch(speak: true)
                }
            }
            .onDisappear {
                transcriber.cancelListening()
                services.speaker.stop()
            }
            // Debounce typing so a long library isn't re-ranked on every keystroke.
            .task(id: query) {
                guard !transcriber.isListening else { return }
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    hits = []
                    answer = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                runSearch(speak: false)
            }
            .alert(
                "Listening problem",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Ask anything you've saved…", text: $query)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { runSearch(speak: speakAnswers) }
                    .disabled(transcriber.isListening)

                if !query.isEmpty {
                    Button {
                        query = ""
                        hits = []
                        answer = nil
                        services.speaker.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: toggleListening) {
                    Image(systemName: transcriber.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: transcriber.isListening)
                        .foregroundStyle(transcriber.isListening ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(transcriber.isListening ? "Stop listening" : "Ask by voice")
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if transcriber.isListening {
                Text(transcriber.liveTranscript.isEmpty ? "Listening…" : transcriber.liveTranscript)
                    .font(.callout)
                    .foregroundStyle(transcriber.liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: transcriber.isListening)
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if isSearching && hits.isEmpty {
            ProgressView("Searching your brain…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestions
        } else if hits.isEmpty {
            EmptyStateView(
                systemImage: "questionmark.bubble",
                title: "Nothing found",
                message: "Nothing in your brain matches “\(AnswerComposer.subject(of: query))” yet. Try different words, or capture it first."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let answer, answer.hasResults {
                    Section { answerCard(answer) }
                }
                Section("Matches") {
                    ForEach(hits) { hit in
                        NavigationLink(value: hit.item) {
                            MemoryRow(item: hit.item, snippet: hit.snippet, footnote: hit.matchExplanation)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func answerCard(_ answer: AnswerComposer.Answer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Answer", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button {
                    if services.speaker.isSpeaking {
                        services.speaker.stop()
                    } else {
                        services.speaker.speak(answer.spoken)
                    }
                } label: {
                    Image(systemName: services.speaker.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(services.speaker.isSpeaking ? "Stop speaking" : "Read answer aloud")
            }
            Text(answer.written)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Try asking")
                    .font(.headline)
                ForEach(Self.samplePrompts, id: \.self) { prompt in
                    Button {
                        query = prompt
                        runSearch(speak: speakAnswers)
                    } label: {
                        HStack {
                            Image(systemName: "quote.opening")
                                .foregroundStyle(.tertiary)
                            Text(prompt)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Text("Tap the microphone to ask out loud. Brain Buddy searches keywords *and* meaning, so you don't have to remember your exact wording.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding()
        }
    }

    private static let samplePrompts = [
        "What did I save about the dentist?",
        "Show me everything from last week",
        "That idea about the app onboarding",
        "The receipt I photographed"
    ]

    // MARK: - Actions

    private func toggleListening() {
        services.speaker.stop()
        if transcriber.isListening {
            transcriber.stopListening()
            return
        }
        isFieldFocused = false
        query = ""
        hits = []
        answer = nil
        Task {
            do {
                try await transcriber.startListening()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runSearch(speak: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        let results = services.search.search(query: trimmed, in: memories, limit: 30)
        hits = results

        let composed = AnswerComposer.compose(
            query: trimmed,
            sources: results.prefix(5).map { hit in
                AnswerSource(
                    title: hit.item.displayTitle,
                    snippet: hit.snippet,
                    createdAt: hit.item.createdAt,
                    kindTitle: hit.item.kind.title,
                    score: hit.score
                )
            }
        )
        answer = composed
        isSearching = false

        if speak && speakAnswers {
            services.speaker.speak(composed.spoken)
        }
    }
}
