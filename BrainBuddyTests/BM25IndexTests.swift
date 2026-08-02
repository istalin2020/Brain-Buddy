import XCTest
@testable import BrainBuddy

final class BM25IndexTests: XCTestCase {
    private let dentist = UUID()
    private let recipe = UUID()
    private let filler = UUID()

    private func makeIndex() -> BM25Index {
        BM25Index(documents: [
            (dentist, "Dentist appointment on Tuesday at four. Bring the insurance card."),
            (recipe, "Pasta recipe: garlic, chilli, olive oil, spaghetti."),
            (filler, "Random unrelated musings about the weather and nothing else at all.")
        ])
    }

    func testRareTermRanksItsDocumentFirst() {
        let scores = makeIndex().scores(for: Tokenizer.queryTokens(in: "dentist"))
        XCTAssertEqual(scores.count, 1)
        XCTAssertNotNil(scores[dentist])
    }

    /// A term present in every document has almost no discriminating power, but
    /// it must never produce a negative score — the classic BM25 IDF does.
    func testUbiquitousTermStaysNonNegative() {
        let index = BM25Index(documents: [
            (dentist, "note about pasta"),
            (recipe, "another note about pasta"),
            (filler, "a third note about pasta")
        ])
        let scores = index.scores(for: Tokenizer.tokens(in: "pasta"))
        XCTAssertEqual(scores.count, 3)
        for score in scores.values {
            XCTAssertGreaterThanOrEqual(score, 0)
        }
    }

    func testMultiTermQueryPrefersDocumentContainingBothTerms() {
        let index = BM25Index(documents: [
            (dentist, "garlic bread"),
            (recipe, "garlic and chilli pasta with chilli oil"),
            (filler, "chilli")
        ])
        let scores = index.scores(for: Tokenizer.tokens(in: "garlic chilli"))
        XCTAssertGreaterThan(scores[recipe] ?? 0, scores[dentist] ?? 0)
        XCTAssertGreaterThan(scores[recipe] ?? 0, scores[filler] ?? 0)
    }

    func testCoverageReportsFractionOfQueryTermsPresent() {
        let index = makeIndex()
        let terms = Tokenizer.tokens(in: "dentist insurance pasta")
        XCTAssertEqual(index.coverage(of: terms, in: dentist), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(index.coverage(of: terms, in: recipe), 1.0 / 3.0, accuracy: 0.0001)
    }

    func testEmptyCorpusScoresNothing() {
        let index = BM25Index(documents: [])
        XCTAssertTrue(index.scores(for: ["anything"]).isEmpty)
        XCTAssertEqual(index.documentCount, 0)
    }
}
