import XCTest
@testable import BrainBuddy

/// The summarizer was written for transcripts. These pin down what it has to do
/// with the other thing people feed it: a document that arrives already
/// bulleted, labelled, and saying the same thing three times.
final class SummaryQualityTests: XCTestCase {
    private let invitation = """
    Your AI Hackathon Jury Round — Wed, 9 Sep, 11:30 AM | Be Ready to Present
    • Congratulations on reaching the jury round of the hackathon
    • The next step is presenting your idea to the jury panel
    Date & Time:
    Wednesday, 9 September, 11:30 AM - 12:30 PM IST
    Jury Panel:
    Ganesh Srinivasan, Raman Kapil, Devendra Patodi
    How the session will run:
    We will bring you into the call one by one within the session, so please join on time
    Your jury round is scheduled for the slot above
    """

    // MARK: - Preparing document text

    func testListMarkersAreStripped() {
        let prepared = DiscussionSummarizer.prepared("• First point\n- Second point\n1. Third point")
        XCTAssertEqual(prepared, "First point\nSecond point\nThird point")
    }

    /// "Date & Time:" is not a key point. "Date & Time: Wednesday…" is.
    func testALabelIsJoinedToItsValue() {
        let prepared = DiscussionSummarizer.prepared("Date & Time:\nWednesday, 9 September")
        XCTAssertEqual(prepared, "Date & Time: Wednesday, 9 September")
    }

    func testALabelWithNothingUnderItIsDropped() {
        let prepared = DiscussionSummarizer.prepared("Real content here\nJury Panel:")
        XCTAssertEqual(prepared, "Real content here")
    }

    func testASummaryOfABulletedDocumentIsNotDoubleBulleted() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(invitation))
        for line in summary.keyPoints + summary.followUps {
            XCTAssertFalse(line.hasPrefix("•"), "got “\(line)”")
            XCTAssertFalse(line.hasPrefix("-"), "got “\(line)”")
        }
    }

    // MARK: - Saying it once

    func testARestatementDoesNotSpendASecondSlot() {
        // The shorter line is almost entirely inside the longer one.
        let scheduled = Set(Tokenizer.tokens(in: "Your jury round is scheduled"))
        let detailed = Set(Tokenizer.tokens(in: "Your AI Hackathon Jury Round — Wed, 9 Sep, 11:30 AM"))
        XCTAssertTrue(DiscussionSummarizer.restates(scheduled, detailed))
    }

    func testTwoGenuinelyDifferentPointsBothSurvive() {
        let first = Set(Tokenizer.tokens(in: "Send the revised drawings to the consultant"))
        let second = Set(Tokenizer.tokens(in: "Book the roof survey for Thursday"))
        XCTAssertFalse(DiscussionSummarizer.restates(first, second))
    }

    func testOneSharedWordIsNotARestatement() {
        let first = Set(Tokenizer.tokens(in: "Jury feedback arrives Friday"))
        let second = Set(Tokenizer.tokens(in: "Jury panel confirmed today"))
        XCTAssertFalse(DiscussionSummarizer.restates(first, second))
    }

    func testTheSummaryDoesNotRepeatItself() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(invitation))
        let lines = summary.keyPoints + summary.followUps

        for (index, line) in lines.enumerated() {
            for other in lines[(index + 1)...] {
                XCTAssertFalse(
                    DiscussionSummarizer.restates(
                        Set(Tokenizer.tokens(in: line)),
                        Set(Tokenizer.tokens(in: other))
                    ),
                    "“\(line)” restates “\(other)”"
                )
            }
        }
    }

    // MARK: - Subjects

    /// "Topics: Jury, Sep, idea, minutes" — half of that was a date and a filler
    /// word. A subject is what the thing was about.
    func testADateIsNotASubject() {
        let topics = DiscussionSummarizer.topics(in: invitation, limit: 6).map { $0.lowercased() }
        XCTAssertFalse(topics.contains("sep"))
        XCTAssertFalse(topics.contains("september"))
        XCTAssertFalse(topics.contains("wednesday"))
        XCTAssertFalse(topics.isEmpty, "A document this long has subjects in it")
        XCTAssertFalse(
            topics.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil },
            "got \(topics)"
        )
    }
}
