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
    }

    func testAdditionalMatchesAreCounted() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source(), source(), source()])
        XCTAssertTrue(answer.written.contains("2 other items also match"))
    }

    func testSingleExtraMatchUsesSingularWording() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source(), source()])
        XCTAssertTrue(answer.written.contains("1 other item also matches"))
        XCTAssertTrue(answer.spoken.contains("1 more match"))
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
