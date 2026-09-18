import XCTest
@testable import BrainBuddy

/// Whether a recognizer result extends the current utterance or replaces it.
///
/// This decides when already-dictated text gets banked, and getting it wrong is
/// what made a pause erase everything said before it.
final class DictationContinuityTests: XCTestCase {
    func testGrowingTranscriptContinues() {
        XCTAssertTrue(SpeechTranscriber.continues("next week meeting on", from: "next week meeting"))
        XCTAssertTrue(SpeechTranscriber.continues("next week meeting with the team", from: "next week"))
    }

    /// The recognizer revises its own tail as it hears more, and that must not
    /// look like a new utterance.
    func testTailRevisionsContinue() {
        XCTAssertTrue(SpeechTranscriber.continues("I want to buy 2", from: "I want to by two"))
        XCTAssertTrue(SpeechTranscriber.continues("send the drawing", from: "send the drawings"))
    }

    func testPunctuationAndCasingDoNotBreakContinuity() {
        XCTAssertTrue(SpeechTranscriber.continues("Next week meeting.", from: "next week meeting"))
    }

    /// The reported bug: a pause, then a fresh transcript for the same task.
    func testAnUnrelatedTranscriptIsANewUtterance() {
        XCTAssertFalse(
            SpeechTranscriber.continues("order the gift", from: "next week meeting on Tuesday"),
            "a different opening word means a different utterance"
        )
    }

    func testACollapsedTranscriptIsANewUtterance() {
        XCTAssertFalse(SpeechTranscriber.continues("hello", from: "next week meeting on Tuesday"))
        XCTAssertFalse(SpeechTranscriber.continues("", from: "next week meeting"))
    }

    /// A materially shorter transcript is a restart even when it happens to share
    /// its first word.
    func testASharedFirstWordIsNotEnoughWhenMostOfItIsGone() {
        XCTAssertFalse(
            SpeechTranscriber.continues("next", from: "next week meeting on Tuesday afternoon")
        )
    }

    /// Nothing to bank yet: the first result of a pass always continues.
    func testTheFirstResultOfAPassContinues() {
        XCTAssertTrue(SpeechTranscriber.continues("anything at all", from: ""))
        XCTAssertTrue(SpeechTranscriber.continues("anything at all", from: "   "))
    }
}
