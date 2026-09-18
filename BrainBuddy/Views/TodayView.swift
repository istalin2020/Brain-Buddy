import SwiftData
import SwiftUI

/// This morning's brief, as four cards.
///
/// It was one flat list with a quoted paragraph under every row, and at twenty
/// lines that is a wall rather than a plan — you cannot see the shape of your
/// day in it. Now each group is a card with a coloured tile, a count and five
/// rows, and everything past that is one tap behind **+N more**. The quote moves
/// where quotes belong: inside the note, when you go looking for it.
///
/// The cards are the four questions a morning has: **Reminders** (what has a
/// day or a time on it), **Office to-do**, **Personal to-do**, and
/// **Important info** (worth remembering, nothing to do). Every line the brief
/// pulled out of your documents lands on exactly one of them — see
/// `BriefGrouping` for the order they are claimed in.
///
/// Everything here was already in your brain. The brief doesn't add knowledge,
/// it just puts today's slice of it in front of you at the hour you asked for.
@MainActor
struct TodayView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    /// A month's worth is plenty: today's lines, plus anything still open behind
    /// them. Bounded so the query doesn't grow without limit over years of use.
    @Query private var entries: [BriefEntry]

    /// Used to resolve the "open the note this came from" links, and to decide
    /// whose work a line is. Same whole-library query the Ask and Brain tabs
    /// already use.
    @Query(filter: #Predicate<MemoryItem> { !$0.isTrashed })
    private var memories: [MemoryItem]

    @State private var expanded: Set<BriefGroupKind> = []
    @State private var isRefreshing = false
    @State private var refreshNotice: String?
    @State private var noticeDismissal: Task<Void, Never>?

    /// What each source document is about — work, family, friends — so a line
    /// that doesn't say can take its answer from the note it came from.
    /// Classification tokenizes the whole document, so it runs off the main
    /// actor once per change rather than in every body pass.
    @State private var sourceRegions: [UUID: BrainRegion] = [:]

    /// What a card looks like, named once.
    ///
    /// Both are spelled out rather than inferred — `Color(uiColor:)` rather than
    /// `Color(.secondarySystemBackground)`, which would leave the compiler to
    /// work out whether that leading dot is a `UIColor` member or a `ShapeStyle`
    /// one. They are applied with `background { shape.fill(colour) }` rather
    /// than `background(_:in:)`, because the style-and-shape overload is one of
    /// several and picking between them is exactly the work that fails first
    /// when a builder gets long.
    private static let cardFill = Color(uiColor: .secondarySystemBackground)
    private static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// Recomputed rather than stored, so a session left open overnight rolls onto
    /// the new day instead of showing yesterday as "today".
    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    init() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -30,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date.distantPast
        _entries = Query(
            filter: #Predicate<BriefEntry> { $0.day >= cutoff },
            sort: \BriefEntry.sortIndex
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today")
                .navigationDestination(for: MemoryItem.self) { item in
                    MemoryDetailView(item: item)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Today answers "what now"; the review answers "how is
                        // it actually going", which is a different question and
                        // belongs one tap away rather than on the same screen.
                        NavigationLink {
                            ReviewView()
                        } label: {
                            Label("Review", systemImage: "chart.bar.doc.horizontal")
                        }
                    }
                }
                // The brief is built here rather than at 8 am by a background
                // task, because iOS grants no guaranteed slot at a fixed time.
                // The 8 am notification is the alarm; this is the work, and it
                // takes milliseconds off purely local data.
                .task {
                    services.brief.generateIfNeeded(in: modelContext)
                    await services.offerMorningBriefIfNeeded()
                    await services.refreshReminders(in: modelContext)
                }
                .task(id: classificationSignature) { await classifySources() }
        }
    }

    // MARK: - The board

    /// Grouped once per body pass and handed down, so the header's counts and
    /// the cards can never disagree — the header used to count every line in
    /// the database, including the ones no card claimed.
    @ViewBuilder
    private var content: some View {
        let grouped = groupedEntries()
        if grouped.isEmpty {
            emptyState
        } else {
            board(grouped)
        }
    }

    private func board(_ grouped: [BriefGroupKind: [BriefEntry]]) -> some View {
        // Resolved once per body pass. A per-row fetch would run on every render
        // of every line, which is the kind of thing that makes a list stutter.
        let sources = sourceLookup()

        return ScrollView {
            LazyVStack(spacing: 16) {
                header(grouped)

                ForEach(BriefGroupKind.display) { group in
                    if let lines = grouped[group], !lines.isEmpty {
                        card(group, lines: lines, sources: sources)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    /// Changes whenever the set of source documents, or any of their text,
    /// could have changed.
    private var classificationSignature: String {
        let newest = memories.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        return "\(entries.count)-\(memories.count)-\(Int(newest))"
    }

    /// What each referenced document is about, computed off the main actor.
    private func classifySources() async {
        let wanted = Set(entries.compactMap(\.sourceIdentifier))
        guard !wanted.isEmpty else {
            sourceRegions = [:]
            return
        }
        let inputs = memories
            .filter { wanted.contains($0.identifier) }
            .map { BrainFileInput($0) }

        let regions = await Task.detached(priority: .userInitiated) {
            Dictionary(
                inputs.compactMap { input in
                    BrainClassifier.lexicalRegion(for: input).map { (input.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        }.value
        sourceRegions = regions
    }

    private func header(_ grouped: [BriefGroupKind: [BriefEntry]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.title3.weight(.semibold))
                    Text(refreshNotice ?? progressLine(in: grouped))
                        .font(.caption)
                        .foregroundStyle(refreshNotice == nil ? .secondary : Color.accentColor)
                }

                Spacer(minLength: 8)

                // Anything captured later in the day only appears once the brief
                // is rebuilt, so this is the one control people reach for here.
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Self.cardShape.fill(Self.cardFill) }
    }

    /// One group: a coloured tile, a count, and its rows.
    ///
    /// Deliberately four short calls rather than one long builder. The long
    /// version — a header, a `ForEach` over enumerated rows with a conditional
    /// divider inside it, and two more conditionals after it — is more than the
    /// type checker will solve in one go, and what it reports when it gives up
    /// is "Ambiguous use of background(_:in:fillStyle:)" on the last line, which
    /// points at the one part that was never the problem.
    private func card(
        _ group: BriefGroupKind,
        lines: [BriefEntry],
        sources: [UUID: MemoryItem]
    ) -> some View {
        let isOpen = expanded.contains(group)
        let visible = visibleLines(group, lines: lines, isOpen: isOpen)
        let hidden = lines.count - visible.count

        return VStack(spacing: 0) {
            cardHeader(group, count: lines.count, isOpen: isOpen)
            cardRows(visible, group: group, sources: sources)
            moreButton(group, hidden: hidden)
            caption(group, isOpen: isOpen)
        }
        .background { Self.cardShape.fill(Self.cardFill) }
    }

    /// "Done today" stays shut however few there are: it's a record of work, not
    /// a list of it, and it should never push today's own cards down.
    private func visibleLines(
        _ group: BriefGroupKind,
        lines: [BriefEntry],
        isOpen: Bool
    ) -> [BriefEntry] {
        if group == .done { return isOpen ? lines : [] }
        return isOpen ? lines : Array(lines.prefix(BriefGrouping.collapsedRowLimit))
    }

    @ViewBuilder
    private func cardRows(
        _ lines: [BriefEntry],
        group: BriefGroupKind,
        sources: [UUID: MemoryItem]
    ) -> some View {
        // `pair` rather than destructuring into `(index, entry)`: one less thing
        // for the checker to infer inside a builder.
        ForEach(Array(lines.enumerated()), id: \.element.identifier) { pair in
            VStack(spacing: 0) {
                if pair.offset > 0 {
                    Divider().padding(.leading, 52)
                }
                row(pair.element, group: group, source: source(of: pair.element, in: sources))
            }
        }
    }

    @ViewBuilder
    private func moreButton(_ group: BriefGroupKind, hidden: Int) -> some View {
        if hidden > 0 {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    // Discarded explicitly. `Set.insert` returns
                    // `(inserted: Bool, memberAfterInsert: Element)`, and a
                    // single-expression closure adopts its expression's type as
                    // its return type — so `withAnimation` gets told its Result
                    // is that tuple while the call site needs Void.
                    _ = expanded.insert(group)
                }
            } label: {
                Text(group == .done ? "Show \(hidden)" : "+\(hidden) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    /// Why these lines are together. Only while the card is open, so the closed
    /// state stays clean.
    @ViewBuilder
    private func caption(_ group: BriefGroupKind, isOpen: Bool) -> some View {
        if isOpen {
            Text(group.caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private func cardHeader(_ group: BriefGroupKind, count: Int, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                // Both results discarded: `remove` hands back the old member and
                // `insert` a tuple, and either one would become this closure's
                // return type.
                if isOpen {
                    _ = expanded.remove(group)
                } else {
                    _ = expanded.insert(group)
                }
            }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(group.tint)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: group.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("\(count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(count)")
    }

    /// One line: tick it off on the left, read it in the middle, open the note
    /// it came from by tapping the text.
    private func row(_ entry: BriefEntry, group: BriefGroupKind, source: MemoryItem?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                close(entry)
            } label: {
                Image(systemName: entry.isClosed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.isClosed ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isClosed ? "Reopen" : "Close")

            Group {
                if let source {
                    NavigationLink(value: source) { rowText(entry) }
                        .buttonStyle(.plain)
                } else {
                    rowText(entry)
                }
            }

            chip(for: entry, in: group)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contextMenu {
            Button {
                close(entry)
            } label: {
                Label(entry.isClosed ? "Reopen" : "Close", systemImage: entry.isClosed ? "arrow.uturn.backward" : "checkmark")
            }
            Button(role: .destructive) {
                services.brief.remove(entry, in: modelContext)
                rescheduleReminders()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// The small right-hand chip.
    ///
    /// On a reminder it is *when* — the time today, the day this week, the date
    /// otherwise, and red once it has gone by. Everywhere else it is how long
    /// the line has waited, so a to-do from three days ago doesn't look like
    /// this morning's.
    @ViewBuilder
    private func chip(for entry: BriefEntry, in group: BriefGroupKind) -> some View {
        if group == .reminders, let due = due(for: entry) {
            Text(due.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(due.isPast ? Color.red : Color.orange)
                .fixedSize(horizontal: true, vertical: false)
        } else if let badge = BriefGrouping.badge(
            scheduledAt: entry.scheduledAt,
            day: entry.day,
            today: today
        ) {
            Text(badge)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.scheduledAt == nil ? .secondary : Color.accentColor)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// When a reminder falls due: the time the builder detected, or the day
    /// the line itself names.
    private func due(for entry: BriefEntry) -> BriefDue? {
        let date = entry.scheduledAt ?? BriefGrouping.dueDate(in: entry.text, today: today)
        return date.map { BriefGrouping.due(for: $0, today: today) }
    }

    /// The subject only. The full quote lives in the note — printing it here is
    /// what made twenty lines unreadable.
    private func rowText(_ entry: BriefEntry) -> some View {
        Text(entry.subject)
            .font(.callout)
            .strikethrough(entry.isClosed, color: .secondary)
            .foregroundStyle(entry.isClosed ? .secondary : .primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "sun.horizon",
            title: "Nothing for today yet",
            message: "Your brief is built from what you capture. Note something to do, a meeting with a date on it, or record a discussion and save its summary, and it'll be sorted into reminders, office and personal to-dos, and things worth remembering."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Slices

    /// Every line, on exactly one card. See `BriefGrouping` for the order the
    /// cards claim them in.
    private func groupedEntries() -> [BriefGroupKind: [BriefEntry]] {
        var grouped: [BriefGroupKind: [BriefEntry]] = [:]

        for entry in entries {
            guard let group = BriefGrouping.group(
                kind: entry.kind,
                day: entry.day,
                isClosed: entry.isClosed,
                closedAt: entry.closedAt,
                // The full line, not the heading: the heading of a reminder has
                // had its date taken off, and the date is what makes it one.
                text: entry.text,
                sourceRegion: entry.sourceIdentifier.flatMap { sourceRegions[$0] },
                today: today
            ) else { continue }
            grouped[group, default: []].append(entry)
        }

        // Looked up once per reminder rather than once per comparison — the
        // sort below would otherwise run the date detector n·log n times.
        var dueDates: [UUID: Date] = [:]
        for entry in grouped[.reminders] ?? [] {
            dueDates[entry.identifier] = due(for: entry)?.date
        }

        // Snapshotted: mutating the dictionary while iterating its own keys view
        // is an exclusivity violation waiting for a big enough brief.
        for group in Array(grouped.keys) {
            grouped[group]?.sort { lhs, rhs in
                switch group {
                case .reminders:
                    // Soonest first; anything with no readable date after
                    // everything that has one.
                    let left = dueDates[lhs.identifier]
                    let right = dueDates[rhs.identifier]
                    if let left, let right { return left == right ? lhs.day < rhs.day : left < right }
                    if left != nil { return true }
                    if right != nil { return false }
                    return lhs.day < rhs.day
                case .done:
                    return (lhs.closedAt ?? .distantPast) > (rhs.closedAt ?? .distantPast)
                default:
                    // Oldest first everywhere else: a thing you wrote down three
                    // days ago should not sink under this morning's.
                    return lhs.day == rhs.day ? lhs.sortIndex < rhs.sortIndex : lhs.day < rhs.day
                }
            }
        }
        return grouped
    }

    /// Counted from what the cards actually hold, not from the table.
    ///
    /// A line can be in the brief and on no card at all — a record of
    /// something that already happened is filed rather than shown — and
    /// counting the table said "7 things open" over a screen showing six.
    private func progressLine(in grouped: [BriefGroupKind: [BriefEntry]]) -> String {
        let open = grouped
            .filter { $0.key != .done }
            .values
            .reduce(0) { $0 + $1.count }
        let closed = grouped[.done]?.count ?? 0

        if open == 0 && closed > 0 { return "All clear — \(closed) closed today." }
        if open == 0 { return "Nothing open." }

        var line = open == 1 ? "1 thing open" : "\(open) things open"
        if closed > 0 { line += ", \(closed) closed" }
        if let built = services.brief.lastBuiltAt {
            line += " · built \(built.formatted(date: .omitted, time: .shortened))"
        }
        return line
    }

    // MARK: - Actions

    /// The brief links back to the capture each line was quoted from, by
    /// identifier rather than by relationship — see `BriefEntry` for why.
    ///
    /// Built once per body pass and only for the identifiers actually referenced,
    /// rather than per row: a fetch inside a row builder runs on every render of
    /// every line, which is exactly how a list starts to stutter.
    private func sourceLookup() -> [UUID: MemoryItem] {
        let wanted = Set(entries.compactMap(\.sourceIdentifier))
        guard !wanted.isEmpty else { return [:] }
        return Dictionary(
            memories.lazy.filter { wanted.contains($0.identifier) }.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func source(of entry: BriefEntry, in lookup: [UUID: MemoryItem]) -> MemoryItem? {
        entry.sourceIdentifier.flatMap { lookup[$0] }
    }

    private func close(_ entry: BriefEntry) {
        withAnimation(.easeInOut(duration: 0.2)) {
            services.brief.toggle(entry, in: modelContext)
        }
        rescheduleReminders()
    }

    /// The day's reminders name specific open lines, chosen when they were
    /// scheduled, so closing something has to rebuild them or it keeps being
    /// announced.
    private func rescheduleReminders() {
        Task { await services.refreshReminders(in: modelContext) }
    }

    /// Rebuilds today's brief from everything captured since it was last built.
    /// Only ever adds — nothing you closed comes back.
    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let added = services.brief.generate(in: modelContext)
        isRefreshing = false

        // Says what happened. "Added nothing" and "the button is broken" look
        // identical otherwise, which is exactly how this got reported. Updates
        // are counted separately, because a line rewritten to match a note you
        // corrected is the other thing this button does.
        let updated = services.brief.updatedCount
        if let failure = services.brief.lastError {
            refreshNotice = failure
        } else {
            var parts: [String] = []
            if added > 0 { parts.append(added == 1 ? "Added 1 line" : "Added \(added) lines") }
            if updated > 0 { parts.append(updated == 1 ? "updated 1" : "updated \(updated)") }
            refreshNotice = parts.isEmpty ? "Nothing new to add." : parts.joined(separator: ", ") + "."
        }

        rescheduleReminders()

        noticeDismissal?.cancel()
        noticeDismissal = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            refreshNotice = nil
        }
    }
}
