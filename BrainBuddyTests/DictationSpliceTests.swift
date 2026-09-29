import XCTest
@testable import BrainBuddy

/// Dictation into the Input box: words go in at the cursor, and your own
/// edits made while the mic is listening are never undone by the next word
/// heard — or by the final pass when you tap stop or ✓.
final class DictationSpliceTests: XCTestCase {
    private func at(_ location: Int, _ length: Int = 0) -> NSRange {
        NSRange(location: location, length: length)
    }

    private func end(of text: String) -> NSRange {
        at((text as NSString).length)
    }

    // MARK: - The reported cases

    /// Delete words by hand while listening; more words arrive, then the
    /// final pass. The deletion stays deleted.
    func testAnEditWhileListeningSurvivesMoreWordsAndTheFinalPass() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("I am planning to build a kind of micro mouse")
        splice.hear("I am planning to build a kind of micro mouse it will move around")

        let edited = splice.text.replacingOccurrences(of: "a kind of ", with: "a ")
        let cursor = (edited as NSString).range(of: "a micro").location + 2
        splice.userEdited(to: edited, selection: at(cursor))

        splice.hear("I am planning to build a kind of micro mouse it will move around in the house")
        splice.hear("I am planning to build a kind of micro mouse. It will move around in the house.")

        XCTAssertFalse(splice.text.contains("kind of"), splice.text)
        XCTAssertTrue(splice.text.contains("in the house"), splice.text)
    }

    /// Speak with the cursor in the middle of a note: the words go there.
    func testWordsGoInAtTheCursor() {
        var splice = DictationSplice(text: "Buy milk and eggs", cursor: at(8))
        splice.hear("bread")
        XCTAssertEqual(splice.text, "Buy milk bread and eggs")
        XCTAssertEqual(splice.caret, at(("Buy milk bread" as NSString).length))
    }

    /// Move the cursor while speaking: the next words go to the new place.
    func testMovingTheCursorSendsTheNextWordsThere() {
        var splice = DictationSplice(text: "First line.\nSecond line.", cursor: at(11))
        splice.hear("alpha")
        XCTAssertEqual(splice.text, "First line. alpha\nSecond line.")

        splice.userMoved(end(of: splice.text))
        splice.hear("alpha beta gamma")
        XCTAssertEqual(splice.text, "First line. alpha\nSecond line. beta gamma")
    }

    // MARK: - Edits around the words being heard

    func testAnEditBeforeTheWordsShiftsThem() {
        var splice = DictationSplice(text: "Note: ", cursor: at(6))
        splice.hear("call the surveyor")
        splice.userEdited(to: "IMPORTANT " + splice.text, selection: at(10))
        splice.hear("call the surveyor tomorrow")
        XCTAssertEqual(splice.text, "IMPORTANT Note: call the surveyor tomorrow")
    }

    func testAnEditAfterTheWordsLeavesThemAlone() {
        var splice = DictationSplice(text: "start end", cursor: at(5))
        splice.hear("middle")
        let edited = splice.text + " extra"
        splice.userEdited(to: edited, selection: end(of: edited))
        splice.hear("middle words")
        XCTAssertEqual(splice.text, "start middle words end extra")
    }

    func testTypingInFrontOfTheWordsShiftsThem() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("milk")
        splice.userEdited(to: "Buy " + splice.text, selection: at(4))
        splice.hear("milk and eggs")
        XCTAssertEqual(splice.text, "Buy milk and eggs")
    }

    /// A comma typed straight after the words just heard continues the
    /// sentence; the next words belong after it.
    func testWordsCarryOnAfterATypedComma() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("call Anil")
        let edited = splice.text + ","
        splice.userEdited(to: edited, selection: end(of: edited))
        splice.hear("call Anil tomorrow")
        XCTAssertEqual(splice.text, "call Anil, tomorrow")
    }

    // MARK: - Cursor moves

    /// The caret sits at the end of the words being heard; the text view
    /// reporting it there is not a move.
    func testTheCaretAtTheEndIsJustFollowing() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("one two")
        splice.userMoved(splice.caret)
        splice.hear("one two three")
        XCTAssertEqual(splice.text, "one two three")
    }

    /// A tap at the start of the words is a tap in front of them.
    func testATapAtTheStartOfTheWordsIsAMove() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("world")
        splice.userMoved(at(0))
        splice.hear("world hello")
        XCTAssertEqual(splice.text, "hello world")
    }

    /// The recognizer rewords what it already heard as it hears more. That
    /// must not repeat or drop words after a move.
    func testARevisedEarlierWordIsNotRepeated() {
        var splice = DictationSplice(text: "", cursor: at(0))
        splice.hear("hey Tommy it will")
        splice.userMoved(at(0))
        splice.hear("hey Dommy it will activate")
        XCTAssertTrue(splice.text.hasPrefix("activate "), splice.text)
        XCTAssertEqual(splice.text.components(separatedBy: "will").count - 1, 1, splice.text)
    }

    // MARK: - Small things

    func testNothingHeardChangesNothing() {
        var splice = DictationSplice(text: "abc", cursor: at(3))
        splice.hear("")
        XCTAssertEqual(splice.text, "abc")
    }

    func testASelectionIsNeverDeleted() {
        var splice = DictationSplice(text: "keep this", cursor: at(5, 4))
        splice.hear("please")
        XCTAssertEqual(splice.text, "keep this please")
    }

    func testNoSpaceBeforeClosingPunctuation() {
        var splice = DictationSplice(text: "Call Anil.", cursor: at(9))
        splice.hear("tomorrow")
        XCTAssertEqual(splice.text, "Call Anil tomorrow.")
    }
}
