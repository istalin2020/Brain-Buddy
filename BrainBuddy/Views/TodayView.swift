import SwiftData
import SwiftUI

/// This morning's brief, as a handful of cards.
///
/// It was one flat list with a quoted paragraph under every row, and at twenty
/// lines that is a wall rather than a plan — you cannot see the shape of your
/// day in it. Now each group is a card with a coloured tile, a count and five
/// rows, and everything past that is one tap behind **+N more**. The quote moves
/// where quotes belong: inside the note, when you go looking for it.
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

    /// Used only to resolve the "open the note this came from" links. Same
    /// whole-library query the Ask and Brain tabs already use.
    @Query(filter: #Predicate<MemoryItem> { !$0.isTrashed })
    private var memories: [MemoryItem]

    @State private var expanded: Set<BriefGroupKind> = []
    @State private var isRefreshing = false
    @State private var refreshNotice: String?
    @State private var noticeDismissal: Task<Void, Never>?

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
            Group {
                if isEmpty {
                    emptyState
                } else {
                    board
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Today answers "what now"; the review answers "how is it
                    // actually going", which is a different question and belongs
                    // one tap away rather than on the same screen.
                    NavigationLink {
                        ReviewView()
                    } label: {
                        Label("Review", systemImage: "chart.bar.doc.horizontal")
                    }
                }
            }
            // The brief is built here rather than at 8 am by a background task,
            // because iOS grants no guaranteed slot at a fixed time. The 8 am
            // notification is the alarm; this is the work, and it takes
            // milliseconds off purely local data.
            .task {
                services.brief.generateIfNeeded(in: modelContext)
                await services.offerMorningBriefIfNeeded()
                await services.refreshReminders(in: modelContext)
            }
        }
    }

    // MARK: - The board

    private var board: some View {
        // Resolved once per body pass. A per-row fetch would run on every render
        // of every line, which is the kind of thing that makes a list stutter.
        let sources = sourceLookup()
        let grouped = groupedEntries()

        return ScrollView {
            LazyVStack(spacing: 16) {
                header

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.title3.weight(.semibold))
                    Text(refreshNotice ?? progressLine)
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
            cardRows(visible, sources: sources)
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
    private func cardRows(_ lines: [BriefEntry], sources: [UUID: MemoryItem]) -> some View {
        // `pair` rather than destructuring into `(index, entry)`: one less thing
        // for the checker to infer inside a builder.
        ForEach(Array(lines.enumerated()), id: \.element.identifier) { pair in
            VStack(spacing: 0) {
                if pair.offset > 0 {
                    Divider().padding(.leading, 52)
                }
                row(pair.element, source: source(of: pair.element, in: sources))
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
    private func row(_ entry: BriefEntry, source: MemoryItem?) -> some View {
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

            if let badge = BriefGrouping.badge(
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
            message: "Your brief is built from what you capture. Note a meeting with a date on it, or record a discussion and save its summary, and it'll show up here tomorrow morning."
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
                text: entry.subject,
                today: today
            ) else { continue }
            grouped[group, default: []].append(entry)
        }

        // Snapshotted: mutating the dictionary while iterating its own keys view
        // is an exclusivity violation waiting for a big enough brief.
        for group in Array(grouped.keys) {
            grouped[group]?.sort { lhs, rhs in
                switch group {
                case .priorities:
                    // What's happening today first, in the order it happens;
                    // then whatever has been waiting longest.
                    if let left = lhs.scheduledAt, let right = rhs.scheduledAt { return left < right }
                    if lhs.scheduledAt != nil { return true }
                    if rhs.scheduledAt != nil { return false }
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

    private var openCount: Int {
        entries.filter { !$0.isClosed }.count
    }

    private var closedTodayCount: Int {
        entries.filter { entry in
            guard entry.isClosed, let closedAt = entry.closedAt else { return false }
            return Calendar.current.isDate(closedAt, inSameDayAs: today)
        }.count
    }

    private var isEmpty: Bool { openCount == 0 && closedTodayCount == 0 }

    private var progressLine: String {
        let open = openCount
        let closed = closedTodayCount
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
