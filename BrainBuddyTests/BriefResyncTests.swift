import SwiftData
import XCTest
@testable import BrainBuddy

/// A brief is not a snapshot. Correct a figure in a note and the line quoting
/// it has to say the new figure — a stale quote you can tick off is worse than
/// no line at all.
///
/// Runs against an in-memory store, so it exercises the real fetch-and-update
/// path without iCloud.
@MainActor
final class BriefResyncTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var brief: BriefService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([MemoryItem.self, MemoryAttachment.self, MemoryTag.self, BriefEntry.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        brief = BriefService()
        UserDefaults.standard.removeObject(forKey: "brief.lastBuiltAt")
    }

    override func tearDown() {
        brief = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func insert(_ text: String) -> MemoryItem {
        let item = MemoryItem(text: text, kind: .note)
        item.title = TextAnalysis.suggestedTitle(from: text, fallback: "Note")
        context.insert(item)
        try? context.save()
        return item
    }

    private func entries() -> [BriefEntry] {
        (try? context.fetch(FetchDescriptor<BriefEntry>())) ?? []
    }

    /// What `AppServices.applyEdit` does after an edit: reword what exists, then
    /// pick up anything the edit newly created.
    private func applyEdit(to item: MemoryItem) {
        brief.resync(item, in: context)
        brief.generate(in: context)
    }

    func testEditingANoteRewordsTheLineItProduced() throws {
        let item = insert("Al Qersh confirmed to do the sparing work with 54,000 Omani rial")
        XCTAssertGreaterThan(brief.generate(in: context), 0)

        let before = try XCTUnwrap(entries().first)
        XCTAssertTrue(before.text.contains("54,000"))
        let identifier = before.identifier

        item.text = "Al Qersh confirmed to do the sparing work with 60,000 Omani rial"
        item.touch()
        XCTAssertEqual(brief.resync(item, in: context), 1)

        // The same row, reworded — not a second row, and not the old one left
        // sitting there.
        let after = entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.identifier, identifier)
        XCTAssertTrue(try XCTUnwrap(after.first).text.contains("60,000"))
    }

    /// Closing something is a decision. Rewording the note it came from must not
    /// quietly reopen it.
    func testAClosedLineStaysClosedWhenItsNoteIsEdited() throws {
        let item = insert("Chase the invoice for 54,000 Omani rial")
        brief.generate(in: context)
        let entry = try XCTUnwrap(entries().first)
        brief.close(entry, in: context)

        item.text = "Chase the invoice for 60,000 Omani rial"
        item.touch()
        brief.resync(item, in: context)

        let after = try XCTUnwrap(entries().first)
        XCTAssertTrue(after.isClosed)
        XCTAssertNotNil(after.closedAt)
        XCTAssertTrue(after.text.contains("60,000"))
    }

    /// A rewrite is not a rewording: the old line goes and the new one arrives,
    /// rather than the row being force-fitted to text that no longer resembles
    /// it. (No dates in the text on purpose — a weekday would make this a
    /// schedule item on one day of the week and a task on the other six.)
    func testRewritingANoteEntirelyRetiresTheOldLine() throws {
        let item = insert("Book the roof survey and send the deposit to the surveyor")
        brief.generate(in: context)
        XCTAssertEqual(entries().count, 1, "A short typed note is one task, not one per sentence")

        item.text = "Ignore the invoice from the letting agency"
        item.touch()
        applyEdit(to: item)

        let after = entries()
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(try XCTUnwrap(after.first).text.contains("letting agency"))
    }

    /// The guard that keeps this from doing damage: if a note yields nothing the
    /// builder recognizes, its lines are left alone rather than deleted.
    func testALineIsNeverDeletedWhenItsNoteYieldsNothing() throws {
        let item = insert("Prepare the PPT for the hackathon")
        brief.generate(in: context)
        XCTAssertEqual(entries().count, 1)

        item.text = ""
        item.touch()
        brief.resync(item, in: context)

        XCTAssertEqual(entries().count, 1, "Losing a task you were relying on is worse than stale wording")
    }

    /// Refresh has to catch edits made anywhere — including on another device,
    /// where this app never saw the edit happen.
    func testRefreshBringsEditedLinesUpToDate() throws {
        let item = insert("Send the drawings for 54,000 Omani rial")
        brief.generate(in: context)

        item.text = "Send the drawings for 60,000 Omani rial"
        item.touch()

        let added = brief.generate(in: context)
        XCTAssertEqual(added, 0, "Rewording is an update, not an addition")
        XCTAssertEqual(brief.updatedCount, 1)
        XCTAssertEqual(entries().count, 1)
        XCTAssertTrue(try XCTUnwrap(entries().first).text.contains("60,000"))
    }

    /// The reason the fix didn't reach the screen the first time: today's brief
    /// had already been built, so opening the app skipped the whole pass and the
    /// row went on quoting the old figure until Refresh was pressed by hand.
    func testAlreadyBuiltTodayStillCatchesUpOnOpen() throws {
        let item = insert("Al Qersh confirmed to do the sparing work with 54,000 Omani rial")
        brief.generate(in: context)

        item.text = "Al Qersh confirmed to do the sparing work with 60,000 Omani rial"
        item.touch()

        // What TodayView runs when it appears, and RootView on every return to
        // the foreground.
        XCTAssertEqual(brief.generateIfNeeded(in: context), 0, "Nothing new to propose")
        XCTAssertEqual(brief.updatedCount, 1)
        XCTAssertTrue(try XCTUnwrap(entries().first).text.contains("60,000"))
    }

    /// Timestamps are the fast path, not the truth — an edit merged from another
    /// device, or a line made by an older build, can leave `updatedAt` no newer
    /// than the line. The words themselves settle it.
    func testAStaleLineIsCaughtWhenTheTimestampDidNotMove() throws {
        let item = insert("Al Qersh confirmed to do the sparing work with 54,000 Omani rial")
        brief.generate(in: context)

        // Deliberately no touch(): updatedAt stays older than the line.
        item.text = "Al Qersh confirmed to do the sparing work with 60,000 Omani rial"
        XCTAssertLessThanOrEqual(item.updatedAt, try XCTUnwrap(entries().first).createdAt)

        XCTAssertEqual(brief.reconcileAll(in: context), 1)
        XCTAssertTrue(try XCTUnwrap(entries().first).text.contains("60,000"))

        // And it settles: a line that matches its note is not "updated" again on
        // every pass.
        XCTAssertEqual(brief.reconcileAll(in: context), 0)
    }

    /// Tidying punctuation must not read as an edit, or every pass would report
    /// updates forever.
    func testTidyingSettlesInsteadOfLooping() throws {
        _ = insert("Took video record ..they will put on TV")
        brief.generate(in: context)
        XCTAssertTrue(try XCTUnwrap(entries().first).text.contains("…"))

        XCTAssertEqual(brief.reconcileAll(in: context), 0)
    }

    /// One scanned invitation used to produce five rows. `BriefBuilder` stops
    /// that happening again; this is the clean-up for briefs built before it.
    func testDuplicateRowsFromOneMemoryCollapseOnOpen() throws {
        let item = insert("Your AI Hackathon jury round is on the tenth. You have to present your idea.")
        let day = Calendar.current.startOfDay(for: Date())

        for (index, text) in ["How the session will run", "Your jury round is scheduled"].enumerated() {
            context.insert(
                BriefEntry(
                    day: day,
                    kind: .point,
                    text: text,
                    sourceIdentifier: item.identifier,
                    sortIndex: index
                )
            )
        }
        try context.save()
        XCTAssertEqual(entries().count, 2)

        brief.reconcileAll(in: context)

        let after = entries()
        XCTAssertEqual(after.count, 1, "One memory, one open line")
        XCTAssertEqual(after.first?.text, "How the session will run", "The first one is kept")
    }

    /// Ticking something off is a decision, and the record of it is not a
    /// duplicate.
    func testAClosedLineIsNeverCollapsedAway() throws {
        let item = insert("Your AI Hackathon jury round is on the tenth. You have to present your idea.")
        let day = Calendar.current.startOfDay(for: Date())

        let closed = BriefEntry(day: day, kind: .point, text: "Already dealt with", sourceIdentifier: item.identifier, sortIndex: 0)
        closed.isClosed = true
        closed.closedAt = Date()
        context.insert(closed)
        context.insert(
            BriefEntry(day: day, kind: .point, text: "Still open", sourceIdentifier: item.identifier, sortIndex: 1)
        )
        try context.save()

        brief.reconcileAll(in: context)
        XCTAssertEqual(entries().count, 2)
    }

    /// A summary the app wrote from a scan is on the same footing as the OCR it
    /// came from: readable, and not something you committed to.
    func testAnAutomaticSummaryStaysOutOfTheBrief() throws {
        let item = MemoryItem(kind: .document, source: "Scan")
        item.extractedText = "Minutes of the site meeting, printed and scanned."
        item.summary = DiscussionSummarizer.Summary(
            topics: [],
            keyPoints: [],
            followUps: ["You have to submit the shutdown plan"]
        ).text
        item.summaryIsAutomatic = true
        context.insert(item)
        try context.save()

        XCTAssertEqual(brief.generate(in: context), 0, "Nobody agreed to this yet")

        // Pressing "Use this in my brief" is what changes that.
        item.summaryIsAutomatic = false
        item.touch()
        XCTAssertGreaterThan(brief.generate(in: context), 0)
    }

    func testAnUntouchedNoteIsLeftCompletelyAlone() throws {
        _ = insert("Prepare the PPT for the hackathon")
        brief.generate(in: context)
        let before = try XCTUnwrap(entries().first).text

        let added = brief.generate(in: context)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(brief.updatedCount, 0)
        XCTAssertEqual(try XCTUnwrap(entries().first).text, before)
    }
}
