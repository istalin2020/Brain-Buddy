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

    /// Where the cursor is in `query`, in the text view's own units. Spoken
    /// words go in here.
    @State private var selection = NSRange(location: 0, length: 0)
    /// The words being heard, and where they sit in the box. Non-nil exactly
    /// while *this* screen owns the recognizer — the same splice the Input box
    /// uses, so what you type or fix while speaking is never undone by the
    /// next word heard. See `DictationSplice`.
    @State private var dictation: DictationSplice?
    @State private var isFieldFocused = false

    private var transcriber: SpeechTranscriber { services.transcriber }
    private var isDictating: Bool { dictation != nil }

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
                // Words appear in the box as they are recognised, at the cursor.
                .onChange(of: transcriber.liveTranscript) { _, spoken in
                    // Cancelling blanks the live transcript; without this the
                    // blank would be merged in.
                    guard transcriber.isListening else { return }
                    hear(spoken)
                }
                .onDisappear {
                    if isDictating { transcriber.cancelListening() }
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
                    sourceRow(hit, evidence: turn.evidence[hit.item.identifier])
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One thing the reply came from. Says what it is and when, so a photo
    /// and a PDF with the same title can be told apart before opening — and,
    /// under a one-answer reply, the line the answer was read from.
    private func sourceRow(_ hit: SearchHit, evidence: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.item.kind.systemImage)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let evidence {
                    Text("“\(evidence)”")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(2)
                }
                Text(evidence == nil
                     ? "\(hit.item.kind.title) · \(hit.item.createdAt.filedDateDescription) · \(hit.matchExplanation)"
                     : "\(hit.item.kind.title) · \(hit.item.createdAt.filedDateDescription)")
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
        .animation(.easeInOut(duration: 0.2), value: isDictating)
    }

    /// Only while there is nothing to read.
    ///
    /// They used to come back whenever you tapped an empty box, which put five
    /// rows of "try asking" between the keyboard and the answer you had just
    /// asked for — the reply gets a third of the screen and the suggestions
    /// get the rest. Once a conversation exists, the space belongs to it;
    /// *New conversation* brings the suggestions back.
    private var showsSuggestions: Bool {
        turns.isEmpty && !isDictating
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
        HStack(alignment: .bottom, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if query.isEmpty {
                    Text(isDictating ? "Listening…" : "Ask anything you've saved…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                // Editable while the mic listens, like the Input box: the
                // words land at the cursor and your edits stay.
                DraftTextView(
                    text: query,
                    selection: selection,
                    isFocused: $isFieldFocused,
                    minHeight: 36,
                    // About five lines, then it scrolls.
                    maxHeight: 130,
                    onReturn: { ask(query) },
                    onEdit: userEdited,
                    onSelect: userSelected
                )
            }
            .padding(.vertical, 2)

            micButton
            if canSend { sendButton }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var canSend: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Always there, so you can put the cursor anywhere in a question and
    /// speak into it. While listening it is a **stop** button — a waveform
    /// said "sound is happening", not "tap here to finish".
    private var micButton: some View {
        Button(action: toggleListening) {
            Image(systemName: isDictating ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 32))
                .symbolEffect(.pulse, isActive: isDictating)
                .foregroundStyle(isDictating ? Color.red : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDictating ? "Stop listening" : "Ask by voice, at the cursor")
    }

    /// Sends whatever is in the box, as you left it — including while the
    /// mic is still listening, since the words heard so far are already there.
    private var sendButton: some View {
        Button {
            ask(query)
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send")
    }

    // MARK: - Actions

    /// Speaks into the box at the cursor. It no longer empties the box or
    /// sends by itself: what you said stays there to check, fix or add to,
    /// and ↑ sends it.
    private func toggleListening() {
        services.speaker.stop()
        if isDictating {
            // Ends audio capture; the recognizer's final, punctuated pass lands
            // a moment later through `onFinalTranscript`.
            transcriber.stopListening()
            return
        }
        // The Input tab holds the microphone. Leave it alone rather than
        // fighting over one recognizer.
        guard !transcriber.isListening else {
            errorMessage = "Dictation is already running on the Input tab. Stop it there first."
            return
        }

        dictation = DictationSplice(text: query, cursor: selection)

        // Assigned here rather than when the view appears: the capture editor
        // dictates through the same recognizer, and whichever screen starts a
        // session owns its result. The final pass goes through the splice, so
        // it can only reword the words still live.
        transcriber.onFinalTranscript = { spoken in hear(spoken) }
        transcriber.onSessionEnd = { dictation = nil }

        Task {
            do {
                // Stops by itself after a pause — questions are short.
                try await transcriber.startListening()
                // Starting can wait on a permission prompt, and leaving the tab
                // ends the session meanwhile. Don't leave a recognizer running
                // with no owner.
                if dictation == nil { transcriber.cancelListening() }
            } catch {
                dictation = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Words heard: they go into the live span, and the cursor follows them.
    private func hear(_ spoken: String) {
        guard var splice = dictation else { return }
        splice.hear(spoken)
        dictation = splice
        query = splice.text
        selection = splice.caret
    }

    /// You typed, deleted or pasted. While listening, the splice works out
    /// where the words being heard are now; otherwise it is just typing.
    private func userEdited(_ text: String, _ cursor: NSRange) {
        if var splice = dictation {
            splice.userEdited(to: text, selection: cursor)
            dictation = splice
        }
        query = text
        selection = cursor
    }

    /// You moved the cursor. Ignored if the text on screen is not the text we
    /// hold — a cursor move arriving just ahead of its own edit.
    private func userSelected(_ text: String, _ cursor: NSRange) {
        guard text == query else { return }
        if var splice = dictation {
            splice.userMoved(cursor)
            dictation = splice
        }
        selection = cursor
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
        // The words heard so far are already in the box, so stopping loses
        // nothing that is being sent.
        if isDictating {
            transcriber.cancelListening()
            dictation = nil
        }
        query = ""
        selection = NSRange(location: 0, length: 0)
        // The answer is the point, and it is taller than the third of a screen
        // the keyboard would leave it.
        isFieldFocused = false

        let turn = AskTurn(question: trimmed)
        turns.append(turn)
        bringToTop(turn.id)

        // Named `outcome` rather than `reply`: a local called `reply` would
        // shadow the method it is calling in its own initializer.
        let outcome = reply(to: trimmed)
        let composed = outcome.answer

        Task {
            // Long enough for the question to land and the spinner to be seen
            // as a reply being prepared, rather than the screen changing under
            // your thumb.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
            turns[index].answer = composed
            turns[index].sources = outcome.sources
            turns[index].evidence = outcome.evidence
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
    /// How many a question with one answer shows when the answer couldn't be
    /// read: the closest few, not everything that shared a word with it.
    private static let closestForUnanswered = 3

    // MARK: - Working out the reply

    private struct Reply {
        var answer: AnswerComposer.Answer
        var sources: [SearchHit]
        /// The line each source was read from, when the reply is one answer.
        var evidence: [UUID: String] = [:]
    }

    /// Search finds the documents; then, if the question has one answer, the
    /// reader finds it inside them.
    ///
    /// Three outcomes, in order of how much they say:
    ///
    /// - **An answer.** "What is my name?" → "Your name is Joseph Stalin.",
    ///   with only the documents that say so listed under it, each showing
    ///   the line it was read from.
    /// - **A question with one answer that couldn't be read.** Says so, and
    ///   lists the closest three rather than walking through everything that
    ///   happened to contain the word.
    /// - **Any other question** — "what's on my purchase list" — gets the
    ///   passage-by-passage reply, which is what those questions want.
    private func reply(to question: String) -> Reply {
        // Weak matches are dropped before anything is shown. A question about
        // a purchase list should not list a meeting invitation underneath the
        // answer, however politely.
        let hits = SearchEngine.confident(services.search.search(query: question, in: memories, limit: 30))

        if let factoid = AnswerExtractor.question(from: question) {
            if let found = AnswerExtractor.answer(factoid, in: readerDocuments(for: hits)) {
                let supporting = found.evidence.compactMap { evidence in
                    hit(for: evidence.source, in: hits, line: evidence.line)
                }
                return Reply(
                    answer: AnswerComposer.direct(found, sources: supporting.map { answerSource($0) }),
                    sources: supporting,
                    evidence: Dictionary(
                        found.evidence.map { ($0.source, $0.line) },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
            }

            return unanswered(factoid, hits: hits)
        }

        let terms = Tokenizer.queryTokens(in: question)
        let quoted = Array(hits.prefix(Self.sourcesPerReply))
        return Reply(
            answer: AnswerComposer.compose(
                query: question,
                sources: quoted.map { answerSource($0, terms: terms) },
                totalMatches: min(hits.count, Self.sourcesListed)
            ),
            // Every match worth having is listed, not only what the reply
            // quoted: the sixth match may be the one you were thinking of.
            sources: Array(hits.prefix(Self.sourcesListed))
        )
    }

    /// A question with one answer that nothing answered.
    ///
    /// Says so, and lists only documents that mention what was asked for *as a
    /// phrase*, each with the line that does. Asked for a blood group, the old
    /// reply listed a lab report for "GROUP OF HOSPITALS" and "WHOLE BLOOD",
    /// plus two notes that shared no word with the question at all — three
    /// sources, none of them about a blood group. If nothing mentions it, the
    /// reply is the one sentence and no sources: an empty list is the honest
    /// one.
    private func unanswered(_ question: AnswerExtractor.Question, hits: [SearchHit]) -> Reply {
        var mentions: [SearchHit] = []
        var evidence: [UUID: String] = [:]
        for hit in hits {
            let text = [hit.item.title, hit.item.text, hit.item.extractedText, hit.item.summary]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard let line = AnswerExtractor.linesMentioning(question, in: text, limit: 1).first else { continue }
            mentions.append(hit)
            evidence[hit.item.identifier] = line
            if mentions.count >= Self.closestForUnanswered { break }
        }

        let lead = AnswerExtractor.notFound(question)
        let written = mentions.isEmpty
            ? lead
            : lead + " " + (mentions.count == 1
                ? "This mentions it, if you want to check:"
                : "These mention it, if you want to check:")
        return Reply(
            answer: AnswerComposer.Answer(
                spoken: lead,
                written: written,
                references: [],
                hasResults: false
            ),
            sources: mentions,
            evidence: evidence
        )
    }

    /// What the reader looks through: the search results, best first, and
    /// then every note you wrote yourself.
    ///
    /// The second half matters for questions about you. "Who am I?" shares no
    /// word with "My name is Joseph Stalin", so search alone may never bring
    /// that note up — but it is exactly the sentence the question is about,
    /// and a first-person fact can only be in something you wrote.
    private func readerDocuments(for hits: [SearchHit]) -> [AnswerExtractor.Document] {
        var documents: [AnswerExtractor.Document] = []
        var included = Set<UUID>()

        for (rank, hit) in hits.enumerated() {
            documents.append(readerDocument(hit.item, rank: rank))
            included.insert(hit.item.identifier)
        }
        for item in memories where !included.contains(item.identifier) && !item.text.isEmpty {
            documents.append(readerDocument(item, rank: nil))
        }
        return documents
    }

    private func readerDocument(_ item: MemoryItem, rank: Int?) -> AnswerExtractor.Document {
        // A heading you typed is something you wrote; one the app derived is
        // just the first line again.
        let authored = [
            item.hasCustomTitle ? item.title : "",
            item.text,
            item.summaryIsAutomatic ? "" : item.summary
        ]
        let extracted = [item.extractedText, item.summaryIsAutomatic ? item.summary : ""]
        return AnswerExtractor.Document(
            id: item.identifier,
            authored: authored.filter { !$0.isEmpty }.joined(separator: "\n"),
            extracted: extracted.filter { !$0.isEmpty }.joined(separator: "\n"),
            rank: rank
        )
    }

    /// A source row for a document the reader found the answer in. Usually a
    /// search result already; a note found only by the reader gets a row of
    /// its own, since it is exactly where the answer came from.
    private func hit(for identifier: UUID, in hits: [SearchHit], line: String) -> SearchHit? {
        if let existing = hits.first(where: { $0.item.identifier == identifier }) { return existing }
        guard let item = memories.first(where: { $0.identifier == identifier }) else { return nil }
        return SearchHit(item: item, score: 0, lexicalScore: 0, semanticScore: 0, snippet: line)
    }

    private func answerSource(_ hit: SearchHit) -> AnswerSource {
        answerSource(hit, terms: [])
    }

    private func answerSource(_ hit: SearchHit, terms: [String]) -> AnswerSource {
        AnswerSource(
            identifier: hit.item.identifier,
            title: hit.item.displayTitle,
            snippet: hit.snippet,
            lines: terms.isEmpty ? [] : SearchEngine.relevantLines(
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
    }
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
    /// For a one-answer reply: the line each source was read from, shown on its
    /// row so you can see why it is there without opening it.
    var evidence: [UUID: String] = [:]
}
