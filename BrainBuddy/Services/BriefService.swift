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

    /// How many existing lines the last build brought up to date. Reported
    /// separately from how many were added, because "nothing new to add" and
    /// "two lines now say what your note says" are different outcomes and the
    /// Refresh button should be able to tell you which happened.
    private(set) var updatedCount = 0

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Building

    /// Builds today's brief if it hasn't been built yet. Returns how many lines
    /// were added.
    ///
    /// "Already built" stops new lines being *proposed* twice in a day. It must
    /// not stop existing lines catching up with their notes: edit a note at
    /// 11:34 after the brief was built at 11:26 and skipping the whole pass left
    /// Today quoting the old figure until Refresh was pressed by hand — which
    /// nobody should have to know to do. So the reconciliation half always runs,
    /// on every open and every return to the foreground.
    @discardableResult
    func generateIfNeeded(for now: Date = Date(), in context: ModelContext) -> Int {
        if let built = UserDefaults.standard.object(forKey: Self.lastBuiltKey) as? Date,
           calendar.isDate(built, inSameDayAs: now) {
            lastBuiltAt = built
            updatedCount = reconcileAll(for: now, in: context)
            return 0
        }
        return generate(for: now, in: context)
    }

    /// The reconciliation half of a build on its own: lines catch up with the
    /// notes they were quoted from, and nothing new is proposed.
    ///
    /// Cheap enough for every app activation — a fetch, plus a re-read of only
    /// those notes whose lines are actually out of date.
    @discardableResult
    func reconcileAll(for now: Date = Date(), in context: ModelContext) -> Int {
        guard let memories = fetchMemories(in: context) else { return 0 }
        let changed = refreshEditedLines(
            around: calendar.startOfDay(for: now),
            memories: memories,
            in: context
        )
        if changed > 0 { save(context) }
        return changed
    }

    /// Rebuilds today's brief unconditionally — the Refresh action, and what runs
    /// after you capture something and want it reflected straight away.
    ///
    /// Two things happen, and only these two: lines whose note has been **edited**
    /// are reworded in place, and genuinely new lines are **added**. Nothing you
    /// closed reopens, and no line is dropped except one whose sentence is no
    /// longer in the note it was quoted from.
    @discardableResult
    func generate(for now: Date = Date(), in context: ModelContext) -> Int {
        let day = calendar.startOfDay(for: now)
        // Cleared up front so the caller can read these as the outcome of *this*
        // rebuild rather than of some earlier one.
        lastError = nil
        updatedCount = 0

        guard let memories = fetchMemories(in: context) else {
            lastError = "Couldn't read your memories to build today's brief."
            return 0
        }

        // Lines whose note has been edited since they were made are brought up
        // to date first, so an edit shows up in the brief instead of leaving the
        // old wording sitting there — and so deduplication below compares
        // against what the note says *now*.
        updatedCount = refreshEditedLines(around: day, memories: memories, in: context)
        // Saved before the deduplication fetch below, so it compares against
        // the reworded lines rather than against what they used to say.
        if updatedCount > 0 { save(context) }

        let sources = memories.compactMap(briefSource(for:))
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

    /// Everything still open, newest day first, as the subject each row leads with.
    ///
    /// This is what the day's reminders are dealt from. Closed lines are excluded
    /// for the obvious reason, and the subject is used rather than the full quote
    /// because a notification shows one line.
    func openSubjects(in context: ModelContext, on now: Date = Date()) -> [String] {
        let day = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -BriefBuilder.taskLookBackDays, to: day) else {
            return []
        }
        let descriptor = FetchDescriptor<BriefEntry>(
            predicate: #Predicate { $0.day >= cutoff && !$0.isClosed },
            sortBy: [SortDescriptor(\.day, order: .reverse), SortDescriptor(\.sortIndex)]
        )
        guard let entries = try? context.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        return entries.compactMap { entry in
            let subject = entry.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, seen.insert(entry.dedupeKey).inserted else { return nil }
            return subject
        }
    }

    // MARK: - Keeping lines in step with their source

    /// Brings this memory's brief lines up to date after it has been edited.
    ///
    /// Without this, a brief is a snapshot of what a note said the morning it
    /// was first noticed. Correct the figure in a note from 54,000 to 60,000 and
    /// Today would go on quoting 54,000 for as long as the line stayed open —
    /// which is worse than showing nothing, because it looks like a fact you can
    /// tick off.
    ///
    /// Lines are matched to the note's current wording and **updated in place**,
    /// so what you closed stays closed and a carried-over task keeps its history
    /// rather than reappearing as a new row.
    @discardableResult
    func resync(_ item: MemoryItem, on now: Date = Date(), in context: ModelContext) -> Int {
        let day = calendar.startOfDay(for: now)
        let target: UUID? = item.identifier
        let descriptor = FetchDescriptor<BriefEntry>(
            predicate: #Predicate { $0.sourceIdentifier == target },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return 0 }

        let changed = reconcile(entries, of: item, on: day, in: context)
        if changed > 0 { save(context) }
        return changed
    }

    /// The same pass across the whole brief, for edits that happened somewhere
    /// this app never saw — another device, or a note edited before Refresh was
    /// pressed.
    ///
    /// Only memories edited *after* a line was made are re-read, so an untouched
    /// note costs nothing and nothing shifts under you unexpectedly.
    private func refreshEditedLines(
        around day: Date,
        memories: [MemoryItem],
        in context: ModelContext
    ) -> Int {
        guard let cutoff = calendar.date(byAdding: .day, value: -BriefBuilder.taskLookBackDays, to: day) else {
            return 0
        }
        let descriptor = FetchDescriptor<BriefEntry>(predicate: #Predicate { $0.day >= cutoff })
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return 0 }

        let byIdentifier = Dictionary(
            memories.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var grouped: [UUID: [BriefEntry]] = [:]
        // Tokenized at most once per note, and only for notes that have lines.
        var sourceTokens: [UUID: Set<String>] = [:]

        for entry in entries {
            guard let identifier = entry.sourceIdentifier,
                  let memory = byIdentifier[identifier]
            else { continue }

            if memory.updatedAt <= entry.createdAt {
                // Timestamps are the fast path, not the truth. An edit merged in
                // from another device, a line made by an older version of the
                // app, a `updatedAt` that never moved — any of those leave a
                // line stale with nothing in the dates to show it. So fall back
                // to the thing that actually matters: are this line's words
                // still in the note?
                if sourceTokens[identifier] == nil {
                    let body = [memory.text, memory.summary]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    sourceTokens[identifier] = Set(Tokenizer.tokens(in: body))
                }
                guard !Self.isStillQuoted(entry, in: sourceTokens[identifier] ?? []) else { continue }
            }

            grouped[identifier, default: []].append(entry)
        }

        var changed = 0
        for (identifier, group) in grouped {
            guard let memory = byIdentifier[identifier] else { continue }
            changed += reconcile(
                group.sorted { $0.sortIndex < $1.sortIndex },
                of: memory,
                on: day,
                in: context
            )
        }

        // Only lines the pass above left alone: a reconciled line already took
        // its wording from the builder, which cleans as it goes, and an entry
        // that pass deleted must not be touched again.
        let reconciled = Set(grouped.keys)
        changed += tidy(entries.filter { entry in
            guard let identifier = entry.sourceIdentifier else { return true }
            return !reconciled.contains(identifier)
        })
        return changed
    }

    /// Presentation-only clean-up of lines that are already in the brief.
    ///
    /// Punctuation debris, never words — see `BriefText`. Worth doing over the
    /// existing brief rather than only over new lines, because the rows that
    /// look unfinished are the ones already on the screen.
    private func tidy(_ entries: [BriefEntry]) -> Int {
        var changed = 0
        for entry in entries {
            var touched = false

            let text = BriefText.clean(entry.text)
            if text != entry.text, !text.isEmpty {
                entry.text = text
                touched = true
            }
            if !entry.headline.isEmpty {
                let headline = BriefText.clean(entry.headline)
                if headline != entry.headline, !headline.isEmpty {
                    entry.headline = headline
                    touched = true
                }
            }

            if touched { changed += 1 }
        }
        return changed
    }

    /// Pairs existing lines with what the note says now.
    ///
    /// Two rules keep this from doing damage:
    ///
    /// - **Never delete on an empty read.** If the note yields no candidate
    ///   lines at all — it fell outside a look-back window, or the text was
    ///   replaced by something the builder doesn't recognize — the existing
    ///   lines are left alone. Losing a task you were relying on is far worse
    ///   than showing it with stale wording.
    /// - **Only delete a line whose own section still produces.** An unmatched
    ///   task is only stale if the note still produces tasks; if it produces
    ///   none, the silence says nothing about that line.
    private func reconcile(
        _ entries: [BriefEntry],
        of item: MemoryItem,
        on day: Date,
        in context: ModelContext
    ) -> Int {
        guard let source = briefSource(for: item) else { return 0 }
        var pool = BriefBuilder.build(for: day, from: [source], calendar: calendar)
        guard !pool.isEmpty else { return 0 }
        let producedKinds = Set(pool.map(\.kind))

        var changed = 0
        for entry in entries {
            guard let index = Self.bestMatch(for: entry, in: pool) else {
                if producedKinds.contains(entry.kind) {
                    context.delete(entry)
                    changed += 1
                }
                continue
            }

            let candidate = pool.remove(at: index)
            let isUnchanged = entry.text == candidate.text
                && entry.headline == candidate.headline
                && entry.detail == candidate.detail
                && entry.kind == candidate.kind
                && entry.scheduledAt == candidate.scheduledAt
            guard !isUnchanged else { continue }

            entry.text = candidate.text
            entry.headline = candidate.headline
            entry.detail = candidate.detail
            entry.kind = candidate.kind
            entry.scheduledAt = candidate.scheduledAt
            changed += 1
        }
        return changed
    }

    /// Whether every word of this line is still somewhere in the note it was
    /// quoted from.
    ///
    /// Compared on normalized tokens rather than on the string, which is what
    /// keeps this stable: tidying punctuation leaves the tokens identical, so a
    /// tidied line doesn't look edited and can't reconcile on a loop — while
    /// 54,000 becoming 60,000 changes a token and shows up immediately.
    nonisolated static func isStillQuoted(_ entry: BriefEntry, in sourceTokens: Set<String>) -> Bool {
        let terms = Set(Tokenizer.tokens(in: entry.text))
        guard !terms.isEmpty else { return true }
        return terms.isSubset(of: sourceTokens)
    }

    /// How alike two lines have to be to count as the same line, reworded.
    ///
    /// Editing a figure changes one word in a sentence; rewriting the sentence
    /// changes most of them. This sits between the two, so a correction updates
    /// the row you already have and a genuinely new thought becomes a new one.
    nonisolated static let minimumRematchSimilarity = 0.45

    nonisolated static func bestMatch(for entry: BriefEntry, in pool: [BriefCandidate]) -> Int? {
        let terms = Set(Tokenizer.tokens(in: entry.text))
        guard !terms.isEmpty else { return nil }

        var best: (index: Int, score: Double)?
        for (index, candidate) in pool.enumerated() {
            let other = Set(Tokenizer.tokens(in: candidate.text))
            guard !other.isEmpty else { continue }

            let overlap = Double(terms.intersection(other).count)
            let union = Double(terms.union(other).count)
            guard union > 0 else { continue }
            // A same-section match wins a tie: a line usually stays the kind of
            // thing it was.
            let score = overlap / union + (candidate.kind == entry.kind ? 0.05 : 0)

            guard score >= minimumRematchSimilarity else { continue }
            if let current = best {
                if score > current.score { best = (index, score) }
            } else {
                best = (index, score)
            }
        }
        return best?.index
    }

    /// Only what you actually said feeds a brief.
    ///
    /// `extractedText` — OCR off a photo, a PDF's text layer — is reference
    /// material, not a commitment. A scanned lab report contains no tasks, and
    /// its printed timestamps are not your calendar; reading them as one produced
    /// a brief full of "2 - 2.54 at 2:00 PM". So a line can only come from text
    /// you typed, dictated or spoke, or from a summary you reviewed and pressed
    /// Save on. To get something out of a document and into your brief, write it
    /// down or summarize the document.
    private func briefSource(for item: MemoryItem) -> BriefSource? {
        let authored = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authored.isEmpty || !summary.isEmpty else { return nil }

        return BriefSource(
            identifier: item.identifier,
            title: item.displayTitle,
            text: authored,
            summary: summary,
            createdAt: item.createdAt,
            kind: item.kind,
            tags: item.tagNames
        )
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
