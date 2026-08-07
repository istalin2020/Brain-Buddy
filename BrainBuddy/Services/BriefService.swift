import Foundation
import Observation
import SwiftData

/// Owns the morning brief: when it gets built, what goes in it, and what you've
/// closed off.
///
/// **On "generated at 8 am".** iOS does not let an app wake at a fixed time to do
/// work — there is no guaranteed background slot, and asking for one would be a
/// lie dressed as a feature. So the 8 am *notification* is the alarm, and the
/// brief is built the first time you open the app that day, stamped with the time
/// it was actually built. Building it takes milliseconds and reads only local
/// data, so opening the notification and reading the brief are the same gesture.
@MainActor
@Observable
final class BriefService {
    /// When the most recent brief was built. Stored as the moment rather than the
    /// day, so it can answer both "was today's already built?" (same-day compare)
    /// and "built at 8:04" for the header.
    private static let lastBuiltKey = "brief.lastBuiltAt"

    private(set) var lastBuiltAt: Date?
    private(set) var lastError: String?

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Building

    /// Builds today's brief if it hasn't been built yet. Returns how many lines
    /// were added.
    @discardableResult
    func generateIfNeeded(for now: Date = Date(), in context: ModelContext) -> Int {
        if let built = UserDefaults.standard.object(forKey: Self.lastBuiltKey) as? Date,
           calendar.isDate(built, inSameDayAs: now) {
            lastBuiltAt = built
            return 0
        }
        return generate(for: now, in: context)
    }

    /// Rebuilds today's brief unconditionally — the Refresh action, and what runs
    /// after you capture something and want it reflected straight away.
    ///
    /// Existing lines are kept as they are, including ones you've closed, so
    /// refreshing can only ever *add*.
    @discardableResult
    func generate(for now: Date = Date(), in context: ModelContext) -> Int {
        let day = calendar.startOfDay(for: now)

        guard let memories = fetchMemories(in: context) else {
            lastError = "Couldn't read your memories to build today's brief."
            return 0
        }

        // Only what you actually said feeds a brief.
        //
        // `extractedText` — OCR off a photo, a PDF's text layer — is reference
        // material, not a commitment. A scanned lab report contains no tasks, and
        // its printed timestamps are not your calendar; reading them as one
        // produced a brief full of "2 - 2.54 at 2:00 PM". So a line can only come
        // from text you typed, dictated or spoke, or from a summary you reviewed
        // and pressed Save on. To get something out of a document and into your
        // brief, write it down or summarize the document.
        let sources = memories.compactMap { item -> BriefSource? in
            let authored = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authored.isEmpty || !summary.isEmpty else { return nil }

            return BriefSource(
                identifier: item.identifier,
                title: item.displayTitle,
                text: authored,
                summary: summary,
                createdAt: item.createdAt,
                kindTitle: item.kind.sourceLabel
            )
        }

        let candidates = BriefBuilder.build(for: day, from: sources, calendar: calendar)
        let known = existingKeys(around: day, in: context)

        var added = 0
        var nextIndex = (highestSortIndex(on: day, in: context) ?? -1) + 1
        for candidate in candidates {
            let key = BriefEntry.dedupeKey(for: candidate.text)
            guard !known.blocks(candidate.kind, key: key) else { continue }

            context.insert(BriefEntry(
                day: day,
                kind: candidate.kind,
                text: candidate.text,
                headline: candidate.headline,
                detail: candidate.detail,
                scheduledAt: candidate.scheduledAt,
                sourceIdentifier: candidate.sourceIdentifier,
                sortIndex: nextIndex
            ))
            nextIndex += 1
            added += 1
        }

        save(context)
        UserDefaults.standard.set(now, forKey: Self.lastBuiltKey)
        lastBuiltAt = now
        return added
    }

    // MARK: - Closing and reopening

    func close(_ entry: BriefEntry, in context: ModelContext) {
        entry.isClosed = true
        entry.closedAt = Date()
        save(context)
    }

    func reopen(_ entry: BriefEntry, in context: ModelContext) {
        entry.isClosed = false
        entry.closedAt = nil
        save(context)
    }

    func toggle(_ entry: BriefEntry, in context: ModelContext) {
        entry.isClosed ? reopen(entry, in: context) : close(entry, in: context)
    }

    /// Drops a line from the brief without closing it — for something that turned
    /// out not to be a task at all.
    func remove(_ entry: BriefEntry, in context: ModelContext) {
        context.delete(entry)
        save(context)
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Fetching

    private func fetchMemories(in context: ModelContext) -> [MemoryItem]? {
        let descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { !$0.isTrashed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try? context.fetch(descriptor)
    }

    /// The lines already in the brief, split by how far back they should block a
    /// re-add. Which window applies depends on what kind of line it is.
    private struct KnownKeys {
        /// Everything in today's brief, whatever state it's in.
        var today: Set<String> = []
        /// Everything in the look-back window, open or closed.
        var window: Set<String> = []

        func blocks(_ kind: BriefEntryKind, key: String) -> Bool {
            switch kind {
            case .schedule:
                // A dated line recurs legitimately: standup on Tuesday and
                // standup on Wednesday are the same sentence and two different
                // occurrences. Only today's brief can duplicate it.
                return today.contains(key)
            case .task, .point:
                // A task you closed is done; it must not come back tomorrow. One
                // still open is already visible as a carried-over line, so
                // re-adding it would split one commitment across two rows.
                return window.contains(key)
            }
        }
    }

    private func existingKeys(around day: Date, in context: ModelContext) -> KnownKeys {
        guard let cutoff = calendar.date(byAdding: .day, value: -BriefBuilder.taskLookBackDays, to: day) else {
            return KnownKeys()
        }
        let descriptor = FetchDescriptor<BriefEntry>(predicate: #Predicate { $0.day >= cutoff })
        guard let entries = try? context.fetch(descriptor) else { return KnownKeys() }

        var known = KnownKeys()
        for entry in entries {
            let key = entry.dedupeKey
            known.window.insert(key)
            if calendar.isDate(entry.day, inSameDayAs: day) { known.today.insert(key) }
        }
        return known
    }

    private func highestSortIndex(on day: Date, in context: ModelContext) -> Int? {
        var descriptor = FetchDescriptor<BriefEntry>(
            predicate: #Predicate { $0.day == day },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.sortIndex
    }

    private func save(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            lastError = "Couldn't save the brief: \(error.localizedDescription)"
        }
    }
}
