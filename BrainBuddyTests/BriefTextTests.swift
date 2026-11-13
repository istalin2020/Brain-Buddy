import XCTest
@testable import BrainBuddy

/// The brief quotes you verbatim. These pin down the line between *verbatim*
/// and *unpresented*: punctuation debris is tidied, words never are.
final class BriefTextTests: XCTestCase {
    func testDoubledFullStopsBecomeOneEllipsis() {
        XCTAssertEqual(
            BriefText.clean("Took video record ..they will put on TV"),
            "Took video record… they will put on TV"
        )
    }

    func testASpaceBeforePunctuationIsClosedUp() {
        XCTAssertEqual(
            BriefText.clean("Call the office , then send the file"),
            "Call the office, then send the file"
        )
    }

    func testRepeatedTerminatorsAreReducedToOne() {
        XCTAssertEqual(BriefText.clean("are we still on?!?!"), "Are we still on?")
    }

    func testTheFirstLetterIsCapitalizedAndAcronymsAreLeftAlone() {
        XCTAssertEqual(
            BriefText.clean("send the EOT submission to PCH"),
            "Send the EOT submission to PCH"
        )
    }

    func testALineNeverEndsOnADanglingConnective() {
        XCTAssertEqual(
            BriefText.clean("Send the drawings to the consultant with"),
            "Send the drawings to the consultant"
        )
    }

    func testTrimmingNeverEmptiesTheLine() {
        // Every word here is one that could be trimmed as dangling. Something
        // has to survive.
        XCTAssertFalse(BriefText.clean("and to with").isEmpty)
    }

    func testWordsAreNeverReorderedOrDropped() {
        let line = "Al Qersh confirmed to do the sparing work with 60,000 Omani rial"
        XCTAssertEqual(BriefText.clean(line), line)
    }

    // MARK: - Substance

    /// The row that made this necessary: a date, a filler word and a clock
    /// reading, filed under Key points.
    func testATimestampCarriesNoSubstance() {
        XCTAssertFalse(BriefText.carriesSubstance("29th September mostly 11:50 AM"))
    }

    func testABareTimeCarriesNoSubstance() {
        XCTAssertFalse(BriefText.carriesSubstance("2 - 2.54 at 2:00 PM"))
    }

    func testAShortRealTaskCarriesSubstance() {
        XCTAssertTrue(BriefText.carriesSubstance("EOT submission"))
        XCTAssertTrue(BriefText.carriesSubstance("Prepare PPT for Hackathon"))
    }

    func testADatedButRealLineCarriesSubstance() {
        XCTAssertTrue(BriefText.carriesSubstance("Doctor Wilson on TV 29th September"))
    }
}
