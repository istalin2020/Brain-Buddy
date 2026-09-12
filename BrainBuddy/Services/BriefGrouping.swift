import SwiftUI

/// Which card a brief line belongs on.
///
/// Today used to be one flat list with a quoted paragraph under every row,
/// which reads as a wall — you can't see the shape of your day in it. These are
/// the cards instead: a small number of named groups, each one answering a
/// different question, so the screen can be understood at arm's length.
enum BriefGroupKind: String, CaseIterable, Identifiable, Sendable {
    /// What's on today, and what has been waiting too long.
    case priorities
    /// The rest of what's owed.
    case todo
    /// Things that are really "get in touch with somebody".
    case contact
    /// Worth having in mind; nothing to do.
    case points
    /// Closed today.
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priorities: return "Top priorities"
        case .todo: return "To-do"
        case .contact: return "Calls & emails"
        case .points: return "Worth knowing"
        case .done: return "Done today"
        }
    }

    var systemImage: String {
        switch self {
        case .priorities: return "star.fill"
        case .todo: return "checklist"
        case .contact: return "phone.fill"
        case .points: return "lightbulb.fill"
        case .done: return "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .priorities: return .orange
        case .todo: return .blue
        case .contact: return .green
        case .points: return .purple
        case .done: return .gray
        }
    }

    /// One line under the card, explaining why these are together. Shown only
    /// when the card is open, so the closed state stays clean.
    var caption: String {
        switch self {
        case .priorities: return "Happening today, and whatever has been waiting longest."
        case .todo: return "Everything else you said you'd do."
        case .contact: return "Somebody is waiting to hear from you."
        case .points: return "Nothing to do — just worth having in mind."
        case .done: return "Tap one to reopen it if you ticked it off too early."
        }
    }

    /// The order the cards appear in, which is not the order they claim lines:
    /// calls take a line off the to-do card, but sit below it.
    static let display: [BriefGroupKind] = [.priorities, .todo, .contact, .points, .done]
}

/// Sorts brief lines onto the cards.
///
/// Pure, and every input is a plain value, so "what ends up where" is pinned by
/// tests rather than by tapping through the app. The one rule that matters most:
/// **a line lands on exactly one card.** The complaint that started this was the
/// same thing appearing in several places, and the fix is not to be clever about
/// it — it is to decide once, in order, here.
enum BriefGrouping {
    /// How long something can sit open before it stops being a to-do and starts
    /// being the thing you're avoiding.
    ///
    /// Three days is the point where "I'll get to it" has been said twice. Past
    /// that, listing it politely among thirty others is not helping.
    static let agingDays = 3

    /// Rows shown before a card offers "+N more". Five is about what can be read
    /// without scrolling past the card below it.
    static let collapsedRowLimit = 5

    static func group(
        kind: BriefEntryKind,
        day: Date,
        isClosed: Bool,
        closedAt: Date?,
        text: String,
        today: Date,
        calendar: Calendar = .current
    ) -> BriefGroupKind? {
        if isClosed {
            // Closed on an earlier day is history, not today's screen.
            guard let closedAt, calendar.isDate(closedAt, inSameDayAs: today) else { return nil }
            return .done
        }

        if kind == .point { return .points }

        if kind == .schedule, calendar.isDate(day, inSameDayAs: today) { return .priorities }

        if age(of: day, on: today, calendar: calendar) >= agingDays { return .priorities }
        if kind == .task, isContact(text) { return .contact }
        return .todo
    }

    static func age(of day: Date, on today: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: today)
        ).day ?? 0
    }

    /// Whether this line is really "get in touch with somebody".
    ///
    /// Needs an explicit word for the medium — *email*, *call*, *reply*. Plain
    /// "send" isn't enough: *"Galvanisation previous reading, send it to Pandi"*
    /// is a job with a hand-off at the end, while *"Send email to Subhankar"* is
    /// the whole task.
    static func isContact(_ text: String) -> Bool {
        !BrainClassifier.terms(in: text).intersection(contactTerms).isEmpty
    }

    private static let contactTerms: Set<String> = Set(
        [
            "email", "emails", "mail", "call", "calls", "phone", "reply",
            "respond", "response", "message", "whatsapp", "dial", "ring",
            "inform", "contact", "follow"
        ]
        .compactMap(Tokenizer.normalize)
        .map(BrainClassifier.fold)
    )

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
