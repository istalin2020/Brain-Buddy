import XCTest
@testable import BrainBuddy

final class SearchEngineTests: XCTestCase {
    private var engine: SearchEngine!

    private let dentist = UUID()
    private let recipe = UUID()
    private let receipt = UUID()

    override func setUp() {
        super.setUp()
        engine = SearchEngine()
        // Embeddings depend on OS-provided language models that may be absent in
        // a test runner, so the lexical path is what these tests pin down.
        engine.isSemanticEnabled = false
    }

    private var documents: [SearchDocument] {
        [
            SearchDocument(
                id: dentist,
                title: "Dentist appointment",
                body: "Tuesday at four with Dr Alvarez. Bring the insurance card.",
                keywords: "dentist appointment insurance",
                createdAt: Date().addingTimeInterval(-86_400)
            ),
            SearchDocument(
                id: recipe,
                title: "Pasta recipe",
                body: "Garlic, chilli, olive oil and spaghetti. Cook the garlic slowly.",
                keywords: "pasta garlic recipe",
                createdAt: Date().addingTimeInterval(-86_400 * 30)
            ),
            SearchDocument(
                id: receipt,
                title: "Laptop receipt",
                body: "Paid 1499 at the store. Warranty runs for two years.",
                keywords: "receipt laptop warranty",
                createdAt: Date().addingTimeInterval(-86_400 * 400)
            )
        ]
    }

    func testFindsTheRightDocumentForAKeyword() {
        let results = engine.rank(query: "garlic", documents: documents)
        XCTAssertEqual(results.first?.id, recipe)
    }

    func testAnswersASpokenQuestion() {
        let results = engine.rank(query: "hey what did I save about the dentist", documents: documents)
        XCTAssertEqual(results.first?.id, dentist)
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(engine.rank(query: "   ", documents: documents).isEmpty)
    }

    func testUnknownTermReturnsNothingRatherThanEverything() {
        XCTAssertTrue(engine.rank(query: "helicopter", documents: documents).isEmpty)
    }

    func testRespectsResultLimit() {
        XCTAssertEqual(engine.rank(query: "the garlic dentist receipt", documents: documents, limit: 2).count, 2)
    }

    func testPinnedDocumentOutranksAnOtherwiseEqualOne() {
        let pinned = UUID()
        let plain = UUID()
        let corpus = [
            SearchDocument(id: plain, title: "Meeting notes", body: "Discussed the quarterly roadmap."),
            SearchDocument(id: pinned, title: "Meeting notes", body: "Discussed the quarterly roadmap.", isPinned: true)
        ]
        XCTAssertEqual(engine.rank(query: "quarterly roadmap", documents: corpus).first?.id, pinned)
    }

    func testSnippetPicksTheSentenceContainingTheQuery() {
        let snippet = SearchEngine.snippet(
            for: Tokenizer.queryTokens(in: "warranty"),
            in: "Paid 1499 at the store. Warranty runs for two years."
        )
        XCTAssertTrue(snippet.contains("Warranty"))
        XCTAssertFalse(snippet.contains("Paid"))
    }

    // MARK: - Reading a value out of a document

    /// The report shape this was reported against: asking for TSH must return the
    /// whole row, digits after the decimal point included.
    private let labReport = """
    DEPARTMENT OF LABORATORY MEDICINE
    Name : JOSEPH STALIN KASPAR
    INVESTIGATION RESULT REFERENCE RANGE
    VITAMIN D3 (25 Hydroxy) 25.11 Normal:30-100 ng/ml
    TFT
    FREET3 3.25 2.02 - 4.43 pg/mL
    FREET4 16.87 12 - 22pmol/L
    TSH 5.46 0.270 - 4.20 uIU/mL
    Method:Electrochemiluminescence immunoassay.
    """

    func testSnippetReturnsTheWholeValueNotJustTheDigitsBeforeTheDecimal() {
        let snippet = SearchEngine.snippet(
            for: Tokenizer.queryTokens(in: "What is my latest TSH value?"),
            in: labReport
        )
        XCTAssertTrue(snippet.contains("5.46"), "got “\(snippet)”")
        XCTAssertFalse(snippet.hasSuffix("TSH 5"))
        // The reference range is on the same row and is part of the answer.
        XCTAssertTrue(snippet.contains("0.270"))
    }

    func testSnippetPrefersTheRowWithAValueOverTheHeading() {
        let snippet = SearchEngine.snippet(
            for: Tokenizer.queryTokens(in: "FREET4"),
            in: labReport
        )
        XCTAssertTrue(snippet.contains("16.87"))
    }

    /// OCR splits table rows into separate observations often enough that the
    /// label and its value land on consecutive lines.
    func testBareLabelIsJoinedToTheValueBeneathIt() {
        let columnar = """
        INVESTIGATION
        TSH
        5.46 uIU/mL
        Method: immunoassay
        """
        let snippet = SearchEngine.snippet(for: Tokenizer.queryTokens(in: "TSH"), in: columnar)
        XCTAssertTrue(snippet.contains("TSH"))
        XCTAssertTrue(snippet.contains("5.46"), "got “\(snippet)”")
    }

    func testAValueIsSearchableByItsOwnNumber() {
        let report = SearchDocument(id: UUID(), title: "Blood test", body: labReport)
        let results = engine.rank(query: "5.46", documents: [report])
        XCTAssertEqual(results.first?.id, report.id)
    }

    func testTheAnswerCarriesTheFullValue() {
        let results = engine.rank(
            query: "What is my latest TSH value?",
            documents: [SearchDocument(id: UUID(), title: "Lab report", body: labReport)]
        )
        let answer = AnswerComposer.compose(
            query: "What is my latest TSH value?",
            sources: results.map {
                AnswerSource(
                    title: "Lab report",
                    snippet: $0.snippet,
                    createdAt: Date(),
                    kindTitle: "Document",
                    score: $0.score
                )
            }
        )
        XCTAssertTrue(answer.written.contains("5.46"), "got “\(answer.written)”")
        XCTAssertTrue(answer.spoken.contains("5.46"))
    }

    /// The index is cached between searches; a changed corpus has to invalidate
    /// it or results go stale after every capture.
    func testCacheInvalidatesWhenTheCorpusChanges() {
        _ = engine.rank(query: "garlic", documents: documents)
        let added = documents + [
            SearchDocument(id: UUID(), title: "Garden", body: "Plant more garlic in October.")
        ]
        XCTAssertEqual(engine.rank(query: "garlic", documents: added).count, 2)
    }
}
