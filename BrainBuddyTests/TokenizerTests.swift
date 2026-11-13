import XCTest
@testable import BrainBuddy

final class TokenizerTests: XCTestCase {
    func testDropsStopwordsAndPunctuation() {
        let tokens = Tokenizer.tokens(in: "The dentist appointment is on Tuesday!")
        XCTAssertEqual(tokens, ["dentist", "appointment", "tuesday"])
    }

    func testFoldsDiacriticsAndCase() {
        XCTAssertEqual(Tokenizer.tokens(in: "Café RÉSUMÉ"), ["cafe", "resume"])
    }

    func testStemsCommonPlurals() {
        XCTAssertEqual(Tokenizer.stem("receipts"), "receipt")
        XCTAssertEqual(Tokenizer.stem("batteries"), "battery")
        XCTAssertEqual(Tokenizer.stem("boxes"), "box")
    }

    func testDoesNotStemWordsThatMerelyEndInS() {
        XCTAssertEqual(Tokenizer.stem("address"), "address")
        XCTAssertEqual(Tokenizer.stem("bus"), "bus")
    }

    func testQueryTokensDropConversationalFiller() {
        let tokens = Tokenizer.queryTokens(in: "Hey, what did I say about the dentist?")
        XCTAssertEqual(tokens, ["dentist"])
    }

    func testQueryTokensFallBackWhenFillerEatsEverything() {
        // "what did I say" is pure filler; searching for nothing would be worse
        // than searching for the filler itself.
        XCTAssertFalse(Tokenizer.queryTokens(in: "what did I say").isEmpty)
    }

    func testSentenceSplitting() {
        let sentences = Tokenizer.sentences(in: "First one. Second one!\nThird one?")
        XCTAssertEqual(sentences, ["First one", "Second one", "Third one"])
    }

    // MARK: - Decimals

    /// The bug this suite exists to prevent coming back: a lab result read off a
    /// report was shown as "TSH 5" because the decimal point was treated as the
    /// end of a sentence.
    func testDecimalPointDoesNotEndASentence() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "TSH 5.46 0.270 - 4.20 uIU/mL"),
            ["TSH 5.46 0.270 - 4.20 uIU/mL"]
        )
    }

    func testDecimalSurvivesAlongsideRealSentenceBreaks() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "TSH came back at 5.46. That is above range."),
            ["TSH came back at 5.46", "That is above range"]
        )
    }

    func testDecimalIsOneToken() {
        XCTAssertEqual(Tokenizer.tokens(in: "TSH 5.46"), ["tsh", "5.46"])
        XCTAssertEqual(Tokenizer.tokens(in: "vitamin d3 25.11 ng/ml"), ["vitamin", "d3", "25.11", "ng", "ml"])
    }

    /// A trailing period is still a boundary, not part of the number.
    func testTrailingPeriodAfterANumberIsNotKept() {
        XCTAssertEqual(Tokenizer.sentences(in: "The reading was 5.46."), ["The reading was 5.46"])
        // "the" and "was" are stopwords and "reading" stems to "read"; the value
        // is what has to survive intact.
        XCTAssertEqual(Tokenizer.tokens(in: "The reading was 5.46."), ["read", "5.46"])
    }

    func testDomainsAndVersionsStayWhole() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "Email nmc.ghoubra@example.com about it"),
            ["Email nmc.ghoubra@example.com about it"]
        )
    }

    // MARK: - Abbreviations

    func testAbbreviationsDoNotEndASentence() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "Booked with Dr. Alvarez on Tuesday"),
            ["Booked with Dr. Alvarez on Tuesday"]
        )
        XCTAssertEqual(
            Tokenizer.sentences(in: "File No. 14397468 is the one"),
            ["File No. 14397468 is the one"]
        )
    }

    func testInitialsDoNotEndASentence() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "Reported by J. Jickson yesterday"),
            ["Reported by J. Jickson yesterday"]
        )
    }

    func testARealSentenceStillEndsAfterAWord() {
        XCTAssertEqual(
            Tokenizer.sentences(in: "The sample arrived. It was processed at noon."),
            ["The sample arrived", "It was processed at noon"]
        )
    }

    // MARK: - Shape

    func testEmptyTextHasNoSentences() {
        XCTAssertTrue(Tokenizer.sentences(in: "").isEmpty)
        XCTAssertTrue(Tokenizer.sentences(in: "   \n  ").isEmpty)
    }

    func testSentenceContainingFindsTheRightOne() throws {
        let text = "First line here. TSH 5.46 uIU/mL. Last line."
        let position = try XCTUnwrap(text.range(of: "5.46")).lowerBound
        XCTAssertEqual(Tokenizer.sentence(containing: position, in: text), "TSH 5.46 uIU/mL")
    }

    func testEveryLineOfAReportSurvives() {
        let report = """
        INVESTIGATION RESULT REFERENCE RANGE
        VITAMIN D3 (25 Hydroxy) 25.11 Normal:30-100 ng/ml
        FREET3 3.25 2.02 - 4.43 pg/mL
        FREET4 16.87 12 - 22pmol/L
        TSH 5.46 0.270 - 4.20 uIU/mL
        """
        let lines = Tokenizer.sentences(in: report)
        XCTAssertEqual(lines.count, 5, "one line in, one line out — no line split at a decimal")
        XCTAssertEqual(lines.last, "TSH 5.46 0.270 - 4.20 uIU/mL")
    }
}
