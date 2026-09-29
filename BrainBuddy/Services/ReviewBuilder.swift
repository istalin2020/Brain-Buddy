import Foundation

/// One capture, as the review needs it.
struct ReviewMemory: Identifiable, Sendable {
    let id: UUID
    let title: String
    let text: String
    let kind: MemoryKind
    let tags: [String]
    let createdAt: Date
}

/// One brief line, as the review needs it.
struct ReviewTask: Sendable {
    let subject: String
    let day: Date
    let isClosed: Bool
    let closedAt: Date?
}

/// A period of your brain, summarized.
struct Review: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let text: String
        /// A short qualifier shown to the right — "open 6 days", "Tue", "3×".
        let note: String
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let systemImage: String
        /// Why this group is worth reading. One line, no cheerleading.
        let caption: String
        let items: [Item]
    }

    let title: String
    let capturedCount: Int
    let closedCount: Int
    let openCount: Int
    /// One line of counts by kind: "4 notes · 2 voice notes".
    let mix: String
    let groups: [Group]

    var isEmpty: Bool { capturedCount == 0 && closedCount == 0 && openCount == 0 }
}

/// Builds the weekly review.
///
/// Everything else in this app answers a question you asked. This is the one
/// thing it says on its own — so it has to earn the interruption. Which means:
/// no vanity metrics, no streaks, no "you're doing great". Four things you can
/// act on, in the order you'd want them:
///
/// 1. **What you finished** — because closing things is invisible otherwise.
/// 2. **What's still open**, oldest first, with how long it has been sitting
///    there. Age is the useful number: a task open for nine days is a decision
///    you have been avoiding, and saying so is more helpful than listing it.
/// 3. **What you kept coming back to** — the subjects that recur across the
///    week's captures, which is usually not what you would have guessed.
/// 4. **Questions you wrote down and haven't answered.** People note questions
///    constantly and never revisit them; a second brain that can't hand them
///    back is losing the most valuable thing it holds.
///
/// Pure and calendar-injectable, so what shows up in a review is pinned by tests
/// rather than dependent on the day the suite runs.
enum ReviewBuilder {
    static let defaultDays = 7
    static let maximumItemsPerGroup = 6
    /// A subject needs to recur this many times in the period to be worth
    /// naming. Once is just a thing that happened.
    static let minimumSubjectCount = 2

    static func build(
        memories: [ReviewMemory],
        tasks: [ReviewTask],
        now: Date = Date(),
        days: Int = defaultDays,
        calendar: Calendar = .current
    ) -> Review {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today

        let captured = memories
            .filter { $0.createdAt >= start }
            .sorted { $0.createdAt > $1.createdAt }

        let closed = tasks
            .filter { task in
                guard task.isClosed, let closedAt = task.closedAt else { return false }
                return closedAt >= start
            }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }

        let open = tasks
            .filter { !$0.isClosed }
            .sorted { $0.day < $1.day }

        var groups: [Review.Group] = []

        if !closed.isEmpty {
            groups.append(
                Review.Group(
                    id: "closed",
                    title: "Done",
                    systemImage: "checkmark.circle",
                    caption: closed.count == 1 ? "One thing closed." : "\(closed.count) things closed.",
                    items: closed.prefix(maximumItemsPerGroup).enumerated().map { index, task in
                        Review.Item(
                            id: "closed-\(index)",
                            text: task.subject,
                            note: task.closedAt.map { weekday(of: $0, calendar: calendar) } ?? ""
                        )
                    }
                )
            )
        }

        if !open.isEmpty {
            groups.append(
                Review.Group(
                    id: "open",
                    title: "Still open",
                    systemImage: "circle.dotted",
                    caption: "Oldest first. The age is the point.",
                    items: open.prefix(maximumItemsPerGroup).enumerated().map { index, task in
                        Review.Item(
                            id: "open-\(index)",
                            text: task.subject,
                            note: ageLabel(from: task.day, to: today, calendar: calendar)
                        )
                    }
                )
            )
        }

        let subjects = recurringSubjects(in: captured)
        if !subjects.isEmpty {
            groups.append(
                Review.Group(
                    id: "subjects",
                    title: "What you kept coming back to",
                    systemImage: "arrow.triangle.2.circlepath",
                    caption: "Subjects that turned up in more than one capture.",
                    items: subjects.prefix(maximumItemsPerGroup).enumerated().map { index, subject in
                        Review.Item(
                            id: "subject-\(index)",
                            text: subject.name,
                            note: "\(subject.count)×"
                        )
                    }
                )
            )
        }

        let questions = openQuestions(in: captured)
        if !questions.isEmpty {
            groups.append(
                Review.Group(
                    id: "questions",
                    title: "Questions you left hanging",
                    systemImage: "questionmark.circle",
                    caption: "You wrote these down and moved on.",
                    items: questions.prefix(maximumItemsPerGroup).enumerated().map { index, question in
                        Review.Item(id: "question-\(index)", text: question, note: "")
                    }
                )
            )
        }

        return Review(
            title: periodTitle(from: start, to: today, calendar: calendar),
            capturedCount: captured.count,
            closedCount: closed.count,
            openCount: open.count,
            mix: mixLine(for: captured),
            groups: groups
        )
    }

    // MARK: - Shareable text

    /// Plain text rather than an image or a PDF, because the useful thing to do
    /// with a review is paste it into the message you were about to write.
    static func shareText(for review: Review) -> String {
        var lines = ["Brain Buddy · \(review.title)"]
        lines.append("")
        lines.append(headline(for: review))
        if !review.mix.isEmpty { lines.append(review.mix) }

        for group in review.groups {
            lines.append("")
            lines.append(group.title.uppercased())
            for item in group.items {
                lines.append(item.note.isEmpty ? "• \(item.text)" : "• \(item.text) — \(item.note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func headline(for review: Review) -> String {
        if review.isEmpty { return "Nothing captured, nothing closed. A quiet week." }
        var parts: [String] = []
        parts.append(review.capturedCount == 1 ? "1 capture" : "\(review.capturedCount) captures")
        if review.closedCount > 0 { parts.append("\(review.closedCount) closed") }
        if review.openCount > 0 { parts.append("\(review.openCount) still open") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Signals

    struct Subject: Equatable {
        let name: String
        let count: Int
    }

    /// Reuses the brain-box grouping, so "what you kept coming back to" and the
    /// boxes in the Brain tab can never disagree about what your subjects are.
    static func recurringSubjects(in memories: [ReviewMemory]) -> [Subject] {
        guard memories.count > 1 else { return [] }
        let index = BrainBoxBuilder.build(
            from: memories.map {
                BrainBoxItem(
                    id: $0.id,
                    kind: $0.kind,
                    tags: $0.tags,
                    text: [$0.title, $0.text].filter { !$0.isEmpty }.joined(separator: "\n")
                )
            }
        )

        return index.boxes.compactMap { box in
            switch box.filter {
            case .topic, .tag:
                guard box.count >= minimumSubjectCount else { return nil }
                return Subject(name: box.title, count: box.count)
            case .everything, .kind:
                return nil
            }
        }
    }

    /// Below this a "question" is a fragment — "Why?", "When?" — which is not
    /// something you can hand back to somebody as a loose end.
    static let minimumQuestionLength = 12

    /// Sentences that end in a question mark. Deliberately literal: a derived
    /// "this looks like a question" would be wrong often enough to be annoying,
    /// and a typed question mark is the writer saying so outright.
    ///
    /// Reads sentence *ranges* rather than `Tokenizer.sentences`, which drops
    /// terminators by design — and the terminator is the entire signal here.
    static func openQuestions(in memories: [ReviewMemory]) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        for memory in memories {
            let text = memory.text
            for range in Tokenizer.sentenceRanges(in: text) {
                let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.hasSuffix("?"), sentence.count > minimumQuestionLength else { continue }
                let key = Tokenizer.tokens(in: sentence).joined(separator: " ")
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                found.append(sentence)
            }
        }
        return found
    }

    // MARK: - Phrasing

    static func mixLine(for memories: [ReviewMemory]) -> String {
        guard !memories.isEmpty else { return "" }
        let counts = memories.reduce(into: [MemoryKind: Int]()) { counts, memory in
            counts[memory.kind, default: 0] += 1
        }
        return MemoryKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            let noun = count == 1 ? kind.singularNoun : kind.boxTitle.lowercased()
            return "\(count) \(noun)"
        }
        .joined(separator: " · ")
    }

    static func periodTitle(from start: Date, to end: Date, calendar: Calendar) -> String {
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let startText = sameMonth
            ? start.formatted(.dateTime.day())
            : start.formatted(.dateTime.day().month(.abbreviated))
        let endText = end.formatted(.dateTime.day().month(.abbreviated))
        return "\(startText) – \(endText)"
    }

    static func ageLabel(from day: Date, to today: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "open 1 day"
        default: return "open \(days) days"
        }
    }

    static func weekday(of date: Date, calendar: Calendar) -> String {
        calendar.isDateInToday(date) ? "today" : date.formatted(.dateTime.weekday(.abbreviated))
    }
}

extension MemoryKind {
    /// "1 note", not "1 notes".
    var singularNoun: String {
        switch self {
        case .note: return "note"
        case .voice: return "voice note"
        case .image: return "photo"
        case .document: return "document"
        case .link: return "link"
        }
    }
}
