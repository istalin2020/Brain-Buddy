import XCTest
@testable import BrainBuddy

final class AnswerComposerTests: XCTestCase {
    private func source(
        title: String = "Dentist appointment",
        snippet: String = "Tuesday at four with Dr Alvarez",
        daysAgo: Int = 0,
        kindTitle: String = "Note"
    ) -> AnswerSource {
        AnswerSource(
            title: title,
            snippet: snippet,
            createdAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            kindTitle: kindTitle,
            score: 1
        )
    }

    func testNoResultsSaysSoWithoutInventingAnything() {
        let answer = AnswerComposer.compose(query: "what did I save about the dentist", sources: [])
        XCTAssertFalse(answer.hasResults)
        XCTAssertTrue(answer.written.contains("dentist"))
        XCTAssertEqual(answer.written, answer.spoken)
    }

    func testAnswerQuotesTheStoredText() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source()])
        XCTAssertTrue(answer.hasResults)
        XCTAssertTrue(answer.written.contains("Tuesday at four with Dr Alvarez"))
        XCTAssertTrue(answer.written.contains("today"))
        XCTAssertTrue(answer.written.contains("Dentist appointment"), "the source is named")
    }

    /// The reply goes through every source, not just the best one.
    func testEverySourceGetsAPassage() {
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [
                source(title: "Dentist appointment"),
                source(title: "Insurance card", snippet: "Policy covers two check-ups a year"),
                source(title: "Dr Alvarez", snippet: "Parking is behind the clinic")
            ]
        )
        XCTAssertTrue(answer.written.contains("3 things in your brain mention it"))
        XCTAssertTrue(answer.written.contains("Insurance card"))
        XCTAssertTrue(answer.written.contains("Policy covers two check-ups a year"))
        XCTAssertTrue(answer.written.contains("Parking is behind the clinic"))
        XCTAssertEqual(answer.references.count, 3)
    }

    /// Every line that bears on the question, not only the one that answers it.
    func testAllRelevantLinesAreQuoted() {
        let lines = [
            "Dentist on Tuesday at four",
            "Bring the insurance card",
            "Ask about the crown on the lower left"
        ]
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [AnswerSource(title: "Dentist", snippet: lines[0], lines: lines, createdAt: Date(), kindTitle: "Note", score: 1)]
        )
        for line in lines {
            XCTAssertTrue(answer.written.contains(line), "missing “\(line)”")
        }
    }

    func testMatchesBeyondThoseQuotedAreCounted() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source(), source()], totalMatches: 4)
        XCTAssertTrue(answer.written.contains("2 more notes mention it too"))
        XCTAssertTrue(answer.spoken.contains("2 more notes mention it"))
    }

    func testSingleExtraMatchUsesSingularWording() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source()], totalMatches: 2)
        XCTAssertTrue(answer.written.contains("1 more note mentions it too"))
        XCTAssertTrue(answer.spoken.contains("One more note mentions it"))
    }

    func testReferencesPointBackAtTheSources() {
        let identifier = UUID()
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [AnswerSource(identifier: identifier, title: "Dentist", snippet: "Tuesday", createdAt: Date(), kindTitle: "Note", score: 1)]
        )
        XCTAssertEqual(answer.references.first?.id, identifier)
        XCTAssertEqual(answer.references.first?.kindTitle, "Note")
    }

    // MARK: - Worth noting

    /// The concrete things in the quoted lines, as written — never computed.
    func testAmountsAndDatesAreCalledOut() {
        let details = AnswerComposer.details(
            in: ["Al Qersh confirmed the sparing work with 60,000 Omani rial", "Site review on 29 July 2026 at 4 PM"],
            query: "sparing work"
        )
        XCTAssertTrue(details.contains { $0.lowercased().contains("60,000 omani rial") }, "got \(details)")
        XCTAssertTrue(details.contains { $0.contains("29 July 2026") }, "got \(details)")
    }

    /// A number next to a word you asked about is an answer.
    func testALabelledValueYouAskedAboutIsCalledOut() {
        let details = AnswerComposer.details(in: ["TSH 5.46 0.270 - 4.20 uIU/mL"], query: "what is my TSH value")
        XCTAssertTrue(details.contains { $0.hasPrefix("TSH 5.46") }, "got \(details)")
    }

    /// The detector reads a numeric range as a clock time; that is not a detail.
    func testANumericRangeIsNotADetail() {
        let details = AnswerComposer.details(in: ["Reference range 2 - 2.54 for that panel"], query: "panel")
        XCTAssertTrue(details.isEmpty, "got \(details)")
    }

    func testDetailsAreNotRepeated() {
        let details = AnswerComposer.details(
            in: ["Invoice for 1,250 OMR", "The 1,250 OMR invoice is still open"],
            query: "invoice"
        )
        XCTAssertEqual(details.filter { $0.lowercased().contains("1,250 omr") }.count, 1, "got \(details)")
    }

    func testSubjectStripsQuestionFiller() {
        XCTAssertEqual(AnswerComposer.subject(of: "hey, what did I save about the dentist?"), "dentist")
    }

    func testTightenCollapsesWhitespaceAndTruncatesOnAWordBoundary() {
        XCTAssertEqual(AnswerComposer.tighten("  hello\n\n  world  "), "hello world")

        let long = String(repeating: "alpha beta ", count: 60)
        let tightened = AnswerComposer.tighten(long, limit: 40)
        XCTAssertLessThanOrEqual(tightened.count, 41)
        XCTAssertTrue(tightened.hasSuffix("…"))
        XCTAssertFalse(tightened.contains("  "))
    }

    func testRelativeDescriptions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        func description(daysAgo: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return AnswerComposer.relativeDescription(for: date, now: now, calendar: calendar)
        }

        XCTAssertEqual(description(daysAgo: 0), "today")
        XCTAssertEqual(description(daysAgo: 1), "yesterday")
        XCTAssertEqual(description(daysAgo: 10), "last week")
        XCTAssertEqual(description(daysAgo: 45), "last month")
        XCTAssertEqual(description(daysAgo: 200), "6 months ago")
    }

    func testFutureDatesDoNotProduceNonsense() {
        let now = Date()
        let tomorrow = now.addingTimeInterval(86_400 * 3)
        XCTAssertEqual(AnswerComposer.relativeDescription(for: tomorrow, now: now), "recently")
    }
}
