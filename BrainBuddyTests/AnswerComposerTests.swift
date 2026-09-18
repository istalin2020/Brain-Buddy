import XCTest
@testable import BrainBuddy

final class AnswerComposerTests: XCTestCase {
    private func source(
        title: String = "Dentist appointment",
        snippet: String = "Tuesday at four with Dr Alvarez",
        lines: [String] = [],
        daysAgo: Int = 0,
        kindTitle: String = "Note",
        score: Double = 1
    ) -> AnswerSource {
        AnswerSource(
            title: title,
            snippet: snippet,
            lines: lines,
            createdAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            kindTitle: kindTitle,
            score: score
        )
    }

    func testNoResultsSaysSoWithoutInventingAnything() {
        let answer = AnswerComposer.compose(query: "what did I save about the dentist", sources: [])
        XCTAssertFalse(answer.hasResults)
        XCTAssertTrue(answer.written.contains("dentist"))
        XCTAssertEqual(answer.written, answer.spoken)
    }

    /// A note whose *name* is on the subject is worth quoting even when its
    /// body never repeats the word. "Dentist appointment" answers "what did I
    /// save about the dentist", and "Tuesday at four with Dr Alvarez" is the
    /// answer.
    func testANoteNamedAfterTheSubjectIsQuoted() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source()])
        XCTAssertTrue(answer.hasResults)
        XCTAssertTrue(answer.written.contains("Dentist appointment"), "the source is named")
        XCTAssertTrue(answer.written.contains("Tuesday at four with Dr Alvarez"))
        XCTAssertTrue(answer.written.contains("today"))
    }

    /// The reply goes through every source, not just the best one.
    func testEverySourceGetsAPassage() {
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [
                source(title: "Dentist appointment"),
                source(title: "Insurance card", lines: ["The dentist is covered twice a year"]),
                source(title: "Dr Alvarez", lines: ["Parking for the dentist is behind the clinic"])
            ]
        )
        XCTAssertTrue(answer.written.contains("3 things in your brain mention it"))
        XCTAssertTrue(answer.written.contains("Insurance card"))
        XCTAssertTrue(answer.written.contains("covered twice a year"))
        XCTAssertTrue(answer.written.contains("behind the clinic"))
        XCTAssertEqual(answer.references.count, 3)
    }

    /// Every line that bears on the question, not only the one that answers it.
    func testAllRelevantLinesAreQuoted() {
        let lines = [
            "Dentist on Tuesday at four",
            "Bring the insurance card to the dentist",
            "Ask the dentist about the crown on the lower left"
        ]
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [source(title: "Appointments", lines: lines)]
        )
        for line in lines {
            XCTAssertTrue(answer.written.contains(line), "missing “\(line)”")
        }
    }

    // MARK: - Nothing said twice

    /// The reported row: a note called "Purchase a black belt" whose only line
    /// is "Purchase a black belt", printed as a heading and then again as its
    /// own bullet.
    func testATitleIsNotRepeatedAsItsOwnBullet() {
        let answer = AnswerComposer.compose(
            query: "what is on my purchase list",
            sources: [source(title: "Purchase a black belt", lines: ["Purchase a black belt"])]
        )
        XCTAssertTrue(answer.written.contains("Purchase a black belt"))
        XCTAssertFalse(answer.written.contains("• Purchase a black belt"), "got \(answer.written)")
    }

    /// The same, with the wording varied enough to survive an exact-match
    /// check but not a restatement one.
    func testARewordedRepeatOfTheTitleIsAlsoDropped() {
        let answer = AnswerComposer.compose(
            query: "thyroid tablet",
            sources: [source(
                title: "Remind me to purchase thyroid tablet when I reach any shopping centre",
                lines: ["Remind me to purchase thyroid tablet when I reach a shopping centre"]
            )]
        )
        XCTAssertFalse(answer.written.contains("•"), "got \(answer.written)")
    }

    // MARK: - Nothing irrelevant

    /// The reported row: a question about a purchase list answered, in part,
    /// with "Because I have only six hours balance". No line of that recording
    /// carries a word from the question, so it has nothing to contribute and
    /// must not be quoted from at all.
    func testASourceWithNothingToSayIsLeftOut() {
        let answer = AnswerComposer.compose(
            query: "what is on my purchase list",
            sources: [
                source(title: "Purchase a black belt", lines: ["Purchase a black belt"]),
                source(
                    title: "Go and pick up Vadiya Thaayum Bridge Station",
                    snippet: "Because I have only six hours balance, so that's why I remove this",
                    lines: []
                )
            ]
        )
        XCTAssertFalse(answer.written.contains("six hours balance"), "got \(answer.written)")
        XCTAssertFalse(answer.written.contains("Bridge Station"), "got \(answer.written)")
        XCTAssertEqual(answer.references.count, 1, "only the relevant note is a source")
    }

    /// A match scoring far below the best one is not part of an answer, even
    /// though the ranker was happy to return it.
    func testAMatchFarWeakerThanTheBestIsDropped() {
        let answer = AnswerComposer.compose(
            query: "purchase list",
            sources: [
                source(title: "Purchase a black belt", lines: ["Purchase a black belt"], score: 1.0),
                source(title: "AI Hackathon meeting", lines: ["Purchase order review at the meeting"], score: 0.1)
            ]
        )
        XCTAssertFalse(answer.written.contains("Hackathon"), "got \(answer.written)")
    }

    /// The floor is relative, so the best match always survives however low
    /// everything scored.
    func testTheBestMatchSurvivesHoweverWeakTheScores() {
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [source(title: "Dentist appointment", score: 0.02)]
        )
        XCTAssertTrue(answer.hasResults)
    }

    // MARK: - Counting

    func testMatchesBeyondThoseQuotedAreCounted() {
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [source(), source(title: "Dentist follow-up")],
            totalMatches: 4
        )
        XCTAssertTrue(answer.written.contains("2 more matches are listed below"))
    }

    func testSingleExtraMatchUsesSingularWording() {
        let answer = AnswerComposer.compose(query: "dentist", sources: [source()], totalMatches: 2)
        XCTAssertTrue(answer.written.contains("1 more match is listed below"))
        XCTAssertTrue(answer.spoken.contains("One more match is listed below"))
    }

    func testReferencesPointBackAtTheSources() {
        let identifier = UUID()
        let answer = AnswerComposer.compose(
            query: "dentist",
            sources: [AnswerSource(
                identifier: identifier,
                title: "Dentist",
                snippet: "Tuesday",
                createdAt: Date(),
                kindTitle: "Note",
                score: 1
            )]
        )
        XCTAssertEqual(answer.references.first?.id, identifier)
        XCTAssertEqual(answer.references.first?.kindTitle, "Note")
    }

    // MARK: - What the question was about

    func testSubjectStripsQuestionFiller() {
        XCTAssertEqual(AnswerComposer.subject(of: "hey, what did I save about the dentist?"), "dentist")
    }

    /// The reported heading: "Here's what I have on water all all purchase
    /// list". Dictation restarted the question, and the search terms were
    /// stemmed and repeated.
    func testSubjectDropsADictationFalseStart() {
        XCTAssertEqual(
            AnswerComposer.subject(of: "Water, all the things are What all the things are there on my purchase list?"),
            "purchase list"
        )
    }

    func testSubjectNeverRepeatsAWord() {
        let subject = AnswerComposer.subject(of: "what about the invoice, the invoice from the yard")
        XCTAssertEqual(subject.components(separatedBy: " ").count, Set(subject.components(separatedBy: " ")).count)
    }

    func testSubjectKeepsTheAskersOwnSpelling() {
        XCTAssertEqual(AnswerComposer.subject(of: "what about the insulators"), "insulators")
    }

    func testAQuestionWithNoSubjectLeftStillReadsAsASentence() {
        XCTAssertEqual(AnswerComposer.subject(of: "what about it?"), "that")
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

    // MARK: - Shaping

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
