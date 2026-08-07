import XCTest
@testable import BrainBuddy

final class HeadlineTests: XCTestCase {
    // MARK: - Commitments lead

    /// When somebody agreed to do something, that is the subject — and it is what
    /// a pending task in the brief has to say.
    func testACommitmentBecomesTheSubject() {
        let headline = Headline.from(
            "So the yard was quiet today. I have to close the excess tower material approval from PCH, keep this as a top priority.",
            fallback: "Voice note"
        )
        XCTAssertTrue(headline.hasPrefix("Close the excess tower material"), "got “\(headline)”")
        XCTAssertLessThanOrEqual(headline.count, Headline.maximumLength + 1)
    }

    /// Speech opens with scaffolding — "I have to", "so", "okay" — that says
    /// nothing about the content.
    func testLeadingFillerIsStripped() throws {
        let condensed = try XCTUnwrap(
            Headline.condense("Okay so I have to send the signed contract to Anil")
        )
        XCTAssertEqual(condensed, "Send the signed contract to Anil")
    }

    func testStrippingStopsAtTheFirstMeaningfulWord() throws {
        let condensed = try XCTUnwrap(Headline.condense("Close the approval before the deadline"))
        XCTAssertEqual(condensed, "Close the approval before the deadline")
    }

    /// Stripping is tidying, not rewriting: it can't eat the whole sentence.
    func testStrippingIsBounded() throws {
        let condensed = try XCTUnwrap(
            Headline.condense("I think we really should just also know the answer eventually")
        )
        XCTAssertFalse(condensed.isEmpty)
        XCTAssertTrue(condensed.contains("know") || condensed.contains("answer"), "got “\(condensed)”")
    }

    // MARK: - Falling back to what it's about

    /// The reported case: the old title was the first seventy characters, which is
    /// the least informative part of a recording.
    func testTheOpeningFillerIsNotTheSubject() {
        let headline = Headline.from(
            """
            I would like to know when we are going to leave from home and we will go \
            to a place where we will buy gold and then come back home after that.
            """,
            fallback: "Voice note"
        )
        XCTAssertFalse(headline.isEmpty)
        XCTAssertLessThanOrEqual(headline.count, Headline.maximumLength + 1)
        XCTAssertFalse(headline.hasPrefix("I would like to know"), "got “\(headline)”")
    }

    /// Content that never commits to anything still has subjects in it, and a
    /// short list of them heads a rambling conversation better than a truncated
    /// quote does.
    func testContentWithNoCommitmentStillGetsASubject() {
        let headline = Headline.from(
            "The yard was quiet this morning. Material sat there again all day. Nobody came from the office.",
            fallback: "Voice note"
        )
        XCTAssertFalse(headline.isEmpty)
        XCTAssertLessThanOrEqual(headline.count, Headline.maximumLength + 1)
        XCTAssertFalse(headline.hasPrefix("The yard was quiet"), "got “\(headline)”")
    }

    func testEmptyTextUsesTheFallback() {
        XCTAssertEqual(Headline.from("", fallback: "Voice note"), "Voice note")
        XCTAssertEqual(Headline.from("   \n ", fallback: "Voice note"), "Voice note")
    }

    // MARK: - Shape

    func testAHeadlineEndsAtACommaWhenThereIsOneInRange() throws {
        let condensed = try XCTUnwrap(
            Headline.condense("Close the PCH material approval, and then chase the invoice from the yard")
        )
        XCTAssertEqual(condensed, "Close the PCH material approval")
    }

    func testALongHeadlineIsClippedOnAWordBoundary() throws {
        let condensed = try XCTUnwrap(
            Headline.condense(String(repeating: "material ", count: 20))
        )
        XCTAssertLessThanOrEqual(condensed.count, Headline.maximumLength + 1)
        XCTAssertTrue(condensed.hasSuffix("…"))
        XCTAssertFalse(condensed.hasSuffix(" …"))
    }

    func testAHeadlineIsCapitalized() throws {
        let condensed = try XCTUnwrap(Headline.condense("close the approval this week"))
        XCTAssertEqual(condensed.first, "C")
    }

    func testTooShortToBeASubject() {
        XCTAssertNil(Headline.condense("okay yeah sure"))
    }

    // MARK: - Titles derived from content

    /// A note someone typed has a first line, and it always beats a derived one.
    func testADeliberateFirstLineStillWins() {
        XCTAssertEqual(
            TextAnalysis.suggestedTitle(
                from: "Dentist appointment\nTuesday at four, bring the insurance card.",
                fallback: "Note"
            ),
            "Dentist appointment"
        )
    }

    /// A transcript has no first line, which is how titles like "I would like to
    /// know when I we are going to leave from home and we…" happened.
    func testATranscriptGetsADerivedTitle() {
        let title = TextAnalysis.suggestedTitle(
            from: "Okay so I have to close the excess tower material approval from PCH before Friday and it is a top priority for everyone here.",
            fallback: "Voice note"
        )
        XCTAssertFalse(title.hasPrefix("Okay so"), "got “\(title)”")
        XCTAssertLessThanOrEqual(title.count, Headline.maximumLength + 1)
    }

    func testAShortSingleLineNoteKeepsItsText() {
        XCTAssertEqual(
            TextAnalysis.suggestedTitle(from: "Buy milk on the way home", fallback: "Note"),
            "Buy milk on the way home"
        )
    }
}
