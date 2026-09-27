import Foundation

/// Answers a question with the thing it asked for, not with everything that
/// mentions it.
///
/// "What is my name?" used to come back as five passages: the note that says
/// "My name is Joseph Stalin", a note about an API returning "the food name",
/// a bank slip, and two lab reports whose only relevant line was the word
/// *Name*. Every one of them contained the word, and the search was right to
/// find them. What was missing is the second half of every question-answering
/// system since DrQA: search finds the documents, then a **reader** finds the
/// answer *inside* them.
///
/// This is that reader, on-device and without a model:
///
/// 1. **Understand the question.** A factoid question names a slot — *my
///    name*, *my blood group*, *the rent*, *my TSH value* — and the slot says
///    what shape the answer has: a person's name, a phone number, a date, an
///    amount, a number, or free text.
/// 2. **Read for the answer.** Every sentence of the candidate documents is
///    matched against the ways people write a fact down: *"My name is …"*,
///    *"I'm …"*, *"Name: …"*, *"Rent is …"*, *"TSH 5.46"*. The span after the
///    pattern is cut at the end of the thought and must have the right shape
///    — a name is one to five capitalised words, a phone number has seven
///    digits — or it is thrown away.
/// 3. **Weigh the evidence.** Something you wrote in the first person beats a
///    label on a scanned form; a better search rank counts; and documents that
///    **agree** strengthen each other — the note saying "Joseph Stalin" and the
///    bank slip saying "JOSEPH STALIN KASPAR" are the same answer twice.
///
/// When it finds nothing solid it says so and returns `nil`, and the caller
/// falls back to showing the closest matches. It never guesses.
enum AnswerExtractor {
    /// The shape an answer has to have.
    enum Kind: Equatable, Sendable {
        case name, phone, email, date, amount, number, text
    }

    struct Question: Equatable, Sendable {
        /// What is being asked for, in the asker's words: "name", "blood group".
        let slot: String
        /// "my name" rather than "the rent" — decides how the reply is phrased.
        let isPersonal: Bool
        let kind: Kind
    }

    /// One document, as the reader needs it.
    struct Document: Sendable {
        let id: UUID
        /// What you typed, dictated or reviewed — where first-person facts live.
        let authored: String
        /// What a machine read off a scan, photo or PDF.
        let extracted: String
        /// Position in the search results, 0 being best. `nil` for a note read
        /// because it was yours, without having matched the search at all.
        let rank: Int?

        init(id: UUID, authored: String, extracted: String = "", rank: Int?) {
            self.id = id
            self.authored = authored
            self.extracted = extracted
            self.rank = rank
        }
    }

    /// One place an answer was found.
    struct Evidence: Equatable, Sendable {
        let source: UUID
        let value: String
        /// The sentence it was found in, for the source row under the reply.
        let line: String
        let score: Double
    }

    struct Answer: Equatable, Sendable {
        let question: Question
        let value: String
        /// Best first; the first is where `value` came from. At most one per
        /// document.
        let evidence: [Evidence]

        /// The reply, as a sentence: "Your name is Joseph Stalin."
        var sentence: String { phrase(value) }

        /// The same, with the answer in bold for the screen.
        var markdown: String { phrase("**\(value)**") }

        private func phrase(_ shown: String) -> String {
            let owner = question.isPersonal ? "Your" : "The"
            let lastWord = question.slot.split(separator: " ").last.map(String.init) ?? ""
            let isPlural = lastWord.hasSuffix("s") && !lastWord.hasSuffix("ss") && lastWord.count > 3
            return "\(owner) \(question.slot) \(isPlural ? "are" : "is") \(shown)."
        }
    }

    // MARK: - Understanding the question

    static func question(from raw: String) -> Question? {
        var text = AnswerComposer.lastQuestion(in: raw)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        text = text.replacingOccurrences(
            of: #"^(?:(?:hey|hi|ok|okay|please|so|and)[, ]+)+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^(?:can|could|would) you (?:please )?(?:tell me |say |remind me )?"#,
            with: "",
            options: .regularExpression
        )

        if text.range(of: #"^who am i$"#, options: .regularExpression) != nil {
            return Question(slot: "name", isPersonal: true, kind: .name)
        }

        let patterns: [(pattern: String, forced: Kind?)] = [
            (#"^(?:what|whats|what's|which)(?: is| are| was)?\s+(my|the)\s+(.+)$"#, nil),
            (#"^(?:tell me|give me|show me|say)\s+(my|the)\s+(.+)$"#, nil),
            (#"^when(?: is|'s|s| was)?\s+(my|the)\s+(.+)$"#, .date),
            (#"^how much(?: is| was| does| did)?\s+(my|the)\s+(.+?)(?:\s+cost)?$"#, .amount)
        ]
        for (pattern, forced) in patterns {
            let groups = captures(pattern, in: text)
            guard groups.count == 2 else { continue }
            guard let slot = cleanSlot(groups[1]) else { return nil }
            return Question(slot: slot, isPersonal: groups[0] == "my", kind: forced ?? kind(for: slot))
        }
        return nil
    }

    /// Words that end the slot: "my TSH value **from** the latest report".
    private static let slotEnders = [
        " from ", " in my ", " in the ", " according to ", " as per ", " that i ",
        " which i ", " i saved", " i wrote", " i noted", " on my ", " written "
    ]

    /// Words that qualify which one you want, not what it is.
    private static let slotFillers: Set<String> = [
        "latest", "current", "recent", "exact", "actual", "again", "please", "now"
    ]

    /// A question about a list wants the list, not a value from it — "what are
    /// my reminders", "what is on my purchase list". Those stay with the
    /// passage-by-passage reply.
    private static let listWords: Set<String> = [
        "things", "list", "tasks", "todos", "to-dos", "plans", "notes",
        "reminders", "items", "everything", "all", "stuff"
    ]

    private static func cleanSlot(_ raw: String) -> String? {
        var slot = " " + raw + " "
        for ender in slotEnders {
            if let range = slot.range(of: ender) { slot = String(slot[..<range.lowerBound]) }
        }
        var words = slot.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        while let first = words.first, slotFillers.contains(first) { words.removeFirst() }
        while let last = words.last, slotFillers.contains(last) { words.removeLast() }

        guard (1...5).contains(words.count) else { return nil }
        guard words.allSatisfy({ !listWords.contains($0) }) else { return nil }
        return words.joined(separator: " ")
    }

    static func kind(for slot: String) -> Kind {
        let words = Set(slot.split(separator: " ").map(String.init))
        func has(_ vocabulary: Set<String>) -> Bool { !words.isDisjoint(with: vocabulary) }

        if has(["name", "surname", "firstname", "lastname"]) { return .name }
        if has(["phone", "mobile", "whatsapp", "cell", "contact"]) { return .phone }
        if has(["email", "mail", "e-mail", "gmail"]) { return .email }
        if has(["birthday", "dob", "anniversary", "birthdate"]) || slot.contains("date of birth") { return .date }
        if has(["cost", "price", "amount", "salary", "fee", "fees", "rent", "balance", "total", "bill", "budget", "emi"]) {
            return .amount
        }
        if has(["number", "no", "id", "value", "level", "reading", "count", "code", "pin", "score"]) { return .number }
        return .text
    }

    // MARK: - Reading for the answer

    /// How much a document of each kind is trusted for a first-person fact.
    /// What you wrote about yourself is the best evidence there is; a scanned
    /// form is good evidence that is often about somebody else.
    private static let authoredWeight = 1.0
    private static let extractedWeight = 0.7

    /// How much another document agreeing adds.
    private static let agreementBonus = 0.6

    /// Below this nothing is said. A single label on a scanned form, found far
    /// down the search results and agreeing with nothing, is not an answer.
    static let confidenceThreshold = 1.6

    /// Past this many documents the reader has seen enough; the answer to a
    /// factoid question is in the first handful or it is not there.
    static let maximumDocuments = 400

    static func answer(_ question: Question, in documents: [Document]) -> Answer? {
        var candidates: [Candidate] = []
        for document in documents.prefix(maximumDocuments) {
            candidates += read(document, for: question)
        }
        guard !candidates.isEmpty else { return nil }

        // Agreement: the same answer in different documents is stronger than
        // any one of them. "Joseph Stalin" and "JOSEPH STALIN KASPAR" agree.
        for index in candidates.indices {
            let agreeing = Set(
                candidates.enumerated()
                    .filter { $0.offset != index && $0.element.source != candidates[index].source }
                    .filter { agree(candidates[index].value, $0.element.value, kind: question.kind) }
                    .map(\.element.source)
            )
            candidates[index].score += agreementBonus * Double(agreeing.count)
        }

        guard let best = candidates
            .filter({ !$0.corroboratesOnly })
            .max(by: { lhs, rhs in
                lhs.score == rhs.score ? lhs.value.count > rhs.value.count : lhs.score < rhs.score
            }),
              best.score >= confidenceThreshold
        else { return nil }

        // The answer's own evidence first, then one line from each other
        // document that says the same thing.
        var evidence: [Evidence] = []
        var seen = Set<UUID>()
        let supporting = candidates
            .filter { $0.source == best.source || agree(best.value, $0.value, kind: question.kind) }
            .sorted { $0.score > $1.score }
        for candidate in [best] + supporting where seen.insert(candidate.source).inserted {
            evidence.append(Evidence(source: candidate.source, value: candidate.value, line: candidate.line, score: candidate.score))
            if evidence.count >= maximumEvidence { break }
        }

        return Answer(question: question, value: display(best.value, kind: question.kind), evidence: evidence)
    }

    /// Sources shown under a direct answer. Three is enough to trust it.
    static let maximumEvidence = 3

    private struct Candidate {
        let source: UUID
        let value: String
        let line: String
        var score: Double
        /// Found in a shape too loose to answer from on its own — a label on
        /// one line and something on the next — but fine as a second witness.
        let corroboratesOnly: Bool
    }

    private static func read(_ document: Document, for question: Question) -> [Candidate] {
        let rankBonus = document.rank.map { pow(0.8, Double($0)) } ?? 0
        var found: [Candidate] = []

        for (text, weight, isAuthored) in [
            (document.authored, authoredWeight, true),
            (document.extracted, extractedWeight, false)
        ] where !text.isEmpty {
            let lines = Tokenizer.sentences(in: text)
            for (index, line) in lines.enumerated() {
                for match in matches(in: line, next: lines[safe: index + 1], question: question, isAuthored: isAuthored) {
                    found.append(Candidate(
                        source: document.id,
                        value: match.value,
                        line: clip(match.line),
                        score: match.base * weight + rankBonus,
                        corroboratesOnly: match.corroboratesOnly
                    ))
                }
            }
        }

        // One vote per document per distinct answer: a note that says your
        // name twice is not two witnesses.
        var best: [String: Candidate] = [:]
        for candidate in found {
            let key = normalized(candidate.value)
            if let existing = best[key], existing.score >= candidate.score { continue }
            best[key] = candidate
        }
        return Array(best.values)
    }

    private struct Match {
        let value: String
        let line: String
        let base: Double
        let corroboratesOnly: Bool
    }

    /// The ways people write a fact down, strongest first.
    private static func matches(in line: String, next: String?, question: Question, isAuthored: Bool) -> [Match] {
        var results: [Match] = []

        func attempt(_ pattern: String, base: Double, in text: String? = nil, corroboratesOnly: Bool = false) {
            let source = text ?? line
            for raw in firstCaptures(pattern, in: source) {
                guard let value = clean(raw, kind: question.kind) else { continue }
                results.append(Match(value: value, line: line, base: base, corroboratesOnly: corroboratesOnly))
            }
        }

        for variant in variants(of: question) {
            let slot = NSRegularExpression.escapedPattern(for: variant)

            // "My name is Joseph Stalin", "My blood group: O+".
            attempt(#"\bmy\s+"# + slot + #"\s*(?:is|was|are|:|=|-|–)\s*(.+)"#, base: 3.0)

            // "Name: JOSEPH STALIN KASPAR", "Debit Account Name: …".
            attempt(#"\b"# + slot + #"\s*(?:no\.?)?\s*[:=–]\s*(.+)"#, base: 1.5)

            // "The rent is 400 OMR", "Blood group is O+". Weaker for a
            // personal question: it says whose only by where it was written.
            attempt(#"(?:^|\b(?:the|our)\s+)"# + slot + #"\s+(?:is|was|are|will be)\s+(.+)"#, base: question.isPersonal ? 1.4 : 2.0)

            // "TSH 5.46 0.270 - 4.20 uIU/mL": a label, then its number.
            if question.kind == .number || question.kind == .amount {
                attempt(#"\b"# + slot + #"\s*[:=\-–]?\s*(\d[\d.,]*(?:\s?[A-Za-z%/µ]+)?)"#, base: 1.8)
            }

            // A label on its own line, the value on the next: how OCR often
            // splits a form. Loose, so it can only back up another answer.
            if let next, line.range(
                of: #"^\s*(?:[A-Za-z.]+\s+){0,3}"# + slot + #"\s*[:=\-–]?\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                attempt(#"^\s*(.+)$"#, base: 0.9, in: next, corroboratesOnly: true)
            }
        }

        // "I'm Joseph", "Myself Joseph Stalin" — how people introduce
        // themselves, and only meaningful in something you wrote.
        if question.kind == .name, question.isPersonal, isAuthored {
            attempt(#"\b(?:i am|i'm|im|myself)\s+(.+)"#, base: 2.0)
        }
        return results
    }

    /// The ways a slot is written. "tsh value" is labelled "TSH"; "passport
    /// number" is labelled "Passport No".
    private static func variants(of question: Question) -> [String] {
        var variants = [question.slot]
        var words = question.slot.split(separator: " ").map(String.init)
        if let last = words.last, ["value", "level", "reading", "result"].contains(last), words.count > 1 {
            words.removeLast()
            variants.append(words.joined(separator: " "))
        }
        if question.slot.hasSuffix(" number") {
            variants.append(String(question.slot.dropLast(" number".count)) + " no")
        }
        if question.kind == .name, question.slot == "name" {
            variants.append("full name")
        }
        return variants
    }

    // MARK: - Cleaning a value

    /// Where the answer stops: the end of the clause, or a word that starts a
    /// new one. "Joseph Stalin, from Tirunelveli" is "Joseph Stalin".
    private static let valueEnd = #"[,;!?](?=\s|$)|\.(?=\s|$)|\s+(?:from|and|who|which|but|because|since|aged?|dob|s/o|d/o|w/o)\b|\s[-–—]\s"#

    /// Words that are labels on forms, never part of a name.
    private static let labelWords: Set<String> = [
        "account", "number", "no", "beneficiary", "phone", "mobile", "email",
        "address", "date", "age", "sex", "gender", "id", "ref", "reference",
        "bill", "patient", "name", "dob", "amount", "status", "type", "code",
        "branch", "ifsc", "contact", "debit", "credit", "report", "sample",
        "file", "mr", "mrs", "ms"
    ]

    /// Words that follow "I am" without being a name.
    private static let notANameWords: Set<String> = [
        "the", "a", "an", "at", "in", "on", "going", "not", "very", "here",
        "there", "fine", "good", "sure", "sorry", "back", "home", "done",
        "ok", "okay", "busy", "free", "ready", "coming", "leaving", "on", "off",
        "just", "also", "still", "always", "never", "so", "too", "this", "that"
    ]

    static func clean(_ raw: String, kind: Kind) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The value on a form runs straight into the next label: "JOSEPH
        // STALIN KASPAR Beneficiary Account Number: 000590…". Cut at the next
        // colon, then take the next label's words back off the end.
        if let colon = value.firstIndex(of: ":") {
            value = dropTrailingLabel(String(value[..<colon]))
        }
        if let end = value.range(of: valueEnd, options: [.regularExpression, .caseInsensitive]) {
            value = String(value[..<end.lowerBound])
        }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’()[]")))
        guard !value.isEmpty else { return nil }

        let words = value.split(separator: " ").map(String.init)
        switch kind {
        case .name:
            guard (1...5).contains(words.count) else { return nil }
            guard let first = value.first, first.isUppercase else { return nil }
            guard value.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
            let lowered = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            guard !lowered.contains(where: notANameWords.contains) else { return nil }
            guard !lowered.allSatisfy(labelWords.contains) else { return nil }
            guard words.allSatisfy({ $0.first?.isLetter == true }) else { return nil }
            return value

        case .phone:
            guard let match = value.range(of: #"\+?\d[\d\s\-()]{6,}\d"#, options: .regularExpression) else { return nil }
            return String(value[match])

        case .email:
            guard let match = value.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) else {
                return nil
            }
            return String(value[match])

        case .date:
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
                return nil
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = detector.firstMatch(in: value, options: [], range: range),
                  let found = Range(match.range, in: value) else { return nil }
            return String(value[found])

        case .amount, .number:
            guard value.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
            guard words.count <= 6 else { return nil }
            return value

        case .text:
            guard (1...12).contains(words.count) else { return nil }
            return value
        }
    }

    /// Takes the next label's words off the end of a value that ran into it.
    ///
    /// Forms print values in capitals and labels in title case, so when the
    /// value starts in capitals the leading run of capitalised words is the
    /// value. Otherwise, known label words are peeled off the end.
    static func dropTrailingLabel(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return text }

        if isAllCaps(first) {
            let run = words.prefix { isAllCaps($0) }
            return run.joined(separator: " ")
        }

        var kept = words
        var dropped = 0
        while let last = kept.last, dropped < 4, kept.count > 1,
              labelWords.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            kept.removeLast()
            dropped += 1
        }
        return kept.joined(separator: " ")
    }

    private static func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    // MARK: - Agreement

    /// Whether two found values are the same answer: equal, or one inside the
    /// other word for word. "Joseph Stalin" is inside "JOSEPH STALIN KASPAR".
    static func agree(_ lhs: String, _ rhs: String, kind: Kind) -> Bool {
        switch kind {
        case .phone, .number, .amount:
            let left = lhs.filter(\.isNumber)
            let right = rhs.filter(\.isNumber)
            return !left.isEmpty && (left == right || left.hasSuffix(right) || right.hasSuffix(left))
        default:
            let left = wordSet(lhs)
            let right = wordSet(rhs)
            guard !left.isEmpty, !right.isEmpty else { return false }
            return left.isSubset(of: right) || right.isSubset(of: left)
        }
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func normalized(_ value: String) -> String {
        wordSet(value).sorted().joined(separator: " ")
    }

    /// A name found in capitals on a form is shown the way a person writes it.
    private static func display(_ value: String, kind: Kind) -> String {
        guard kind == .name, value.split(separator: " ").allSatisfy({ isAllCaps(String($0)) }) else {
            return value
        }
        return value.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func clip(_ line: String, limit: Int = 140) -> String {
        let collapsed = line.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - Regex helpers

    /// Every capture group of the first match.
    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    /// The first capture group of every match.
    private static func firstCaptures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
