import SwiftData
import SwiftUI

/// Ask your brain a question — by typing or by talking — and get talked
/// through the answer, out of your own notes.
///
/// It is a conversation, laid out the way every assistant people already use
/// is laid out: the box is at the bottom, tapping into it lifts the keyboard,
/// and each exchange reads **from the top down** — your question, then the
/// reply, then the sources it was built from. Tap a source and the note, photo
/// or PDF opens. The reply is generated in *voice* only; every fact in it is a
/// line quoted from something you saved, which is why the sources are always
/// there to check.
///
/// Reading it *aloud* is a button, never automatic.
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
    @State private var turns: [AskTurn] = []
    @State private var errorMessage: String?
    @State private var speakingTurn: UUID?

    /// The exchange to bring to the top of the screen, and a counter that makes
    /// the same target scrollable twice.
    ///
    /// A plain `onChange` of the identifier fires once and then never again for
    /// the same value, which is exactly wrong here: the question is scrolled to
    /// when it is asked, and to the *same* place again when its answer lands.
    @State private var scrollTarget: UUID?
    @State private var scrollToken = 0

    @FocusState private var isFieldFocused: Bool

    private var transcriber: SpeechTranscriber { services.transcriber }

    /// True between sending a question and its reply landing.
    private var isAwaitingReply: Bool { turns.contains { $0.answer == nil } }

    var body: some View {
        NavigationStack {
            conversation
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle("Ask")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: MemoryItem.self) { item in
                    MemoryDetailView(item: item)
                }
                .toolbar {
                    if !turns.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                startOver()
                            } label: {
                                Label("New conversation", systemImage: "square.and.pencil")
                            }
                        }
                    }
                }
                // A question can arrive from Siri before this view exists, so it
                // is collected on appearance as well as on change.
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

    // MARK: - The conversation

    /// One block per exchange, each block reading question → reply → sources.
    ///
    /// The block carries the identifier, so scrolling to an exchange puts its
    /// **question** at the top of the screen and everything else flows down
    /// from there. Scrolling to the bottom instead — which is what a chat app
    /// does while a reply streams in word by word — lands you at the *end* of
    /// a reply that arrived all at once, looking at the source rows with the
    /// question somewhere above the fold.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty {
                        welcome
                    }
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 14) {
                            questionBubble(turn.question)
                            if let answer = turn.answer {
                                replyBubble(turn, answer: answer)
                            } else {
                                thinkingBubble
                            }
                        }
                        .id(turn.id)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollToken) { _, _ in
                guard let scrollTarget else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
        }
    }

    /// Brings one exchange to the top of the screen.
    private func bringToTop(_ id: UUID) {
        scrollTarget = id
        scrollToken += 1
    }

    /// The empty conversation: what this is, in two lines.
    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Ask your brain")
                .font(.title2.weight(.semibold))
            Text("Ask about anything you've saved — a figure, a date, what someone said. The answer is read out of your own notes, and every source is one tap away.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 12)
    }

    private func questionBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// The reply: what was found, walked through; then the sources it came
    /// from, each a link to the original; then Read aloud.
    private func replyBubble(_ turn: AskTurn, answer: AnswerComposer.Answer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Brain Buddy", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(Self.markdown(answer.written))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !turn.sources.isEmpty {
                sourcesList(turn)
            }

            if answer.hasResults {
                readAloudButton(turn, answer: answer)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Bold and bullets from the composer, or the plain text if the markup
    /// can't be read — never nothing.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func sourcesList(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.sources.count == 1 ? "Source" : "Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            ForEach(turn.sources) { hit in
                NavigationLink(value: hit.item) {
                    sourceRow(hit)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One thing the reply came from. Says what it is and when, so a photo
    /// and a PDF with the same title can be told apart before opening.
    private func sourceRow(_ hit: SearchHit) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.item.kind.systemImage)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(hit.item.kind.title) · \(hit.item.createdAt.filedDateDescription) · \(hit.matchExplanation)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Reading aloud is an action you take on an answer you can already see —
    /// not something that happens the moment results arrive.
    private func readAloudButton(_ turn: AskTurn, answer: AnswerComposer.Answer) -> some View {
        let isSpeakingThis = services.speaker.isSpeaking && speakingTurn == turn.id
        return Button {
            if isSpeakingThis {
                services.speaker.stop()
                speakingTurn = nil
            } else {
                speakingTurn = turn.id
                services.speaker.speak(answer.spoken)
            }
        } label: {
            Label(
                isSpeakingThis ? "Stop" : "Read aloud",
                systemImage: isSpeakingThis ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(.footnote.weight(.medium))
            .padding(.vertical, 6)
            .padding(.horizontal, 11)
            .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var thinkingBubble: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Looking through your brain…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - The composer

    /// The bottom of the screen: the suggestions while the conversation is
    /// empty, then the box and the microphone. Sits inside the safe area, so
    /// the keyboard lifts the whole thing.
    private var composer: some View {
        VStack(spacing: 10) {
            if showsSuggestions {
                suggestionList
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputRow
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: showsSuggestions)
        .animation(.easeInOut(duration: 0.2), value: transcriber.isListening)
    }

    /// Only while there is nothing to read.
    ///
    /// They used to come back whenever you tapped an empty box, which put five
    /// rows of "try asking" between the keyboard and the answer you had just
    /// asked for — the reply gets a third of the screen and the suggestions
    /// get the rest. Once a conversation exists, the space belongs to it;
    /// *New conversation* brings the suggestions back.
    private var showsSuggestions: Bool {
        turns.isEmpty && !transcriber.isListening
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions, id: \.self) { prompt in
                Button {
                    ask(prompt)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "quote.opening")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Two stock questions, then questions about what you actually saved
    /// most recently — a suggestion that names your own note is one you can
    /// tap without thinking.
    private var suggestions: [String] {
        var prompts = ["What did I save about the dentist?", "Show me everything from last week"]
        for item in memories.prefix(6) where prompts.count < 5 {
            let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 4 else { continue }
            let short = title.count > 36 ? String(title.prefix(35)).trimmingCharacters(in: .whitespaces) + "…" : title
            prompts.append("What did I save about “\(short)”?")
        }
        if prompts.count < 4 { prompts.append("The receipt I photographed") }
        return prompts
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if transcriber.isListening {
                    Text(transcriber.liveTranscript.isEmpty ? "Listening…" : transcriber.liveTranscript)
                        .font(.body)
                        .foregroundStyle(transcriber.liveTranscript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Ask anything you've saved…", text: $query, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...5)
                        .focused($isFieldFocused)
                        .submitLabel(.send)
                        .onSubmit { ask(query) }
                }
            }
            .padding(.vertical, 9)
            .padding(.leading, 4)

            trailingButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// One button, three jobs, decided by what you're doing: listening shows
    /// Stop, typed text shows Send, and an empty box shows the microphone.
    @ViewBuilder
    private var trailingButton: some View {
        if transcriber.isListening {
            Button(action: toggleListening) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .symbolEffect(.pulse, isActive: true)
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop listening")
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                ask(query)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send")
        } else {
            Button(action: toggleListening) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask by voice")
        }
    }

    // MARK: - Actions

    private func toggleListening() {
        services.speaker.stop()
        if transcriber.isListening {
            transcriber.stopListening()
            return
        }
        isFieldFocused = false
        query = ""

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

    private func startOver() {
        services.speaker.stop()
        speakingTurn = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            turns = []
        }
    }

    /// Asks one question.
    ///
    /// Your question appears **immediately**, at the top of the screen, and
    /// the reply fills in underneath it. It used to be held back until the
    /// reply was ready, so pressing send emptied the box and showed nothing
    /// at all for a moment — and then landed you at the bottom of an answer
    /// you hadn't read the beginning of.
    ///
    /// Searching is explicit — on send, on a voice result, or from a
    /// suggestion — rather than debounced on every keystroke. A box that
    /// empties itself when the reply arrives can't also be searched as you
    /// type it.
    private func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAwaitingReply else { return }

        services.speaker.stop()
        query = ""
        // The answer is the point, and it is taller than the third of a screen
        // the keyboard would leave it.
        isFieldFocused = false

        let turn = AskTurn(question: trimmed)
        turns.append(turn)
        bringToTop(turn.id)

        let hits = services.search.search(query: trimmed, in: memories, limit: 30)
        let terms = Tokenizer.queryTokens(in: trimmed)
        let quoted = Array(hits.prefix(Self.sourcesPerReply))

        let composed = AnswerComposer.compose(
            query: trimmed,
            sources: quoted.map { hit in
                AnswerSource(
                    identifier: hit.item.identifier,
                    title: hit.item.displayTitle,
                    snippet: hit.snippet,
                    lines: SearchEngine.relevantLines(
                        for: terms,
                        in: [hit.item.text, hit.item.extractedText, hit.item.summary]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n"),
                        limit: AnswerComposer.linesPerSource
                    ),
                    createdAt: hit.item.createdAt,
                    kindTitle: hit.item.kind.title,
                    score: hit.score
                )
            },
            totalMatches: hits.count
        )

        // Everything that matched is listed, not only what the reply quoted:
        // the sixth match may be the one you were thinking of.
        let sources = Array(hits.prefix(Self.sourcesListed))

        Task {
            // Long enough for the question to land and the spinner to be seen
            // as a reply being prepared, rather than the screen changing under
            // your thumb.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
            turns[index].answer = composed
            turns[index].sources = sources
            // Held at the top again: the reply grew underneath the question,
            // and the question is where reading starts.
            bringToTop(turn.id)

            // Only when the user has explicitly turned automatic reading on.
            if speakAnswers, composed.hasResults {
                speakingTurn = turn.id
                services.speaker.speak(composed.spoken)
            }
        }
    }

    /// How many sources a reply walks through, and how many it lists. Reading
    /// out five is a reply; reading out twenty is a search results page with
    /// a paragraph on top.
    private static let sourcesPerReply = 5
    private static let sourcesListed = 8
}

/// One exchange: what you asked and what came back, with the memories the
/// reply was built from so the rows under it can open them.
///
/// The answer is optional because the question goes on screen the instant you
/// send it; `nil` is the moment in between, drawn as the spinner.
struct AskTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: AnswerComposer.Answer?
    var sources: [SearchHit] = []
}
