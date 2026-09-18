import XCTest
@testable import BrainBuddy

/// What gets published to the device's own search index is decided in one place,
/// so this is where the rules about it live.
final class SpotlightRecordTests: XCTestCase {
    func testATrashedMemoryIsNeverPublished() {
        let item = MemoryItem(title: "Old note", text: "Something", kind: .note)
        item.isTrashed = true
        XCTAssertNil(SpotlightRecord(item))
    }

    func testAnEmptyMemoryIsNeverPublished() {
        // A recording that failed to transcribe would otherwise put a blank row
        // in the system's results.
        XCTAssertNil(SpotlightRecord(MemoryItem(kind: .voice)))
    }

    func testTitleAndSummaryComeFromTheMemory() throws {
        let item = MemoryItem(
            title: "Roof survey",
            text: "Booked for Thursday\nAccess through the side gate",
            kind: .note
        )

        let record = try XCTUnwrap(SpotlightRecord(item))
        XCTAssertEqual(record.title, "Roof survey")
        // Newlines collapsed: the index shows one line of description.
        XCTAssertEqual(record.summary, "Booked for Thursday Access through the side gate")
    }

    func testASavedSummaryIsPreferredOverTheRawTranscript() throws {
        let item = MemoryItem(title: "Site call", text: "So yeah um anyway", kind: .voice)
        item.summary = "Key points\n• Cladding sign-off moves to the twelfth"

        let record = try XCTUnwrap(SpotlightRecord(item))
        XCTAssertTrue(record.summary.contains("Cladding sign-off"))
    }

    func testALongBodyIsClippedOnAWordBoundary() throws {
        let item = MemoryItem(
            title: "Handover",
            text: String(repeating: "detail ", count: 200),
            kind: .note
        )

        let record = try XCTUnwrap(SpotlightRecord(item))
        XCTAssertLessThanOrEqual(record.summary.count, SpotlightRecord.summaryLimit + 1)
        XCTAssertTrue(record.summary.hasSuffix("…"))
    }

    func testTagsLeadTheKeywords() throws {
        let item = MemoryItem(title: "Invoice", text: "Chase the invoice", kind: .note)
        item.keywordIndex = "invoice chase"
        item.tags = [MemoryTag(name: "admin")]

        let record = try XCTUnwrap(SpotlightRecord(item))
        XCTAssertEqual(record.keywords.first, "admin")
        XCTAssertTrue(record.keywords.contains("invoice"))
        XCTAssertLessThanOrEqual(record.keywords.count, SpotlightRecord.keywordLimit)
    }

    func testAnUnrelatedActivityIsNotMistakenForASpotlightTap() {
        XCTAssertNil(SpotlightIndexer.memoryIdentifier(from: NSUserActivity(activityType: "com.example.other")))
    }
}
