import Foundation

/// The minimum a composed answer needs to know about a result. Kept separate
/// from `SearchHit` so answer phrasing is testable without SwiftData.
struct AnswerSource {
    let title: String
    let snippet: String
    let createdAt: Date
    let kindTitle: String
    let score: Double
}

/// Turns ranked results into one sentence a person can read — or hear.
///
/// This is extractive on purpose: it quotes what you actually stored rather
/// than generating new prose, so the app can never tell you something your
/// notes do not say, and it works entirely offline.
enum AnswerComposer {
    struct Answer {
        let spoken: String
        let written: String
        let hasResults: Bool
    }

    static func compose(query: String, sources: [AnswerSource], now: Date = Date()) -> Answer {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let best = sources.first else {
            let miss = cleanQuery.isEmpty
                ? "Ask me anything you have saved."
                : "I couldn't find anything about \(subject(of: cleanQuery)) in your brain yet."
            return Answer(spoken: miss, written: miss, hasResults: false)
        }

        let when = relativeDescription(for: best.createdAt, now: now)
        let quote = tighten(best.snippet.isEmpty ? best.title : best.snippet)

        var written = "From your \(best.kindTitle.lowercased()) \(when): \(quote)"
        var spoken = "\(when.capitalizedFirst) you saved: \(quote)"

        if sources.count > 1 {
            let others = sources.count - 1
            if others == 1 {
                written += "\n\n1 other item also matches."
                spoken += ". I found 1 more match."
            } else {
                written += "\n\n\(others) other items also match."
                spoken += ". I found \(others) more matches."
            }
        }

        return Answer(spoken: spoken, written: written, hasResults: true)
    }

    /// Strips filler from a question so the "no results" line reads naturally.
    static func subject(of query: String) -> String {
        let terms = Tokenizer.queryTokens(in: query)
        guard !terms.isEmpty else { return "that" }
        return terms.prefix(6).joined(separator: " ")
    }

    /// Collapses whitespace and caps length so a spoken answer stays listenable.
    static func tighten(_ text: String, limit: Int = 320) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    /// Phrased relative to the supplied `now` rather than the wall clock, so the
    /// wording is deterministic and testable.
    static func relativeDescription(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0:
            return "recently"
        case 0...6:
            return "on \(date.formatted(.dateTime.weekday(.wide)))"
        case 7...30:
            let weeks = max(1, days / 7)
            return weeks == 1 ? "last week" : "\(weeks) weeks ago"
        case 31...364:
            let months = max(1, days / 30)
            return months == 1 ? "last month" : "\(months) months ago"
        default:
            return "in \(date.formatted(.dateTime.year()))"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
