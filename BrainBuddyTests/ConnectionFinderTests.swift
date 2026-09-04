import XCTest
@testable import BrainBuddy

/// The bar these pin down: a link is shown only when there is a reason for it.
/// Padding the section with near-misses would teach people to ignore it.
final class ConnectionFinderTests: XCTestCase {
    private func candidate(
        tags: [String] = [],
        keywords: [String] = [],
        embedding: [Double]? = nil,
        daysAgo: Int = 0
    ) -> ConnectionCandidate {
        ConnectionCandidate(
            id: UUID(),
            title: "Memory",
            tags: tags,
            keywords: keywords,
            embedding: embedding,
            createdAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        )
    }

    func testALoneMemoryHasNoConnections() {
        let subject = candidate(keywords: ["cladding"])
        XCTAssertTrue(ConnectionFinder.related(to: subject, among: [subject]).isEmpty)
    }

    func testASharedTagIsEnough() throws {
        let subject = candidate(tags: ["admin"], keywords: ["renew", "insurance"])
        let other = candidate(tags: ["admin"], keywords: ["file", "tax"])

        let found = ConnectionFinder.related(to: subject, among: [subject, other])
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.id, other.id)
        XCTAssertEqual(first.reason, "Both tagged #admin")
    }

    func testASharedRareWordLinks() throws {
        let subject = candidate(keywords: ["cladding", "tower"])
        let other = candidate(keywords: ["cladding", "invoice"])
        // Filler so "cladding" is genuinely rare in this library.
        let filler = (0..<8).map { candidate(keywords: ["filler\($0)"]) }

        let found = ConnectionFinder.related(to: subject, among: [subject, other] + filler)
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.id, other.id)
        XCTAssertEqual(first.reason, "Both mention cladding")
    }

    /// The signal that keeps this feature honest: a word you write constantly
    /// says nothing about what a memory is about.
    func testAWordInHalfTheLibraryLinksNothing() {
        let subject = candidate(keywords: ["project"])
        let others = (0..<3).map { _ in candidate(keywords: ["project"]) }

        let found = ConnectionFinder.related(to: subject, among: [subject] + others)
        XCTAssertTrue(found.isEmpty, "Expected no links, got \(found.map(\.reason))")
    }

    func testNearIdenticalMeaningLinksWithoutSharedWords() throws {
        let vector = [1.0, 0.0, 0.0]
        let subject = candidate(keywords: ["alpha"], embedding: vector)
        let other = candidate(keywords: ["beta"], embedding: vector)

        let found = ConnectionFinder.related(to: subject, among: [subject, other])
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.reason, "Reads like the same subject")
    }

    func testUnrelatedMeaningLinksNothing() {
        let subject = candidate(keywords: ["alpha"], embedding: [1, 0, 0])
        let other = candidate(keywords: ["beta"], embedding: [0, 1, 0])

        XCTAssertTrue(ConnectionFinder.related(to: subject, among: [subject, other]).isEmpty)
    }

    func testStrongerLinksComeFirst() throws {
        let subject = candidate(tags: ["tower"], keywords: ["cladding", "handover"])
        let strong = candidate(tags: ["tower"], keywords: ["cladding"])
        let weaker = candidate(keywords: ["cladding", "handover"])
        let filler = (0..<8).map { candidate(keywords: ["filler\($0)"]) }

        let found = ConnectionFinder.related(to: subject, among: [subject, weaker, strong] + filler)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.id, strong.id)
        XCTAssertGreaterThan(try XCTUnwrap(found.first).strength, try XCTUnwrap(found.last).strength)
    }

    func testTheListIsCapped() {
        let subject = candidate(tags: ["admin"])
        let others = (0..<9).map { _ in candidate(tags: ["admin"]) }

        let found = ConnectionFinder.related(to: subject, among: [subject] + others, limit: 4)
        XCTAssertEqual(found.count, 4)
    }

    func testReasonNamesAtMostTwoThings() {
        let reason = ConnectionFinder.reason(
            tags: [],
            terms: ["cladding", "handover", "invoice", "sign-off"],
            semantic: 0
        )
        XCTAssertEqual(reason, "Both mention cladding and handover")
    }
}
