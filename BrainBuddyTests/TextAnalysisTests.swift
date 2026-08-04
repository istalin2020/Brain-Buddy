import XCTest
@testable import BrainBuddy

final class TextAnalysisTests: XCTestCase {
    func testTitleUsesTheFirstLine() {
        let title = TextAnalysis.suggestedTitle(
            from: "Dentist appointment\nTuesday at four, bring the insurance card.",
            fallback: "Note"
        )
        XCTAssertEqual(title, "Dentist appointment")
    }

    func testTitleSkipsLeadingBlankLines() {
        let title = TextAnalysis.suggestedTitle(from: "\n\n  Grocery list  \nmilk", fallback: "Note")
        XCTAssertEqual(title, "Grocery list")
    }

    func testLongFirstLineIsTruncatedOnAWordBoundary() {
        let long = String(repeating: "wander ", count: 40)
        let title = TextAnalysis.suggestedTitle(from: long, fallback: "Note")
        XCTAssertLessThanOrEqual(title.count, 71)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.hasSuffix(" …"))
    }

    func testEmptyTextFallsBackToTheProvidedTitle() {
        XCTAssertEqual(TextAnalysis.suggestedTitle(from: "   \n ", fallback: "Voice note"), "Voice note")
    }

    func testKeywordsAreExtractedAndBounded() {
        let keywords = TextAnalysis.keywords(
            from: "Dentist appointment on Tuesday with Doctor Alvarez about the crown replacement.",
            limit: 5
        )
        XCTAssertLessThanOrEqual(keywords.count, 5)
        XCTAssertFalse(keywords.isEmpty)
        XCTAssertFalse(keywords.contains("the"))
    }

    func testKeywordsNeverEmptyForNonTriviaText() {
        // Even when the linguistic tagger finds no nouns, frequency fallback
        // must still yield something indexable.
        XCTAssertFalse(TextAnalysis.keywords(from: "zzzq wxyv zzzq").isEmpty)
    }

    func testHashtagsAreNormalizedAndDeduplicated() {
        let tags = TextAnalysis.hashtags(in: "Call the plumber #Home #home #urgent")
        XCTAssertEqual(tags, ["home", "urgent"])
    }

    func testHashtagsIgnoreBareHashes() {
        XCTAssertTrue(TextAnalysis.hashtags(in: "issue # 42 and #").isEmpty)
    }
}
