import Foundation

/// Decides which part of the brain a memory belongs in.
///
/// Three passes, in the order that respects what the user actually told us:
///
/// 1. **A tag you typed.** `#work` is you saying it outright; nothing should
///    argue with that.
/// 2. **What the thing is.** A photo goes to the visual cortex and a recording
///    to the auditory one, whatever the words in it happen to be about. This is
///    the rule people expect from the shape of the model, and breaking it — a
///    photo of a site plan filed under Work — makes the whole map feel arbitrary.
/// 3. **What it says.** A small lexicon per region, matched on normalized tokens
///    so "meetings" and "meeting" are the same word. The region with the most
///    hits wins; nothing wins nothing, and unclassified things go to General
///    rather than being forced somewhere.
///
/// No model, no network, no learning: the rules are readable, and when something
/// lands in the wrong room you can see why and add a tag.
enum BrainClassifier {
    // MARK: - Entry point

    static func map(_ inputs: [BrainFileInput]) -> BrainMap {
        var map = BrainMap()
        for input in inputs {
            let region = region(for: input)
            let file = BrainFile(
                id: input.id,
                title: input.title,
                summary: input.summary,
                createdAt: input.createdAt,
                kind: input.kind,
                region: region,
                section: region == .work ? section(for: input) : nil
            )
            map.files[region, default: []].append(file)
        }
        for region in map.files.keys {
            map.files[region]?.sort { $0.createdAt > $1.createdAt }
        }
        return map
    }

    // MARK: - Region

    static func region(for input: BrainFileInput) -> BrainRegion {
        for tag in input.tags {
            if let tagged = region(forTag: tag) { return tagged }
        }

        if input.kind == .image { return .images }
        if input.kind == .voice || hasVideo(input) { return .media }

        // Named `words` rather than `terms`: `let terms = terms(...)` would be a
        // local shadowing the function it is calling.
        let words = terms(in: searchableText(of: input))
        guard !words.isEmpty else { return .general }

        // How much evidence a long document has to show.
        //
        // In six words, one match is the subject. In six hundred, one match is a
        // coincidence — and it was: two scans of the same bank message landed in
        // two different regions because one of them happened to contain a word
        // from the family lexicon exactly once. Near-identical documents filed
        // differently is the thing that makes the whole map untrustworthy, so a
        // long text has to say it twice.
        let required = words.count > longTextTokens ? 2 : 1

        // Ordered, so an equal number of hits resolves the same way every time
        // rather than by dictionary order.
        var best: (region: BrainRegion, hits: Int)?
        for region in lexicalRegions {
            let hits = words.intersection(lexicon(for: region)).count
            guard hits >= required else { continue }
            if best == nil || hits > (best?.hits ?? 0) { best = (region, hits) }
        }
        return best?.region ?? .general
    }

    /// Distinct words past which a memory counts as a document rather than a
    /// note, and needs more than one match to claim a region.
    static let longTextTokens = 60

    /// Regions that can be reached by what a memory *says*, in tie-break order.
    static let lexicalRegions: [BrainRegion] = [.work, .family, .friends]

    static func region(forTag tag: String) -> BrainRegion? {
        switch MemoryTag.normalize(tag) {
        case "work", "office", "job", "project", "client": return .work
        case "family", "home", "kids": return .family
        case "friends", "friend", "relatives", "social": return .friends
        case "photo", "photos", "image", "images": return .images
        case "video", "voice", "recording": return .media
        default: return nil
        }
    }

    // MARK: - Work's rooms

    static func section(for input: BrainFileInput) -> WorkSection {
        if isEmail(input) { return .email }
        if isReminder(input) { return .reminders }
        return .notes
    }

    static func isEmail(_ input: BrainFileInput) -> Bool {
        if input.tags.contains(where: { ["email", "mail", "inbox"].contains(MemoryTag.normalize($0)) }) {
            return true
        }

        let heading = input.title.lowercased()
        if heading.hasPrefix("re:") || heading.hasPrefix("fwd:") || heading.hasPrefix("fw:") {
            return true
        }

        let body = searchableText(of: input)
        if body.range(of: emailAddressPattern, options: .regularExpression) != nil { return true }

        return !terms(in: body).intersection(emailTerms).isEmpty
    }

    static func isReminder(_ input: BrainFileInput) -> Bool {
        if input.tags.contains(where: { BriefBuilder.taskTags.contains(MemoryTag.normalize($0)) }) {
            return true
        }

        let body = searchableText(of: input)
        if !terms(in: body).intersection(reminderTerms).isEmpty { return true }
        return mentionsADay(body)
    }

    /// A day named in the text — "Tuesday", "29/07/2026", "tomorrow".
    ///
    /// Shares `BriefBuilder`'s day words rather than keeping a second list that
    /// would drift out of step with the brief's idea of what a date looks like.
    static func mentionsADay(_ text: String) -> Bool {
        let words = Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        if !words.isDisjoint(with: BriefBuilder.dayWords) { return true }
        return text.range(
            of: #"\d{1,4}[./-]\d{1,2}[./-]\d{2,4}"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Lexicons

    /// The words of a memory, folded the same way the lexicons are.
    static func terms(in text: String) -> Set<String> {
        Set(Tokenizer.tokens(in: text).map(fold))
    }

    /// Stems until the word stops changing.
    ///
    /// One pass is not enough here, because the search stemmer is deliberately
    /// conservative and applies **one** rule: `"meetings"` loses its `s` and
    /// stops at `"meeting"`, while the lexicon entry `"meeting"` loses its `ing`
    /// and becomes `"meet"`. Compared against each other those never match — a
    /// silent miss that would have made half of every lexicon dead weight. A
    /// fixpoint makes both sides land on the same word.
    static func fold(_ word: String) -> String {
        var current = word
        // Three is past the fixpoint for every rule in the stemmer; the loop is
        // bounded rather than `while` so a future rule can't hang this.
        for _ in 0..<3 {
            let next = Tokenizer.stem(current)
            if next == current { return current }
            current = next
        }
        return current
    }

    /// Built through the same normalization *and* folding as the text, so both
    /// sides of every comparison are the same shape.
    private static func normalized(_ words: [String]) -> Set<String> {
        Set(words.compactMap(Tokenizer.normalize).map(fold))
    }

    static func lexicon(for region: BrainRegion) -> Set<String> {
        switch region {
        case .work: return workTerms
        case .family: return familyTerms
        case .friends: return friendTerms
        default: return []
        }
    }

    static let workTerms = normalized([
        "meeting", "meetings", "project", "client", "invoice", "deadline",
        "report", "contract", "office", "manager", "boss", "team", "colleague",
        "submission", "drawing", "drawings", "approval", "tender", "budget",
        "presentation", "ppt", "proposal", "quotation", "contractor",
        "engineer", "site", "shift", "handover", "hackathon", "schedule",
        "agenda", "minutes", "invoicing", "payment", "purchase", "vendor",
        "supplier", "shutdown", "commissioning", "inspection", "workshop",
        "interview", "salary", "appraisal", "training", "audit", "compliance"
    ])

    static let familyTerms = normalized([
        "family", "wife", "husband", "spouse", "son", "daughter", "kids",
        "child", "children", "mother", "father", "mom", "mum", "dad", "parents",
        "grandma", "grandpa", "grandmother", "grandfather", "anniversary",
        "school", "homework", "groceries", "rent", "mortgage", "household",
        "doctor", "dentist", "pediatrician", "vacation", "holiday"
    ])

    static let friendTerms = normalized([
        "friend", "friends", "buddy", "mate", "cousin", "uncle", "aunt",
        "nephew", "niece", "relative", "relatives", "neighbour", "neighbor",
        "wedding", "party", "reunion", "dinner", "lunch", "birthday",
        "catchup", "gathering", "guest", "visit"
    ])

    static let emailTerms = normalized([
        "email", "emails", "mail", "inbox", "unsubscribe", "sender",
        "attachment", "cc", "bcc", "subject"
    ])

    static let reminderTerms = normalized([
        "remind", "reminder", "due", "deadline", "submit", "follow", "chase",
        "renew", "expire", "expiry", "book", "booking", "appointment",
        "deliver", "pending", "urgent", "asap", "today", "tomorrow"
    ])

    private static let emailAddressPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    private static func hasVideo(_ input: BrainFileInput) -> Bool {
        input.attachmentNames.contains { name in
            videoExtensions.contains((name as NSString).pathExtension.lowercased())
        }
    }

    private static func searchableText(of input: BrainFileInput) -> String {
        [input.title, input.text, input.source, input.tags.joined(separator: " ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
