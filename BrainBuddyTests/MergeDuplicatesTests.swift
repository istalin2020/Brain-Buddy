import SwiftData
import XCTest
@testable import BrainBuddy

/// Copies that got into the library before the app checked for them. Runs
/// against an in-memory store, so it exercises the real fetch-and-trash path
/// without iCloud.
@MainActor
final class MergeDuplicatesTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var ingest: IngestService!

    private let message = """
    Transaction with reference id 732379459 processed successfully.
    Transaction Number: LFT26253286VPSCP From: 0435XXXXXX
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([MemoryItem.self, MemoryAttachment.self, MemoryTag.self, BriefEntry.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        ingest = IngestService()
    }

    override func tearDown() {
        ingest = nil
        context = nil
        container = nil
        super.tearDown()
    }

    /// Saved by an earlier build: no fingerprint on it.
    @discardableResult
    private func insert(_ text: String, daysAgo: Int = 0, kind: MemoryKind = .note) -> MemoryItem {
        let item = MemoryItem(text: text, kind: kind)
        item.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        context.insert(item)
        try? context.save()
        return item
    }

    private func live() -> [MemoryItem] {
        ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []).filter { !$0.isTrashed }
    }

    func testTheSameTextSavedTwiceBecomesOne() throws {
        let original = insert(message, daysAgo: 3)
        insert(message, daysAgo: 1)
        insert(message)

        XCTAssertEqual(ingest.mergeDuplicates(in: context), 2)

        let remaining = live()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.identifier, original.identifier, "The oldest copy is kept")
    }

    /// To the trash, not gone: a wrong guess costs a tap, not a document.
    func testCopiesGoToTheTrashRatherThanBeingDeleted() throws {
        insert(message, daysAgo: 1)
        insert(message)
        ingest.mergeDuplicates(in: context)

        let all = try context.fetch(FetchDescriptor<MemoryItem>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.isTrashed).count, 1)
    }

    func testDifferentCapturesAreLeftAlone() {
        insert(message, daysAgo: 1)
        insert(message.replacingOccurrences(of: "732379459", with: "732379348"))

        XCTAssertEqual(ingest.mergeDuplicates(in: context), 0)
        XCTAssertEqual(live().count, 2)
    }

    /// Formatting is not content: the same message, shouted, is the same message.
    func testFormattingDifferencesStillMerge() {
        insert(message, daysAgo: 1)
        insert("  TRANSACTION with reference id 732379459   PROCESSED successfully!\n\n"
               + "transaction number: LFT26253286VPSCP from: 0435XXXXXX  ")

        XCTAssertEqual(ingest.mergeDuplicates(in: context), 1)
    }

    /// A scrap of text is not enough to call two things the same.
    func testShortNotesAreNeverMerged() {
        insert("Hi there", daysAgo: 1)
        insert("Hi there")

        XCTAssertEqual(ingest.mergeDuplicates(in: context), 0)
        XCTAssertEqual(live().count, 2)
    }

    /// What the newer copy had — a summary you saved — moves to the one that
    /// stays, so nothing you did is lost with the copy.
    func testASavedSummaryOnTheCopyMovesToTheOriginal() throws {
        let original = insert(message, daysAgo: 2)
        let copy = insert(message)
        copy.summary = "The transfer went through."
        copy.summaryIsAutomatic = false
        try context.save()

        ingest.mergeDuplicates(in: context)

        XCTAssertEqual(original.summary, "The transfer went through.")
        XCTAssertFalse(original.summaryIsAutomatic)
    }

    /// The pass fingerprints what it reads, so the next capture's duplicate
    /// check has something to compare against.
    func testItFingerprintsWhatItReads() {
        let item = insert(message)
        XCTAssertTrue(item.contentFingerprint.isEmpty)

        ingest.mergeDuplicates(in: context)

        XCTAssertFalse(item.contentFingerprint.isEmpty)
    }

    func testAnEmptyLibraryIsFine() {
        XCTAssertEqual(ingest.mergeDuplicates(in: context), 0)
    }
}
