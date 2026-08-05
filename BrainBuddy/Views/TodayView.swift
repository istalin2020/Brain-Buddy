import SwiftData
import SwiftUI

/// This morning's brief: what's on today, what you said you'd do, and the points
/// worth having in mind — each one closable.
///
/// Everything here was already in your brain. The brief doesn't add knowledge, it
/// just puts today's slice of it in front of you at the hour you asked for.
@MainActor
struct TodayView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    /// A month's worth is plenty: today's lines, plus anything still open behind
    /// them. Bounded so the query doesn't grow without limit over years of use.
    @Query private var entries: [BriefEntry]

    /// Used only to resolve the "open the note this came from" links. Same
    /// whole-library query the Ask and Library tabs already use.
    @Query(filter: #Predicate<MemoryItem> { !$0.isTrashed })
    private var memories: [MemoryItem]

    @State private var showClosed = false

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
                    briefList
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            refresh()
                        } label: {
                            Label("Rebuild brief", systemImage: "arrow.clockwise")
                        }
                        Toggle(isOn: $showClosed) {
                            Label("Show closed", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
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
            }
        }
    }

    // MARK: - Content

    private var briefList: some View {
        // Resolved once per body pass. A per-row fetch would run on every render
        // of every line, which is the kind of thing that makes a list stutter.
        let sources = sourceLookup()

        return List {
            headerSection

            ForEach(BriefEntryKind.allCases) { kind in
                let lines = todayEntries.filter { $0.kind == kind }
                if !lines.isEmpty {
                    Section {
                        ForEach(lines) { entry in
                            row(entry, source: source(of: entry, in: sources))
                        }
                    } header: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            }

            if !carriedOver.isEmpty {
                Section {
                    ForEach(carriedOver) { entry in
                        row(entry, source: source(of: entry, in: sources), showDay: true)
                    }
                } header: {
                    Label("Still open from before", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text("Left open on an earlier day. Close it here and it stops following you around.")
                }
            }

            if showClosed, !closedToday.isEmpty {
                Section("Closed today") {
                    ForEach(closedToday) { entry in
                        row(entry, source: source(of: entry, in: sources))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.title3.weight(.semibold))
                Text(progressLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func row(_ entry: BriefEntry, source: MemoryItem?, showDay: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                services.brief.toggle(entry, in: modelContext)
            } label: {
                Image(systemName: entry.isClosed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.isClosed ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isClosed ? "Reopen" : "Close")

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.callout)
                    .strikethrough(entry.isClosed, color: .secondary)
                    .foregroundStyle(entry.isClosed ? .secondary : .primary)

                HStack(spacing: 6) {
                    if let time = entry.scheduledTimeLabel {
                        Text(time)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    if showDay {
                        Text(entry.day.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            // Only the chevron navigates: the rest of the row belongs to the
            // close button, and a whole-row link would swallow those taps.
            if let source {
                NavigationLink(value: source) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Open the note this came from")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                services.brief.toggle(entry, in: modelContext)
            } label: {
                Label(entry.isClosed ? "Reopen" : "Close", systemImage: entry.isClosed ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(entry.isClosed ? .orange : .green)

            Button(role: .destructive) {
                services.brief.remove(entry, in: modelContext)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
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

    private var todayEntries: [BriefEntry] {
        entries.filter { Calendar.current.isDate($0.day, inSameDayAs: today) && !$0.isClosed }
    }

    private var closedToday: [BriefEntry] {
        entries.filter { Calendar.current.isDate($0.day, inSameDayAs: today) && $0.isClosed }
    }

    /// Open lines from earlier days. A task doesn't stop mattering at midnight, so
    /// it follows you forward instead of quietly disappearing from yesterday.
    private var carriedOver: [BriefEntry] {
        entries
            .filter { !$0.isClosed && $0.day < today }
            .sorted { $0.day > $1.day }
    }

    private var isEmpty: Bool {
        todayEntries.isEmpty && carriedOver.isEmpty && !(showClosed && !closedToday.isEmpty)
    }

    private var progressLine: String {
        let open = todayEntries.count + carriedOver.count
        let closed = closedToday.count
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

    private func refresh() {
        services.brief.generate(in: modelContext)
    }
}
