import XCTest
@testable import BrainBuddy

final class BrainBoxTests: XCTestCase {
    private func item(
        _ text: String,
        kind: MemoryKind = .note,
        tags: [String] = []
    ) -> BrainBoxItem {
        BrainBoxItem(id: UUID(), kind: kind, tags: tags, text: text)
    }

    func testEmptyLibraryHasNoBoxes() {
        XCTAssertTrue(BrainBoxBuilder.build(from: []).boxes.isEmpty)
    }

    func testEverythingComesFirstAndCountsTheWholeLibrary() throws {
        let index = BrainBoxBuilder.build(from: [
            item("Called the plumber about the leak"),
            item("Bought paint for the hallway")
        ])

        let first = try XCTUnwrap(index.boxes.first)
        XCTAssertEqual(first.id, "everything")
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.filter, .everything)
    }

    func testKindsWithNothingInThemGetNoBox() {
        let index = BrainBoxBuilder.build(from: [
            item("A typed thought"),
            item("Another typed thought")
        ])

        XCTAssertTrue(index.boxes.contains { $0.id == "kind.note" })
        XCTAssertFalse(index.boxes.contains { $0.id == "kind.voice" })
        XCTAssertFalse(index.boxes.contains { $0.id == "kind.image" })
    }

    func testKindBoxCountsOnlyThatKind() {
        let index = BrainBoxBuilder.build(from: [
            item("A typed thought"),
            item("Discussion about the roof", kind: .voice),
            item("Discussion about the yard", kind: .voice)
        ])

        let voice = index.boxes.first { $0.id == "kind.voice" }
        XCTAssertEqual(voice?.count, 2)
        XCTAssertEqual(voice?.title, "Voice notes")
    }

    func testTagsBecomeBoxes() {
        let index = BrainBoxBuilder.build(from: [
            item("Renew the insurance", tags: ["admin"]),
            item("File the tax return", tags: ["admin"]),
            item("Try the new bakery", tags: ["food"])
        ])

        let admin = index.boxes.first { $0.id == "tag.admin" }
        XCTAssertEqual(admin?.title, "#admin")
        XCTAssertEqual(admin?.count, 2)
        XCTAssertEqual(admin?.filter, .tag("admin"))
    }

    func testRecurringSubjectEarnsABoxAndAOneOffDoesNot() {
        let index = BrainBoxBuilder.build(from: [
            item("The Tower handover slipped again, Tower cladding still open"),
            item("Tower snagging list needs signing off before Friday"),
            item("Bought sourdough starter from the market")
        ])

        XCTAssertTrue(
            index.boxes.contains { $0.title.lowercased() == "tower" },
            "A subject in two memories should get a box: \(index.boxes.map(\.title))"
        )
        XCTAssertFalse(index.boxes.contains { $0.title.lowercased() == "sourdough" })
    }

    func testTopicBoxesAreCapped() {
        // Twelve distinct subjects, each in two memories, so every one of them
        // clears the threshold and only the cap can hold the count down.
        let subjects = [
            "Tower", "Harbour", "Bridge", "Depot", "Quarry", "Foundry",
            "Terrace", "Wharf", "Mill", "Kiln", "Vault", "Arcade"
        ]
        let items = subjects.flatMap { subject in
            [
                item("\(subject) inspection was rescheduled"),
                item("\(subject) inspection notes filed")
            ]
        }

        let topicBoxes = BrainBoxBuilder.build(from: items).boxes.filter {
            $0.id.hasPrefix("topic.")
        }
        XCTAssertLessThanOrEqual(topicBoxes.count, BrainBoxBuilder.maximumTopicBoxes)
    }

    func testASubjectThatIsAlreadyATagDoesNotGetASecondBox() {
        let index = BrainBoxBuilder.build(from: [
            item("Tower handover slipped again", tags: ["tower"]),
            item("Tower snagging list needs signing off", tags: ["tower"])
        ])

        XCTAssertEqual(index.boxes.filter { $0.title.lowercased().contains("tower") }.count, 1)
    }

    func testTopicLabelKeepsTheSpellingTheWriterUsed() {
        let index = BrainBoxBuilder.build(from: [
            item("PCH invoice is overdue"),
            item("PCH invoice chased again")
        ])

        XCTAssertTrue(
            index.boxes.contains { $0.title == "PCH" },
            "Expected the capitalized spelling: \(index.boxes.map(\.title))"
        )
    }

    /// The point of a topic box is that opening it shows the memories the
    /// subject came from — which is `topics`, not the count on the card.
    func testMemoriesAreFiledUnderTheSubjectTheyEarned() throws {
        let first = item("Tower handover slipped again")
        let second = item("Tower snagging list needs signing off")
        let unrelated = item("Bought sourdough starter from the market")
        let index = BrainBoxBuilder.build(from: [first, second, unrelated])

        let tower = try XCTUnwrap(
            index.boxes.first { $0.title.lowercased() == "tower" },
            "Expected a Tower box: \(index.boxes.map(\.title))"
        )
        guard case .topic(let key) = tower.filter else {
            return XCTFail("Expected a topic filter, got \(tower.filter)")
        }

        XCTAssertEqual(index.topics[first.id]?.contains(key), true)
        XCTAssertEqual(index.topics[second.id]?.contains(key), true)
        XCTAssertEqual(index.topics[unrelated.id]?.contains(key), false)
    }
}
