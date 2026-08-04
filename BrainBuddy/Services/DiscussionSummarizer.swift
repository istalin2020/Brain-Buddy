import Foundation
import NaturalLanguage

/// Condenses a long transcript — a meeting, two people talking something over —
/// into something readable in ten seconds.
///
/// **Extractive, like `AnswerComposer`.** Every line of a summary is a sentence
/// somebody actually said, quoted verbatim. Nothing is generated. That rules out
/// the one failure a discussion summary must never have: inventing a decision
/// that was never made, or an owner who never agreed to anything.
///
/// Deliberately free of SwiftData, UIKit and the network, so its behavior is
/// unit-testable without a device.
enum DiscussionSummarizer {
    struct Summary: Equatable {
        /// The recurring subjects, in the speakers' own spelling.
        var topics: [String]
        /// The sentences that carry the most of the transcript's own vocabulary.
        var keyPoints: [String]
        /// Sentences where somebody committed to something.
        var followUps: [String]

        var isEmpty: Bool { keyPoints.isEmpty && followUps.isEmpty }

        /// The form that gets stored on the memory and read on screen.
        var text: String {
            var lines: [String] = []
            if !topics.isEmpty {
                lines.append("Topics: " + topics.joined(separator: ", "))
            }
            if !keyPoints.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Key points")
                lines.append(contentsOf: keyPoints.map { "• \($0)" })
            }
            if !followUps.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Follow-ups")
                lines.append(contentsOf: followUps.map { "• \($0)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Shortest transcript worth condensing. Below this a "summary" would just be
    /// the transcript with bullets in front of it, which is worse than nothing
    /// because it implies work was done.
    static let minimumWords = 25

    // MARK: - Entry point

    /// Returns `nil` when there is not enough material to summarize honestly.
    static func summarize(
        _ transcript: String,
        maxKeyPoints: Int = 5,
        maxFollowUps: Int = 4
    ) -> Summary? {
        let sentences = usableSentences(in: transcript)
        guard sentences.count >= 2 else { return nil }
        guard wordCount(of: transcript) >= minimumWords else { return nil }

        // Document frequency over the transcript's own sentences: a term that
        // recurs across a discussion is what the discussion was about.
        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for term in Set(Tokenizer.tokens(in: sentence)) {
                frequency[term, default: 0] += 1
            }
        }
        guard let peak = frequency.values.max(), peak > 0 else { return nil }
        let scale = Double(peak)

        let scores = sentences.indices.map { index in
            score(sentences[index], at: index, frequency: frequency, scale: scale)
        }

        // Commitments are claimed first, so an agreed action is never demoted to
        // a key point — and never printed twice under two headings.
        let followUpIndexes = pick(
            from: sentences.indices.filter { isCommitment(sentences[$0]) },
            scores: scores,
            limit: maxFollowUps,
            sentences: sentences
        )

        let remaining = sentences.indices.filter { !followUpIndexes.contains($0) }
        // Scale with length: a four-sentence chat does not have five key points.
        let pointBudget = min(maxKeyPoints, max(2, remaining.count / 3))
        let keyPointIndexes = pick(
            from: remaining,
            scores: scores,
            limit: pointBudget,
            sentences: sentences
        )

        let summary = Summary(
            topics: topics(in: transcript),
            keyPoints: keyPointIndexes.map { sentences[$0] },
            followUps: followUpIndexes.map { sentences[$0] }
        )
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Sentence selection

    /// Sentences worth quoting. Drops the "yeah", "okay, right" fragments that
    /// make up a third of any real conversation.
    private static func usableSentences(in transcript: String) -> [String] {
        Tokenizer.sentences(in: transcript)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { wordCount(of: $0) >= 4 }
    }

    /// Mean term weight rather than the sum, so one rambling sentence can't win
    /// on sheer volume. Openings get a nudge: people state the subject first.
    private static func score(
        _ sentence: String,
        at index: Int,
        frequency: [String: Int],
        scale: Double
    ) -> Double {
        let terms = Set(Tokenizer.tokens(in: sentence))
        guard !terms.isEmpty else { return 0 }
        let weight = terms.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) / scale }
        var value = weight / Double(terms.count).squareRoot()
        if index == 0 { value *= 1.15 }
        return value
    }

    /// Takes the best `limit` candidates, drops near-duplicates, and returns them
    /// in transcript order — a summary that jumps around in time is hard to read.
    private static func pick(
        from candidates: [Int],
        scores: [Double],
        limit: Int,
        sentences: [String]
    ) -> [Int] {
        guard limit > 0 else { return [] }
        // Index breaks score ties, so the result never depends on sort stability.
        let ranked = candidates.sorted { lhs, rhs in
            scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
        }

        var chosen: [Int] = []
        var chosenTerms: [Set<String>] = []
        for index in ranked where chosen.count < limit {
            let terms = Set(Tokenizer.tokens(in: sentences[index]))
            guard !terms.isEmpty else { continue }
            // People repeat themselves when they talk; two restatements of one
            // point should not spend two of the five slots.
            guard !chosenTerms.contains(where: { overlap(terms, $0) > 0.7 }) else { continue }
            chosen.append(index)
            chosenTerms.append(terms)
        }
        return chosen.sorted()
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    // MARK: - Commitments

    /// Phrases that mark a sentence as something somebody took on. Matched
    /// against a space-padded, contraction-expanded form so `will` doesn't fire
    /// inside "willing" and `let's` matches however the recognizer spelled it.
    private static let commitmentCues: [String] = [
        " action item", " assign", " deadline", " due ", " follow up",
        " has to ", " have to ", " let us ", " must ", " need to ", " needs to ",
        " next step", " priority", " should ", " will ", " going to "
    ]

    static func isCommitment(_ sentence: String) -> Bool {
        let padded = " " + expandedForMatching(sentence) + " "
        return commitmentCues.contains { padded.contains($0) }
    }

    private static func expandedForMatching(_ sentence: String) -> String {
        sentence
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "let's", with: "let us")
            .replacingOccurrences(of: "n't", with: " not")
            .replacingOccurrences(of: "'ll", with: " will")
            .replacingOccurrences(of: "gonna", with: "going to")
    }

    // MARK: - Topics

    /// The recurring nouns and names, keeping the spelling the speaker used —
    /// stemmed keywords are right for the search index and unreadable in a
    /// heading ("materi", "prioriti").
    static func topics(in text: String, limit: Int = 4) -> [String] {
        guard !text.isEmpty else { return [] }

        var weights: [String: Double] = [:]
        var display: [String: String] = [:]
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]
        let range = text.startIndex..<text.endIndex

        func note(_ word: String, weight: Double) {
            let key = word.lowercased()
            guard key.count > 2 else { return }
            guard !Tokenizer.stopwords.contains(key), !Tokenizer.questionFillers.contains(key) else { return }
            weights[key, default: 0] += weight
            // Prefer a capitalized spelling when one exists: "PCH", not "pch".
            if let existing = display[key] {
                if word.first?.isUppercase == true, existing.first?.isUppercase != true {
                    display[key] = word
                }
            } else {
                display[key] = word
            }
        }

        let lexical = NLTagger(tagSchemes: [.lexicalClass])
        lexical.string = text
        lexical.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, wordRange in
            if tag == .noun { note(String(text[wordRange]), weight: 1) }
            return true
        }

        // Who and what was named carries more of a discussion than any noun.
        let names = NLTagger(tagSchemes: [.nameType])
        names.string = text
        names.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, wordRange in
            guard let tag, [.personalName, .placeName, .organizationName].contains(tag) else { return true }
            note(String(text[wordRange]), weight: 2)
            return true
        }

        return weights
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }

    // MARK: - Helpers

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
