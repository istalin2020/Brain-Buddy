import SwiftData
import SwiftUI

/// Ask your brain a question — by typing or by talking — and read the answer out
/// of your own notes. Reading it *aloud* is a button, never automatic.
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

    /// Off by default. See `AppServices.init` for why silence is the default.
    @AppStorage(PreferenceKey.speakAnswers) private var speakAnswers = false

    @State private var query = ""
    /// The question that produced what's on screen. Held separately from `query`
    /// because the input box is emptied as soon as an answer arrives — you should
    /// be able to ask the next thing without clearing the last one by hand.
    @State private var askedQuestion = ""
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
            // A question can arrive from Siri before this view exists, so it is
            // collected on appearance as well as on change.
            .task { consumePendingQuestion() }
            .onChange(of: services.pendingQuestion) { _, _ in consumePendingQuestion() }
            .onDisappear {
                transcriber.cancelListening()
                services.speaker.stop()
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
                    .font(.title3)
                    .foregroundStyle(.secondary)

                // Questions are long — "what is my TSH value from the latest
                // report" — so the field gets body-sized text and room to sit in.
                TextField("Ask anything you've saved…", text: $query)
                    .font(.body)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { ask(query) }
                    .disabled(transcriber.isListening)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear what you typed")
                }

                Button(action: toggleListening) {
                    Image(systemName: transcriber.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .symbolEffect(.pulse, isActive: transcriber.isListening)
                        .foregroundStyle(transcriber.isListening ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(transcriber.isListening ? "Stop listening" : "Ask by voice")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if transcriber.isListening {
                Text(transcriber.liveTranscript.isEmpty ? "Listening…" : transcriber.liveTranscript)
                    .font(.callout)
                    .foregroundStyle(transcriber.liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if !askedQuestion.isEmpty {
                askedQuestionRow
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: transcriber.isListening)
    }

    /// What you asked, kept on screen because the box that held it is now empty.
    private var askedQuestionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(askedQuestion)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                clearResults()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear this answer")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if isSearching && hits.isEmpty {
            ProgressView("Searching your brain…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if askedQuestion.isEmpty {
            suggestions
        } else if hits.isEmpty {
            EmptyStateView(
                systemImage: "questionmark.bubble",
                title: "Nothing found",
                message: "Nothing in your brain matches “\(AnswerComposer.subject(of: askedQuestion))” yet. Try different words, or capture it first."
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
            Label("Answer", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(answer.written)
                .font(.body)
                .textSelection(.enabled)

            // Reading aloud is an action you take on an answer you can already
            // see — not something that happens the moment results arrive.
            Button {
                if services.speaker.isSpeaking {
                    services.speaker.stop()
                } else {
                    services.speaker.speak(answer.spoken)
                }
            } label: {
                Label(
                    services.speaker.isSpeaking ? "Stop" : "Read aloud",
                    systemImage: services.speaker.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .font(.footnote.weight(.medium))
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
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
                        ask(prompt)
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

                Text("Type a question and press search, or tap the microphone to ask out loud. Brain Buddy searches keywords *and* meaning, so you don't have to remember your exact wording. Answers stay silent until you tap Read aloud.")
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
        clearResults()

        // Assigned here rather than when the view appears: the capture editor
        // dictates through the same recognizer, and whichever screen starts a
        // session owns its result.
        transcriber.onFinalTranscript = { text in ask(text) }
        transcriber.onSessionEnd = nil

        Task {
            do {
                try await transcriber.startListening()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs a question handed over by Siri or the Shortcuts app, once.
    private func consumePendingQuestion() {
        guard let question = services.pendingQuestion else { return }
        services.pendingQuestion = nil
        ask(question)
    }

    private func clearResults() {
        askedQuestion = ""
        hits = []
        answer = nil
        services.speaker.stop()
    }

    /// Runs one question and empties the input box.
    ///
    /// Searching is explicit — on submit, on a voice result, or from a
    /// suggestion — rather than debounced on every keystroke. Those two
    /// behaviors are mutually exclusive: a box that empties itself when results
    /// arrive can't also be searched as you type it.
    private func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.speaker.stop()
        isFieldFocused = false
        askedQuestion = trimmed
        query = ""
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

        // Only when the user has explicitly turned automatic reading on.
        if speakAnswers, composed.hasResults {
            services.speaker.speak(composed.spoken)
        }
    }
}
