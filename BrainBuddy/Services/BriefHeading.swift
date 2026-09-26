import Foundation

/// What a row on Today says, and where an edit to it goes.
///
/// A note and its line on Today used to be two separate pieces of text. The
/// note had a heading — *"Doctor Wilson on TV 29th Sep"* — and the row showed a
/// sentence quoted out of it — *"Took video record… they will put on TV"*. Edit
/// one and the other stayed as it was, because nothing connected them.
///
/// Now there is one rule and one place for each piece of text:
///
/// - **A note's main row is its heading.** The first line a note ever put in
///   the brief shows the note's title, live. Edit the heading inside the note
///   and the row changes; edit the row on Today and the heading changes,
///   because both are the same field.
/// - **Any other row is its own line.** A note can contribute up to three
///   rows; the second and third are separate points, and editing one stores
///   your wording on that row alone.
/// - **Your wording always wins.** Nothing automatic writes to it — not a
///   rebuild, not an edit to the note, not tidying.
///
/// One exception keeps this from making things worse. A note whose title is a
/// machine placeholder — *"Voice note · 12 Sep"*, *"Scan"*, a file name — has no
/// heading worth showing, so its main row keeps the quoted sentence until you
/// give it one. Editing that row gives the note its heading.
enum BriefHeading {
    /// One brief line, as much of it as deciding the heading needs.
    struct Line {
        let id: UUID
        let source: UUID?
        let day: Date
        let sortIndex: Int
    }

    /// The main row of each note: the first line it ever put in the brief.
    ///
    /// Chosen across open *and* closed lines, so the choice is stable. If only
    /// open lines counted, ticking off the main row would hand the heading to
    /// the next row down, and the thing you just finished would reappear with
    /// a different circle next to it.
    static func mainLines(among lines: [Line]) -> Set<UUID> {
        var first: [UUID: Line] = [:]
        for line in lines {
            guard let source = line.source else { continue }
            guard let current = first[source] else {
                first[source] = line
                continue
            }
            let isEarlier = line.day == current.day
                ? line.sortIndex < current.sortIndex
                : line.day < current.day
            if isEarlier { first[source] = line }
        }
        return Set(first.values.map(\.id))
    }

    /// What one row says.
    static func text(
        userText: String,
        subject: String,
        isMainLine: Bool,
        noteTitle: String?,
        titleIsPlaceholder: Bool
    ) -> String {
        let own = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }

        if isMainLine, !titleIsPlaceholder,
           let title = noteTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return subject
    }

    /// Whether editing this row should change the note's heading rather than
    /// the row alone.
    ///
    /// The main row *is* the heading, so yes — unless you already gave the row
    /// its own wording earlier, when it was not yet the main row. Then it is
    /// that wording you are correcting.
    static func editsNoteTitle(isMainLine: Bool, userText: String) -> Bool {
        isMainLine && userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Placeholder titles

    /// Whether a title is something the app filled in because there was nothing
    /// better, rather than a heading.
    static func isPlaceholder(title: String, source: String, kindLabels: [String]) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lowered = trimmed.lowercased()
        if lowered == "untitled" { return true }
        if lowered.hasPrefix("voice note ·") || lowered.hasPrefix("voice note -") { return true }

        let sourceLowered = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !sourceLowered.isEmpty, lowered == sourceLowered { return true }
        if kindLabels.contains(where: { $0.lowercased() == lowered }) { return true }

        // "IMG_2041.jpg", "report-final.pdf": one token with a file extension.
        return trimmed.range(of: #"^\S+\.[A-Za-z0-9]{2,4}$"#, options: .regularExpression) != nil
    }
}

extension MemoryItem {
    /// See `BriefHeading.isPlaceholder`.
    var titleIsPlaceholder: Bool {
        BriefHeading.isPlaceholder(
            title: title,
            source: source,
            kindLabels: [kind.title, kind.sourceLabel]
        )
    }
}

extension BriefEntry {
    var headingLine: BriefHeading.Line {
        BriefHeading.Line(id: identifier, source: sourceIdentifier, day: day, sortIndex: sortIndex)
    }
}
