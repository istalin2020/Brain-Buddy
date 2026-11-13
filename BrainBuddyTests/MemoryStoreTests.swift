import SwiftData
import XCTest
@testable import BrainBuddy

/// Smoke tests for the SwiftData schema. These run against an in-memory store,
/// so they verify the model graph is valid without touching iCloud.
final class MemoryStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([MemoryItem.self, MemoryAttachment.self, MemoryTag.self, BriefEntry.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testSchemaBuildsAndPersistsAnItem() throws {
        let item = MemoryItem(text: "Dentist on Tuesday", kind: .note)
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MemoryItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.text, "Dentist on Tuesday")
        XCTAssertEqual(fetched.first?.kind, .note)
    }

    func testDeletingAMemoryCascadesToItsAttachments() throws {
        let item = MemoryItem(kind: .voice)
        let attachment = MemoryAttachment(
            filename: "voice.m4a",
            kind: .audio,
            payload: Data([0x01, 0x02]),
            duration: 12
        )
        attachment.memory = item
        context.insert(item)
        context.insert(attachment)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<MemoryAttachment>()).count, 1)

        context.delete(item)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
    }

    func testSearchableTextGathersEveryIndexedField() {
        let item = MemoryItem(text: "typed body", extractedText: "ocr body", kind: .image, source: "receipt.jpg")
        item.summary = "the summarized point"
        XCTAssertTrue(item.searchableText.contains("typed body"))
        XCTAssertTrue(item.searchableText.contains("ocr body"))
        XCTAssertTrue(item.searchableText.contains("receipt.jpg"))
        // A saved summary is the shortest description of a long recording, which
        // makes it the most valuable thing in the index.
        XCTAssertTrue(item.searchableText.contains("the summarized point"))
    }

    func testBriefEntryPersistsAndClosesCleanly() throws {
        let entry = BriefEntry(
            day: Calendar.current.startOfDay(for: Date()),
            kind: .task,
            text: "Close the PCH approval",
            detail: "Site meeting"
        )
        context.insert(entry)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<BriefEntry>()).first)
        XCTAssertFalse(fetched.isClosed)
        XCTAssertEqual(fetched.kind, .task)

        fetched.isClosed = true
        fetched.closedAt = Date()
        try context.save()

        XCTAssertTrue(try XCTUnwrap(try context.fetch(FetchDescriptor<BriefEntry>()).first).isClosed)
    }

    func testDisplayTitleFallsBackToThePreview() {
        let item = MemoryItem(text: "No title but plenty of body text.", kind: .note)
        XCTAssertFalse(item.displayTitle.isEmpty)
        XCTAssertNotEqual(item.displayTitle, "Untitled")
    }

    func testEmbeddingRoundTripsThroughTheStoredBlob() throws {
        let item = MemoryItem(text: "vector", kind: .note)
        item.embedding = [0.25, -0.5, 0.75]
        context.insert(item)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<MemoryItem>()).first)
        let embedding = try XCTUnwrap(fetched.embedding)
        XCTAssertEqual(embedding.count, 3)
        XCTAssertEqual(embedding[1], -0.5, accuracy: 0.0001)
    }

    func testAttachmentSizeIsDerivedFromThePayload() {
        let attachment = MemoryAttachment(filename: "a.jpg", kind: .image, payload: Data(repeating: 0, count: 2048))
        XCTAssertEqual(attachment.byteCount, 2048)
        XCTAssertFalse(attachment.formattedSize.isEmpty)
    }
}
