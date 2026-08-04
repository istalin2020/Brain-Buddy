import Foundation
import NaturalLanguage

/// Derives the metadata that makes a raw capture findable: a title, keywords,
/// and any `#tags` the user typed.
enum TextAnalysis {
    /// A short title for something the user never titled.
    ///
    /// Prefers a genuine first line (people naturally write one), otherwise
    /// falls back to the first sentence, trimmed to a readable length.
    static func suggestedTitle(from text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let firstLine = trimmed
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? trimmed

        let candidate = firstLine.count <= 70
            ? firstLine
            : (Tokenizer.sentences(in: firstLine).first ?? firstLine)

        if candidate.count <= 70 { return candidate }

        // Cut on a word boundary rather than mid-word.
        let cut = candidate.prefix(70)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    /// Keywords used for the `keywordIndex` field: nouns and proper nouns win,
    /// because those are what people search their own notes for.
    static func keywords(from text: String, limit: Int = 24) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var weights: [String: Double] = [:]

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]

        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            guard let tag else { return true }
            guard let term = Tokenizer.normalize(String(trimmed[range])) else { return true }
            switch tag {
            case .noun: weights[term, default: 0] += 2.0
            case .verb, .adjective: weights[term, default: 0] += 0.8
            default: break
            }
            return true
        }

        // Proper nouns and names carry the most search signal.
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = trimmed
        nameTagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag, [.personalName, .placeName, .organizationName].contains(tag) else { return true }
            guard let term = Tokenizer.normalize(String(trimmed[range])) else { return true }
            weights[term, default: 0] += 3.0
            return true
        }

        // If the tagger produced nothing useful (short or non-English text),
        // fall back to plain frequency so we never index an empty keyword set.
        if weights.isEmpty {
            for term in Tokenizer.tokens(in: trimmed) {
                weights[term, default: 0] += 1
            }
        }

        return weights
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// Returns the URL when `text` is *nothing but* a single link.
    ///
    /// This is the shape of a share-sheet URL or a pasted address, and it earns
    /// its own memory kind. A URL sitting inside a sentence does not — that's a
    /// note that happens to contain a link.
    static func bareURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }

        let whole = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: whole),
              match.range == whole,
              let url = match.url,
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// A readable title for a link: the host, plus the last path component when
    /// it looks like a slug rather than an ID.
    static func linkTitle(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let slug = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .last?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .removingPercentEncoding

        guard let slug, slug.count > 2, slug.count <= 60, slug.rangeOfCharacter(from: .letters) != nil else {
            return host
        }
        return "\(host) — \(slug)"
    }

    /// Pulls `#hashtags` out of typed text so tagging costs no extra taps.
    static func hashtags(in text: String) -> [String] {
        var found: [String] = []
        for word in text.components(separatedBy: .whitespacesAndNewlines) where word.hasPrefix("#") {
            let name = MemoryTag.normalize(word)
            if name.count > 1, !found.contains(name) { found.append(name) }
        }
        return found
    }
}
