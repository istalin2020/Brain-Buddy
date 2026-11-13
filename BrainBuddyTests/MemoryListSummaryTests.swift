import XCTest
@testable import BrainBuddy

/// A row shows a heading and, under it, the key summary. These pin down the one
/// rule that makes that readable: never say the same thing twice.
final class MemoryListSummaryTests: XCTestCase {
    func testAShortNoteWhoseTitleIsTheWholeNoteShowsNoSummary() {
        let item = MemoryItem(title: "Call the dentist", text: "Call the dentist")
        XCTAssertEqual(item.listSummary, "")
    }

    func testAnUntitledShortNoteShowsNoSummary() {
        // The derived title is the opening of the body, so the body underneath
        // would be the same sentence again.
        let item = MemoryItem(text: "Pick up the parcel from the depot")
        XCTAssertEqual(item.listSummary, "")
    }

    func testALongerNoteShowsWhatTheHeadingLeftOut() {
        let item = MemoryItem(
            title: "Roof survey",
            text: "Roof survey booked for Thursday at nine, access through the side gate"
        )

        XCTAssertFalse(item.listSummary.isEmpty)
        XCTAssertFalse(
            item.listSummary.lowercased().hasPrefix("roof survey"),
            "The heading should not be repeated: \(item.listSummary)"
        )
        XCTAssertTrue(item.listSummary.contains("Thursday"))
    }

    func testASummaryUnrelatedToTheTitleIsShownWhole() {
        let item = MemoryItem(title: "Site call", text: "", kind: .voice)
        item.summary = DiscussionSummarizer.Summary(
            topics: ["Tower"],
            keyPoints: ["Cladding sign-off moves to the twelfth"],
            followUps: []
        ).text

        XCTAssertEqual(item.listSummary, "Cladding sign-off moves to the twelfth")
    }

    func testTheSavedSummaryWinsOverTheRawBody() {
        let item = MemoryItem(
            title: "Site call",
            text: "So yeah I mean the thing is we talked about a lot of stuff today",
            kind: .voice
        )
        item.summary = DiscussionSummarizer.Summary(
            topics: [],
            keyPoints: ["Cladding sign-off moves to the twelfth"],
            followUps: []
        ).text

        XCTAssertEqual(item.listSummary, "Cladding sign-off moves to the twelfth")
    }

    func testALongSummaryIsClippedOnAWordBoundary() {
        let item = MemoryItem(
            title: "Handover",
            text: "Handover " + String(repeating: "detail ", count: 60)
        )

        let summary = item.listSummary
        XCTAssertLessThanOrEqual(summary.count, 151)
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertFalse(summary.contains("  "))
    }
}
