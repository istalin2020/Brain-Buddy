import XCTest
@testable import BrainBuddy

/// Where a memory lands in the brain. The rules are meant to be explainable to
/// the person using them, so they're pinned down here one at a time.
final class BrainClassifierTests: XCTestCase {
    private func input(
        _ text: String,
        title: String = "",
        tags: [String] = [],
        kind: MemoryKind = .note,
        source: String = "",
        attachments: [String] = []
    ) -> BrainFileInput {
        BrainFileInput(
            id: UUID(),
            title: title.isEmpty ? text : title,
            summary: "",
            text: text,
            tags: tags,
            kind: kind,
            source: source,
            attachmentNames: attachments,
            createdAt: Date()
        )
    }

    // MARK: - Regions

    func testATagYouTypedSettlesIt() {
        // Even though every word here is work vocabulary.
        let file = input("Client invoice and the project deadline", tags: ["family"])
        XCTAssertEqual(BrainClassifier.region(for: file), .family)
    }

    func testAPhotoGoesToTheVisualCortexWhateverItIsAbout() {
        let file = input("Site drawing for the client project", kind: .image)
        XCTAssertEqual(BrainClassifier.region(for: file), .images)
    }

    func testARecordingGoesToTheAuditoryCortex() {
        XCTAssertEqual(BrainClassifier.region(for: input("Anything at all", kind: .voice)), .media)
    }

    func testAVideoAttachmentCountsAsMediaEvenAsADocument() {
        let file = input("Handover walkthrough", kind: .document, attachments: ["walkthrough.MP4"])
        XCTAssertEqual(BrainClassifier.region(for: file), .media)
    }

    func testWorkWordsReachTheFrontalLobe() {
        XCTAssertEqual(
            BrainClassifier.region(for: input("Send the tender drawings to the contractor")),
            .work
        )
    }

    func testFamilyWordsReachTheLimbicCore() {
        XCTAssertEqual(
            BrainClassifier.region(for: input("Pick up my daughter from school")),
            .family
        )
    }

    func testRelativesCountAsFriends() {
        XCTAssertEqual(
            BrainClassifier.region(for: input("Dinner with my cousin before the wedding")),
            .friends
        )
    }

    /// Plurals must not decide anything: both sides go through the same stemmer.
    func testPluralsMatchTheSingularLexicon() {
        XCTAssertEqual(BrainClassifier.region(for: input("Two meetings tomorrow")), .work)
    }

    func testNothingRecognizableGoesToGeneralRatherThanBeingForced() {
        XCTAssertEqual(BrainClassifier.region(for: input("Sourdough starter, day four")), .general)
    }

    func testTheRegionWithMoreEvidenceWins() {
        // One family word, three work words.
        let file = input("Home office: the client contract and the invoice are ready")
        XCTAssertEqual(BrainClassifier.region(for: file), .work)
    }

    // MARK: - Work's rooms

    func testAnAddressMakesItEmail() {
        let file = input("Chase the drawings", source: "priya@contractor.example.com")
        XCTAssertEqual(BrainClassifier.section(for: file), .email)
    }

    func testAReplySubjectMakesItEmail() {
        let file = input("Chase the drawings", title: "Re: tender pack")
        XCTAssertEqual(BrainClassifier.section(for: file), .email)
    }

    func testADeadlineMakesItAReminder() {
        XCTAssertEqual(BrainClassifier.section(for: input("Submit the shutdown plan by Friday")), .reminders)
    }

    func testAToDoTagMakesItAReminder() {
        XCTAssertEqual(
            BrainClassifier.section(for: input("Stringing execution study", tags: ["todo"])),
            .reminders
        )
    }

    func testPlainWorkTextIsANote() {
        XCTAssertEqual(
            BrainClassifier.section(for: input("Minutes of the site meeting with the contractor")),
            .notes
        )
    }

    func testOnlyWorkGetsSections() {
        let map = BrainClassifier.map([
            input("Pick up my daughter from school"),
            input("Submit the tender by Friday")
        ])
        XCTAssertNil(map.files(in: .family).first?.section)
        XCTAssertEqual(map.files(in: .work).first?.section, .reminders)
    }

    // MARK: - The map

    func testTheMapCountsAndSortsNewestFirst() {
        let older = BrainFileInput(
            id: UUID(),
            title: "Older meeting note",
            text: "Meeting with the client",
            kind: .note,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = BrainFileInput(
            id: UUID(),
            title: "Newer meeting note",
            text: "Another client meeting",
            kind: .note,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        let map = BrainClassifier.map([older, newer])
        XCTAssertEqual(map.count(.work), 2)
        XCTAssertEqual(map.total, 2)
        XCTAssertEqual(map.files(in: .work).first?.id, newer.id)
    }

    func testEveryRegionHasACountEvenWhenEmpty() {
        let counts = BrainClassifier.map([input("Sourdough starter")]).counts
        XCTAssertEqual(counts.count, BrainRegion.allCases.count)
        XCTAssertEqual(counts[.general], 1)
        XCTAssertEqual(counts[.work], 0)
    }
}
