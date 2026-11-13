import XCTest
@testable import BrainBuddy

/// The reported case: fourteen minutes of meeting came back as 118 words,
/// because only the recognizer's last utterance in each slice was kept.
final class PassCollectorTests: XCTestCase {
    private typealias Word = SpeakerTranscript.Word

    private func timed(_ text: String, from start: TimeInterval) -> [Word] {
        text.split(separator: " ").enumerated().map { index, word in
            Word(text: String(word), start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.35)
        }
    }

    private func untimed(_ text: String) -> [Word] {
        text.split(separator: " ").map { Word(text: String($0), start: 0, end: 0) }
    }

    /// The recognizer starts the second utterance from scratch; both are kept.
    func testEveryUtteranceIsKept() {
        var collector = PassCollector()
        collector.receive(text: "Hello there", words: timed("Hello there", from: 0))
        collector.receive(text: "Hello there how", words: timed("Hello there how", from: 0))
        collector.receive(text: "We need the drawings", words: timed("We need the drawings", from: 3))
        collector.receive(text: "We need the drawings by Friday.", words: timed("We need the drawings by Friday.", from: 3))

        let words = collector.words(duration: 10)
        XCTAssertEqual(words.map(\.text).joined(separator: " "), "Hello there how We need the drawings by Friday.")
        XCTAssertEqual(words[3].start, 3, accuracy: 0.001)
    }

    /// Without timings, utterances share out the slice in order.
    func testUntimedUtterancesAreSpreadInOrder() {
        var collector = PassCollector()
        collector.receive(text: "First pass words", words: untimed("First pass words"))
        collector.receive(text: "Second one here", words: untimed("Second one here"))

        let words = collector.words(duration: 10)
        XCTAssertEqual(words.map(\.text), ["First", "pass", "words", "Second", "one", "here"])
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted())
        XCTAssertEqual(words.last!.start, 10 * 5 / 6, accuracy: 0.01)
    }

    /// Timings counted from each utterance's own start are placed after the last.
    func testRestartedTimingsArePlacedAfterThePreviousUtterance() {
        var collector = PassCollector()
        collector.receive(text: "Alpha beta gamma", words: timed("Alpha beta gamma", from: 0))
        collector.receive(text: "Delta epsilon", words: timed("Delta epsilon", from: 0))

        let words = collector.words(duration: 10)
        XCTAssertEqual(words[3].text, "Delta")
        XCTAssertEqual(words[3].start, 1.45, accuracy: 0.001)
    }

    /// A changed first word is the same utterance, revised — not a second one.
    func testARevisedOpeningIsNotCountedTwice() {
        var collector = PassCollector()
        collector.receive(text: "Sun drawings are late", words: timed("Sun drawings are late", from: 1))
        collector.receive(text: "The drawings are late", words: timed("The drawings are late", from: 1))
        XCTAssertEqual(collector.words(duration: 10).map(\.text).joined(separator: " "), "The drawings are late")
    }
}

final class SpokenSummaryTests: XCTestCase {
    /// From the reported meeting.
    func testFillerRunsSplitRemarksAndRepeatsCollapse() {
        XCTAssertEqual(
            DiscussionSummarizer.spokenClauses(
                "Okay Okay Okay, okay, no problem Survey going on or existing means so construction work will start from maybe by March April Okay, okay, okay Suresh, Suresh, Suresh Phir ki alignment Hai na African"
            ),
            [
                "Survey going on or existing means so construction work will start from maybe by March April",
                "Suresh Phir ki alignment Hai na African"
            ]
        )
        XCTAssertEqual(DiscussionSummarizer.spokenClauses("Yes, yes What reason legal coordinate?"), ["What reason legal coordinate?"])
    }

    /// One "okay" inside a remark is a word, not filler.
    func testAnOrdinaryOkayStays() {
        XCTAssertEqual(
            DiscussionSummarizer.spokenClauses("Is it okay to send the drawings today?"),
            ["Is it okay to send the drawings today?"]
        )
    }

    /// Words of a commitment about the past are not a follow-up.
    func testThePastIsNotAFollowUp() {
        XCTAssertFalse(DiscussionSummarizer.isFollowUp("I will take that 10 years ago"))
        XCTAssertFalse(DiscussionSummarizer.isFollowUp(
            "Because yesterday there was a meeting with ITC so our highest priority only that modification work"
        ))
        XCTAssertTrue(DiscussionSummarizer.isFollowUp("I will send the revised drawings by Thursday"))
    }
}

final class SpeechVocabularyTests: XCTestCase {
    func testNamesAndAcronymsFromYourNotes() {
        let terms = SpeechVocabulary.terms(in: [
            "Give work order to Al Qersh. The PCH approval is pending.",
            "Call Suresh about the Haffaf drawings. Suresh has the PCH file.",
            "Meeting on Monday at 10."
        ])
        XCTAssertEqual(Array(terms.prefix(2)), ["PCH", "Suresh"], "used twice, so first")
        XCTAssertTrue(terms.contains("Qersh"))
        XCTAssertTrue(terms.contains("Haffaf"))
        XCTAssertFalse(terms.contains("The"))
        XCTAssertFalse(terms.contains("Monday"))
        XCTAssertFalse(terms.contains("Give"), "ordinary sentence openers are capitalised too")
    }
}
