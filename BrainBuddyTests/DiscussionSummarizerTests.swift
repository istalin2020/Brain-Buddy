import XCTest
@testable import BrainBuddy

final class DiscussionSummarizerTests: XCTestCase {
    /// A transcript with a clear subject, some restatement, and two commitments.
    private let discussion = """
    So the main thing today is the excess tower material sitting at the yard. \
    We still need the approval from PCH before anything moves. \
    The tower material has been there since March and it is costing us rent. \
    Right, the material is just sitting there costing rent every week. \
    I have to close the excess tower material approval from PCH this week. \
    Someone should also check whether the invoice from the yard was ever paid. \
    Okay. Yeah. Fine.
    """

    // MARK: - Refusing to pad

    func testShortTextIsNotSummarized() {
        XCTAssertNil(DiscussionSummarizer.summarize("Call the dentist tomorrow."))
    }

    func testEmptyTextIsNotSummarized() {
        XCTAssertNil(DiscussionSummarizer.summarize("   \n  "))
    }

    /// Many words but only one sentence: there is nothing to select between, so a
    /// "summary" would just be the input with a bullet in front of it.
    func testSingleSentenceIsNotSummarized() {
        let oneSentence = String(repeating: "the yard material approval rent invoice ", count: 8)
        XCTAssertNil(DiscussionSummarizer.summarize(oneSentence))
    }

    // MARK: - Extractive guarantee

    /// The property that matters most: every line is something that was actually
    /// said. If this ever fails, the summarizer has started inventing.
    func testEveryLineIsQuotedFromTheTranscript() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        let sentences = Tokenizer.sentences(in: discussion)
        for line in summary.keyPoints + summary.followUps {
            XCTAssertTrue(
                sentences.contains(line),
                "“\(line)” is not a sentence from the transcript"
            )
        }
    }

    /// Speech transcribed without punctuation arrives as one enormous "sentence".
    /// Quoting it whole would reproduce the transcript under a Summary heading.
    func testALineIsClippedRatherThanQuotingAWholeMonologue() throws {
        let runOn = (1...40).map { "point number \($0) about the yard and the material" }.joined(separator: " ")
        let transcript = "\(runOn). And separately the invoice was never paid at all."

        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(transcript))
        for line in summary.keyPoints + summary.followUps {
            XCTAssertLessThanOrEqual(
                line.count,
                DiscussionSummarizer.maximumLineLength + 1,
                "a summary line ran to \(line.count) characters"
            )
        }
    }

    func testSummaryIsShorterThanTheTranscript() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        XCTAssertLessThan(summary.text.count, discussion.count)
        XCTAssertFalse(summary.isEmpty)
    }

    // MARK: - Ordering and budgets

    func testLinesKeepTranscriptOrder() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        let sentences = Tokenizer.sentences(in: discussion)

        for lines in [summary.keyPoints, summary.followUps] {
            let positions = lines.compactMap { sentences.firstIndex(of: $0) }
            XCTAssertEqual(positions, positions.sorted(), "a summary should read in the order it was said")
        }
    }

    func testBudgetsAreRespected() throws {
        let summary = try XCTUnwrap(
            DiscussionSummarizer.summarize(discussion, maxKeyPoints: 2, maxFollowUps: 1)
        )
        XCTAssertLessThanOrEqual(summary.keyPoints.count, 2)
        XCTAssertLessThanOrEqual(summary.followUps.count, 1)
    }

    /// A sentence is either a key point or a follow-up, never printed twice.
    func testKeyPointsAndFollowUpsDoNotOverlap() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        let overlap = Set(summary.keyPoints).intersection(Set(summary.followUps))
        XCTAssertTrue(overlap.isEmpty, "\(overlap) appears under both headings")
    }

    /// People restate themselves constantly when talking; two phrasings of one
    /// point must not spend two of the available slots.
    func testNearDuplicateSentencesAreCollapsed() throws {
        let repetitive = """
        The tower material is costing us rent every week at the yard. \
        The tower material costs rent every week at the yard. \
        We need the PCH approval signed before the material can move. \
        The delivery schedule slipped to the end of the month.
        """
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(repetitive, maxKeyPoints: 4))
        let restatements = summary.keyPoints.filter { $0.contains("rent every week") }
        XCTAssertLessThanOrEqual(restatements.count, 1)
    }

    // MARK: - Commitments

    func testCommitmentCuesAreDetected() {
        XCTAssertTrue(DiscussionSummarizer.isCommitment("I have to close the approval this week"))
        XCTAssertTrue(DiscussionSummarizer.isCommitment("Someone should check the invoice"))
        XCTAssertTrue(DiscussionSummarizer.isCommitment("We'll send it on Monday"))
        XCTAssertTrue(DiscussionSummarizer.isCommitment("Let's keep this a top priority"))
        XCTAssertTrue(DiscussionSummarizer.isCommitment("I'm gonna call the yard"))
    }

    func testPlainStatementsAreNotCommitments() {
        XCTAssertFalse(DiscussionSummarizer.isCommitment("The material has been there since March"))
        XCTAssertFalse(DiscussionSummarizer.isCommitment("It was raining the whole afternoon"))
    }

    /// `will` must not fire inside another word.
    func testCueMatchingIsWordBounded() {
        XCTAssertFalse(DiscussionSummarizer.isCommitment("She was willing to wait"))
        XCTAssertFalse(DiscussionSummarizer.isCommitment("The shoulder of the road was wet"))
    }

    func testCommitmentsSurfaceAsFollowUps() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        XCTAssertFalse(summary.followUps.isEmpty)
        for line in summary.followUps {
            XCTAssertTrue(
                DiscussionSummarizer.isCommitment(line),
                "“\(line)” was filed as a follow-up without a commitment cue"
            )
        }
    }

    // MARK: - Rendering

    func testRenderedTextCarriesEveryLine() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(discussion))
        let rendered = summary.text
        for line in summary.keyPoints + summary.followUps {
            XCTAssertTrue(rendered.contains(line))
        }
        if !summary.keyPoints.isEmpty { XCTAssertTrue(rendered.contains("Key points")) }
        if !summary.followUps.isEmpty { XCTAssertTrue(rendered.contains("Follow-ups")) }
    }

    func testEmptySummaryRendersToNothing() {
        let empty = DiscussionSummarizer.Summary(topics: [], keyPoints: [], followUps: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.text, "")
    }

    // MARK: - Topics

    /// Topics exist to be read, so they keep the speaker's spelling rather than
    /// the stemmed form the search index uses.
    func testTopicsAreNotStemmed() {
        let topics = DiscussionSummarizer.topics(in: discussion)
        XCTAssertFalse(topics.isEmpty)
        for topic in topics {
            XCTAssertTrue(
                discussion.localizedCaseInsensitiveContains(topic),
                "“\(topic)” is not a word from the transcript"
            )
        }
    }

    func testTopicsAreBounded() {
        XCTAssertLessThanOrEqual(DiscussionSummarizer.topics(in: discussion, limit: 2).count, 2)
    }
}
