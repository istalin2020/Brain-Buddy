import Foundation
import SwiftUI

/// Which card a brief line belongs on.
///
/// Today used to be one flat list with a quoted paragraph under every row,
/// which reads as a wall — you can't see the shape of your day in it. These are
/// the cards instead, and they answer the four questions a person actually has
/// standing up in the morning: *what has a time on it*, *what does the office
/// need*, *what does my own life need*, and *what do I just need to remember*.
enum BriefGroupKind: String, CaseIterable, Identifiable, Sendable {
    /// Anything with a day or a time on it, or that says "remind".
    case reminders
    /// Work you said you'd do.
    case office
    /// Everything else you said you'd do.
    case personal
    /// Worth having in mind; nothing to do.
    case info
    /// Closed today.
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: return "Reminders"
        case .office: return "Office to-do"
        case .personal: return "Personal to-do"
        case .info: return "Important info"
        case .done: return "Done today"
        }
    }

    var systemImage: String {
        switch self {
        case .reminders: return "bell.fill"
        case .office: return "briefcase.fill"
        case .personal: return "person.fill"
        case .info: return "info.circle.fill"
        case .done: return "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .reminders: return .orange
        case .office: return .blue
        case .personal: return .green
        case .info: return .purple
        case .done: return .gray
        }
    }

    /// One line under the card, explaining why these are together. Shown only
    /// when the card is open, so the closed state stays clean.
    var caption: String {
        switch self {
        case .reminders: return "Anything with a day or a time on it, soonest first."
        case .office: return "Work you said you'd do — from your work notes, or lines that talk like work."
        case .personal: return "Everything else you said you'd do."
        case .info: return "Nothing to do — just worth remembering."
        case .done: return "Tap one to reopen it if you ticked it off too early."
        }
    }

    /// The order the cards appear in, which is also the order they claim lines.
    static let display: [BriefGroupKind] = [.reminders, .office, .personal, .info, .done]
}

/// When a reminder falls due, as the chip on its row.
struct BriefDue: Equatable {
    let date: Date
    let label: String
    /// Already gone by: the chip turns red rather than quietly showing a date
    /// that was last week.
    let isPast: Bool
}

/// Sorts brief lines onto the cards.
///
/// Pure, and every input is a plain value, so "what ends up where" is pinned by
/// tests rather than by tapping through the app. The one rule that matters most:
/// **a line lands on exactly one card.** The complaint that started this was the
/// same thing appearing in several places, and the fix is not to be clever about
/// it — it is to decide once, in order, here.
///
/// The order is the order of certainty. A line that names a day is a reminder
/// whatever else it says. Failing that, a line is either something to *do* or
/// something to *know*, and only a to-do is then split by whose work it is —
/// so a piece of information never has to guess whether it is office or
/// personal, because it doesn't need to be either.
enum BriefGrouping {
    /// Rows shown before a card offers "+N more". Five is about what can be read
    /// without scrolling past the card below it.
    static let collapsedRowLimit = 5

    static func group(
        kind: BriefEntryKind,
        day: Date,
        isClosed: Bool,
        closedAt: Date?,
        text: String,
        sourceRegion: BrainRegion? = nil,
        today: Date,
        calendar: Calendar = .current
    ) -> BriefGroupKind? {
        if isClosed {
            // Closed on an earlier day is history, not today's screen.
            guard let closedAt, calendar.isDate(closedAt, inSameDayAs: today) else { return nil }
            return .done
        }

        // A dated line was already found to be happening today.
        if kind == .schedule { return .reminders }
        // Checked before anything else looks at the date, because a record of
        // what happened is full of dates and none of them are appointments.
        if isARecord(text) { return nil }
        if isReminder(text) { return .reminders }
        guard isToDo(text) else { return .info }
        return isOffice(text, sourceRegion: sourceRegion) ? .office : .personal
    }

    // MARK: - Records

    /// Whether the line is a record of something that already happened.
    ///
    /// *"Came to Harweel site visit on 16th September 2026"* is a diary entry.
    /// It is worth keeping, and it is kept — the note is in your brain, the
    /// Brain tab files it, and Ask will find it. It is simply not something to
    /// do, not something to be reminded about, and not news you need this
    /// morning. **Today is for what is still ahead of you.**
    ///
    /// Two things stop this swallowing more than it should. It reads only the
    /// *opening* verb, so a past tense further in keeps its place: *"Al Qersh
    /// confirmed to do the sparing work with 60,000 Omani rial"* reports what
    /// somebody committed to, and that belongs under Important info. And a
    /// commitment or obligation anywhere in the line overrides it, because
    /// *"Took the video record, they will put it on TV"* is still waiting on
    /// somebody.
    static func isARecord(_ text: String) -> Bool {
        guard DiscussionSummarizer.opensInThePastTense(text) else { return false }
        return !DiscussionSummarizer.isActionable(text)
    }

    // MARK: - Reminders

    /// Whether a line is about *when* — it names a day or a time, or says
    /// remind, due, deadline, renew, expire, appointment.
    ///
    /// A date on its own is not enough: *"The material has been at the yard
    /// since March"* names a month and is a piece of history. So a day only
    /// makes a reminder when the line isn't reporting something that already
    /// happened.
    static func isReminder(_ text: String) -> Bool {
        if !BrainClassifier.terms(in: text).intersection(reminderTerms).isEmpty { return true }
        guard namesAWhen(text) else { return false }
        return !reportsAFact(text)
    }

    /// Words that make a line a reminder outright.
    static let reminderTerms: Set<String> = Set(
        [
            "remind", "reminder", "reminders", "due", "deadline", "expire",
            "expires", "expiry", "renew", "renewal", "appointment", "alarm"
        ]
        .compactMap(Tokenizer.normalize)
        .map(BrainClassifier.fold)
    )

    /// A day, a date, a clock time, or "next week".
    static func namesAWhen(_ text: String) -> Bool {
        if BrainClassifier.mentionsADay(text) { return true }
        return whenPatterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static let whenPatterns: [String] = [
        // 4:30, 4 pm, 11:30am
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#,
        // 20th, 3rd
        #"\b\d{1,2}(st|nd|rd|th)\b"#,
        #"\b(next|this)\s+(week|month|year|weekend)\b"#
    ]

    // MARK: - To do, or to know

    /// Whether a line describes something still to happen.
    ///
    /// In order: an instruction, a commitment or an obligation is a to-do
    /// whatever else the line says — *"Send the drawings"*, *"I have to close
    /// the approval"*, *"Method statement to be reviewed"*. A line that reports
    /// something that happened, or states how things are, is information —
    /// *"Al Qersh confirmed to do the sparing work with 60,000 Omani rial"*
    /// contains a verb you could read as an order and is plainly a fact. What's
    /// left is the bare label — *"EOT submission"*, *"Haffaf Muscat drawing
    /// status"* — which is what a quick capture of something to deal with looks
    /// like, and is a to-do.
    static func isToDo(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasSuffix("?") else { return false }

        if opensWithAnOrder(line) || DiscussionSummarizer.isActionable(line) { return true }
        if reportsAFact(line) || statesSomething(line) { return false }

        let words = line.split(whereSeparator: { $0.isWhitespace })
        return words.count <= bareLabelWords && line.rangeOfCharacter(from: .decimalDigits) == nil
    }

    /// Whether the line starts with an order.
    ///
    /// The part-of-speech tagger decides in general, but it has to guess for
    /// words that are both a verb and a noun — *book*, *order*, *plan* — and
    /// at the front of a note to yourself those are verbs. A short list of the
    /// verbs people actually start to-dos with settles them without a guess.
    static func opensWithAnOrder(_ text: String) -> Bool {
        let first = text
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { $0.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased() } ?? ""
        if imperativeOpeners.contains(first) { return true }
        return DiscussionSummarizer.opensWithAnInstruction(text)
    }

    /// Only words that are an order far more often than they are a thing:
    /// *order*, *issue*, *update* and *plan* open as many statements as
    /// instructions and are left to the tagger.
    private static let imperativeOpeners: Set<String> = [
        "arrange", "ask", "book", "bring", "buy", "call", "cancel", "chase",
        "check", "clean", "close", "collect", "complete", "confirm", "contact",
        "discuss", "draft", "email", "finish", "fix", "follow", "get", "inform",
        "make", "meet", "organise", "organize", "pay", "pick", "prepare",
        "print", "read", "renew", "reply", "review", "schedule", "send",
        "share", "sign", "study", "submit", "take", "upload", "visit", "write"
    ]

    /// A label this short with no verb in it is a thing to deal with, not a
    /// thing to know. Past this length it's a sentence, and a sentence with no
    /// instruction in it is telling you something.
    static let bareLabelWords = 5

    /// Whether the line reports something that already happened.
    ///
    /// Past tense, matched on the raw words rather than on search tokens —
    /// *was*, *were* and *been* are stopwords, and here they are the whole
    /// point. An instruction is never a fact, whatever tense follows it:
    /// *"Confirm the booking"* opens with an order.
    static func reportsAFact(_ text: String) -> Bool {
        if opensWithAnOrder(text) { return false }
        // Opening in the past tense settles it on its own; the word list below
        // only ever catches what a sentence happens to contain.
        if DiscussionSummarizer.opensInThePastTense(text) { return true }
        return !rawWords(in: text).isDisjoint(with: factWords)
    }

    /// Whether the line states how something is, rather than what to do.
    static func statesSomething(_ text: String) -> Bool {
        if opensWithAnOrder(text) { return false }
        return !rawWords(in: text).isDisjoint(with: stateWords)
    }

    private static let factWords: Set<String> = [
        "was", "were", "been", "did", "confirmed", "completed", "processed",
        "received", "submitted", "successfully", "took", "paid", "arrived",
        "agreed", "approved", "rejected", "said", "told", "informed",
        "mentioned", "happened", "finished", "delivered", "issued", "sent",
        "since", "already"
    ]

    private static let stateWords: Set<String> = [
        "is", "are", "costs", "cost", "means", "includes", "contains", "am"
    ]

    private static func rawWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - Whose work

    /// Whether a to-do is the office's.
    ///
    /// The line decides when it can: work vocabulary against family and friends
    /// vocabulary, whichever there is more of. When the line says nothing
    /// either way — *"Send it to Pandi"* — the document it was quoted from
    /// settles it, which is how a line out of a work email stays with the
    /// office even when the sentence itself is neutral.
    static func isOffice(_ text: String, sourceRegion: BrainRegion?) -> Bool {
        let words = BrainClassifier.terms(in: text)
        let office = words.intersection(BrainClassifier.workTerms).count
        let home = words.intersection(BrainClassifier.familyTerms).count
            + words.intersection(BrainClassifier.friendTerms).count
        if office != home { return office > home }
        return sourceRegion == .work
    }

    // MARK: - When

    /// The day or time a reminder names, for the chip on its row and for
    /// putting the soonest first.
    ///
    /// Only matches that name a day or a clock time count. `NSDataDetector`
    /// will also read a numeric range as a time, and a chip saying *2:00 PM*
    /// under a lab result is worse than no chip.
    static func dueDate(in text: String, today: Date, calendar: Calendar = .current) -> Date? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var best: Date?
        for match in detector.matches(in: text, options: [], range: range) {
            guard let date = match.date, let matched = Range(match.range, in: text) else { continue }
            let phrase = String(text[matched])
            guard BriefBuilder.namesADay(phrase) || namesAClockTime(phrase) else { continue }
            if best == nil || date < (best ?? date) { best = date }
        }
        return best
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )

    private static func namesAClockTime(_ phrase: String) -> Bool {
        phrase.range(of: whenPatterns[0], options: .regularExpression) != nil
            || phrase.range(of: whenPatterns[1], options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The chip: the time if it's today, the day if it's this week, the date
    /// otherwise — the shortest thing that still tells you when.
    static func due(for date: Date, today: Date, calendar: Calendar = .current) -> BriefDue {
        let isTimed = calendar.component(.hour, from: date) != 0
            || calendar.component(.minute, from: date) != 0
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: today),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        let label: String
        if days == 0 {
            label = isTimed ? date.formatted(date: .omitted, time: .shortened) : "Today"
        } else if days == 1 {
            label = "Tomorrow"
        } else if days > 1, days < 7 {
            label = date.formatted(.dateTime.weekday(.abbreviated))
        } else {
            label = date.formatted(.dateTime.day().month(.abbreviated))
        }
        return BriefDue(date: date, label: label, isPast: days < 0)
    }

    // MARK: - Age

    static func age(of day: Date, on today: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: today)
        ).day ?? 0
    }

    /// A short right-hand chip: the time it happens, or how long it has waited.
    /// Both answer "how urgent is this" in three characters.
    static func badge(
        scheduledAt: Date?,
        day: Date,
        today: Date,
        calendar: Calendar = .current
    ) -> String? {
        if let scheduledAt {
            return scheduledAt.formatted(date: .omitted, time: .shortened)
        }
        let days = age(of: day, on: today, calendar: calendar)
        guard days >= 1 else { return nil }
        return "\(days)d"
    }
}
