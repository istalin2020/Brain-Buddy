import XCTest
@testable import BrainBuddy

/// What a row on Today says, and where an edit to it goes. The reported case:
/// a note headed "Doctor Wilson on TV 29th Sep" whose row on Today read "Took
/// video record… they will put on TV", and editing one never touched the other.
final class BriefHeadingTests: XCTestCase {
    private let note = UUID()
    private let otherNote = UUID()
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func line(_ id: UUID = UUID(), source: UUID?, daysLater: Int = 0, sortIndex: Int) -> BriefHeading.Line {
        BriefHeading.Line(
            id: id,
            source: source,
            day: day.addingTimeInterval(Double(daysLater) * 86_400),
            sortIndex: sortIndex
        )
    }

    // MARK: - Which row is the heading

    func testTheFirstLineANoteProducedIsItsMainRow() {
        let first = line(source: note, sortIndex: 3)
        let second = line(source: note, sortIndex: 7)
        let third = line(source: note, daysLater: 1, sortIndex: 0)

        let main = BriefHeading.mainLines(among: [third, second, first])
        XCTAssertTrue(main.contains(first.id))
        XCTAssertFalse(main.contains(second.id))
        XCTAssertFalse(main.contains(third.id), "an earlier day beats a lower index")
    }

    func testEveryNoteHasItsOwnMainRow() {
        let a = line(source: note, sortIndex: 0)
        let b = line(source: otherNote, sortIndex: 1)
        XCTAssertEqual(BriefHeading.mainLines(among: [a, b]), [a.id, b.id])
    }

    func testALineFromNoNoteIsNeverAHeading() {
        XCTAssertTrue(BriefHeading.mainLines(among: [line(source: nil, sortIndex: 0)]).isEmpty)
    }

    // MARK: - What the row says

    /// The reported case: the main row shows the note's heading.
    func testTheMainRowShowsTheNotesHeading() {
        XCTAssertEqual(
            BriefHeading.text(
                userText: "",
                subject: "Took video record… they will put on TV",
                isMainLine: true,
                noteTitle: "Doctor Wilson on TV 29th Sep",
                titleIsPlaceholder: false
            ),
            "Doctor Wilson on TV 29th Sep"
        )
    }

    /// Any other row from the same note is its own point.
    func testAnotherRowKeepsItsOwnLine() {
        XCTAssertEqual(
            BriefHeading.text(
                userText: "",
                subject: "Took video record… they will put on TV",
                isMainLine: false,
                noteTitle: "Doctor Wilson on TV 29th Sep",
                titleIsPlaceholder: false
            ),
            "Took video record… they will put on TV"
        )
    }

    /// "Voice note · 12 Sep" is not a heading; the quote says more.
    func testAPlaceholderTitleIsNotShown() {
        XCTAssertEqual(
            BriefHeading.text(
                userText: "",
                subject: "Close the PCH approval this week",
                isMainLine: true,
                noteTitle: "Voice note · 12 Sep 2026",
                titleIsPlaceholder: true
            ),
            "Close the PCH approval this week"
        )
    }

    /// Your wording beats everything, including the heading.
    func testYourWordingWins() {
        XCTAssertEqual(
            BriefHeading.text(
                userText: "Watch Doctor Wilson on Sathyam TV",
                subject: "Took video record… they will put on TV",
                isMainLine: true,
                noteTitle: "Doctor Wilson on TV 29th Sep",
                titleIsPlaceholder: false
            ),
            "Watch Doctor Wilson on Sathyam TV"
        )
    }

    // MARK: - Where an edit goes

    func testEditingTheMainRowRenamesTheNote() {
        XCTAssertTrue(BriefHeading.editsNoteTitle(isMainLine: true, userText: ""))
    }

    func testEditingAnyOtherRowRewordsOnlyThatRow() {
        XCTAssertFalse(BriefHeading.editsNoteTitle(isMainLine: false, userText: ""))
    }

    /// A row you already reworded before it became the main row: it is your
    /// wording you are correcting, not the note's name.
    func testARowWithYourWordingKeepsIt() {
        XCTAssertFalse(BriefHeading.editsNoteTitle(isMainLine: true, userText: "My own words"))
    }

    // MARK: - Placeholder titles

    func testPlaceholderTitlesAreRecognised() {
        let labels = ["Voice", "Voice note"]
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "", source: "", kindLabels: labels))
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "Untitled", source: "", kindLabels: labels))
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "Voice note · 12 Sep 2026 at 3:04 PM", source: "Voice note", kindLabels: labels))
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "Scan", source: "Scan", kindLabels: ["Document"]))
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "IMG_2041.jpg", source: "Photo", kindLabels: ["Image"]))
        XCTAssertTrue(BriefHeading.isPlaceholder(title: "report-final.pdf", source: "report-final.pdf", kindLabels: ["Document"]))
    }

    func testARealHeadingIsNotAPlaceholder() {
        XCTAssertFalse(BriefHeading.isPlaceholder(title: "Doctor Wilson on TV 29th Sep", source: "Photo", kindLabels: ["Image"]))
        XCTAssertFalse(BriefHeading.isPlaceholder(title: "Purchase a black belt", source: "", kindLabels: ["Note"]))
    }
}
