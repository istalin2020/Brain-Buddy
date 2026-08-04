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
}
