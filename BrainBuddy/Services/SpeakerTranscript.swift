import Foundation

/// A transcript that says who said what.
///
/// Written as plain text, one paragraph per turn, because that is what you read,
/// search, edit and share:
///
///     Person 1: Shall we start with the drawings?
///
///     Person 2: I'll send them over by Thursday.
///
/// Rename "Person 2" to "Anil" and every turn and summary line follows. Give two
/// labels the same name and they become one person — which is also how you
/// correct the app when it has split one voice in two.
///
/// Pure text handling, free of audio and UIKit, so every rule is tested.
enum SpeakerTranscript {
    /// One recognised word and when it was said, in seconds from the start.
    struct Word: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// A stretch of speech with no pause in it: the unit voices are told apart by.
    struct Utterance: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    struct Turn: Equatable {
        var speaker: String
        var text: String
    }

    /// A silence this long ends an utterance. Speakers hand over in gaps
    /// about this size, and shorter ones are mostly breaths.
    static let pause: TimeInterval = 0.3
    /// Longer utterances are cut, so one that runs across a change of speaker
    /// costs a few seconds, not a minute.
    static let longest: TimeInterval = 6

    static func label(_ index: Int) -> String { "Person \(index + 1)" }

    // MARK: - Words into utterances

    static func utterances(from words: [Word]) -> [Utterance] {
        var groups: [[Word]] = []
        for word in words {
            if let previous = groups.last?.last, word.start - previous.end < pause {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }

        var result: [Utterance] = []
        for group in groups {
            var rest = group[...]
            while let first = rest.first, let last = rest.last, last.end - first.start > longest, rest.count > 1 {
                let cut = cutPoint(in: Array(rest))
                result.append(utterance(of: rest.prefix(cut)))
                rest = rest.dropFirst(cut)
            }
            if !rest.isEmpty { result.append(utterance(of: rest)) }
        }
        return result
    }

    /// Where to split a long utterance: the widest gap between three and six
    /// seconds in, and a sentence end counts as a little wider.
    private static func cutPoint(in words: [Word]) -> Int {
        let start = words[0].start
        var best: (index: Int, score: Double)?
        for index in 1..<words.count {
            let at = words[index].start - start
            guard at >= longest / 2, at <= longest else { continue }
            var score = words[index].start - words[index - 1].end
            if let mark = words[index - 1].text.last, ".?!".contains(mark) { score += 0.2 }
            if best == nil || score > best!.score { best = (index, score) }
        }
        if let best { return best.index }
        // No boundary in the window — a very long word, or timings squeezed
        // together. Cut at the first word past it.
        let later = words.indices.dropFirst().first { words[$0].start - start > longest }
        return later ?? words.count - 1
    }

    private static func utterance<S: Collection>(of words: S) -> Utterance where S.Element == Word {
        Utterance(
            text: words.map(\.text).joined(separator: " "),
            start: words.first?.start ?? 0,
            end: words.map(\.end).max() ?? 0
        )
    }

    // MARK: - Utterances into turns

    /// Joins consecutive utterances by the same speaker into one turn.
    static func turns(_ utterances: [Utterance], labels: [Int]) -> [Turn] {
        var turns: [Turn] = []
        for (utterance, index) in zip(utterances, labels) {
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = label(index)
            if turns.last?.speaker == speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: speaker, text: text))
            }
        }
        return turns
    }

    static func text(of turns: [Turn]) -> String {
        turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - Reading one back

    /// A speaker name at the start of a line: a word or a few, then a colon.
    private static let labelPattern = try! NSRegularExpression(
        pattern: #"^(\p{L}[\p{L}\p{N} .'\-]{0,30}?):\s+(.+)$"#
    )

    /// The turns in a transcript, or `nil` if it doesn't read as one.
    ///
    /// - Parameter strict: also require what only a conversation has — two
    ///   speakers, someone speaking more than once, and turns longer than a
    ///   form's "Name: Anil". Summaries use this, so a scanned form with
    ///   labelled lines is never summarised as if its labels were people.
    static func turns(in text: String, strict: Bool = false) -> [Turn]? {
        var turns: [Turn] = []
        var labelled = 0
        var lines = 0

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines += 1
            let range = NSRange(line.startIndex..., in: line)
            if let match = labelPattern.firstMatch(in: line, range: range),
               let name = Range(match.range(at: 1), in: line),
               let body = Range(match.range(at: 2), in: line) {
                labelled += 1
                turns.append(Turn(
                    speaker: String(line[name]).trimmingCharacters(in: .whitespaces),
                    text: String(line[body])
                ))
            } else if !turns.isEmpty {
                turns[turns.count - 1].text += " " + line
            }
        }

        guard lines >= 2, !turns.isEmpty, Double(labelled) >= 0.8 * Double(lines) else { return nil }
        guard strict else { return turns }

        var counts: [String: Int] = [:]
        for turn in turns { counts[turn.speaker, default: 0] += 1 }
        let words = turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard counts.count >= 2,
              counts.values.contains(where: { $0 >= 2 }),
              Double(words) / Double(turns.count) >= 6
        else { return nil }
        return turns
    }

    /// The people in a transcript, in the order they first speak.
    static func speakers(in text: String) -> [String] {
        var seen: [String] = []
        for turn in turns(in: text) ?? [] where !seen.contains(turn.speaker) {
            seen.append(turn.speaker)
        }
        return seen
    }

    // MARK: - Renaming

    /// Renames a speaker throughout a transcript.
    static func renaming(_ text: String, from old: String, to new: String) -> String {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return text }
        return text
            .components(separatedBy: "\n")
            .map { line in
                let prefix = old + ":"
                guard line.hasPrefix(prefix) else { return line }
                return name + ":" + line.dropFirst(prefix.count)
            }
            .joined(separator: "\n")
    }

    /// Renames a speaker throughout a stored summary: its list of speakers and
    /// every line it attributes to them.
    static func renamingInSummary(_ summary: String, from old: String, to new: String) -> String {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return summary }
        let bulleted = DiscussionSummarizer.bullet + " " + old + ":"
        return summary
            .components(separatedBy: "\n")
            .map { line in
                if line.hasPrefix(DiscussionSummarizer.speakersPrefix) {
                    var names: [String] = []
                    for listed in line.dropFirst(DiscussionSummarizer.speakersPrefix.count).components(separatedBy: ",") {
                        let trimmed = listed.trimmingCharacters(in: .whitespaces)
                        let renamed = trimmed == old ? name : trimmed
                        // Two labels given one name are one person.
                        if !renamed.isEmpty, !names.contains(renamed) { names.append(renamed) }
                    }
                    return DiscussionSummarizer.speakersPrefix + names.joined(separator: ", ")
                }
                guard line.hasPrefix(bulleted) else { return line }
                return DiscussionSummarizer.bullet + " " + name + ":" + line.dropFirst(bulleted.count)
            }
            .joined(separator: "\n")
    }
}
