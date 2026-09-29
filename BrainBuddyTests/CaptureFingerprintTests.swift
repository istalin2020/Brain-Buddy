import XCTest
@testable import BrainBuddy

/// Recognising the same capture arriving twice. The ways into this app favour
/// never losing something over never repeating it, so this is what stops the
/// library filling up with four copies of one screenshot.
final class CaptureFingerprintTests: XCTestCase {
    private let message = """
    Transaction with reference id 732379459 processed successfully.
    Transaction Number: LFT26253286VPSCP From: 0435XXXXXX
    """

    func testTheSameTextFingerprintsTheSame() {
        XCTAssertEqual(CaptureFingerprint.text(message), CaptureFingerprint.text(message))
    }

    /// The screenshot taken twice differs by the clock in its status bar and by
    /// whatever the compressor did — but the words are identical, and the words
    /// are what makes it the same message.
    func testFormattingAndCaseDoNotChangeTheFingerprint() {
        let noisy = "  TRANSACTION with reference id 732379459   PROCESSED successfully!\n\n"
            + "transaction number: LFT26253286VPSCP from: 0435XXXXXX  "
        XCTAssertEqual(CaptureFingerprint.text(message), CaptureFingerprint.text(noisy))
    }

    func testDifferentContentFingerprintsDifferently() {
        let other = message.replacingOccurrences(of: "732379459", with: "732379348")
        XCTAssertNotEqual(CaptureFingerprint.text(message), CaptureFingerprint.text(other))
    }

    /// A scrap of OCR is not enough to declare two things the same.
    func testTooFewWordsIsNotAFingerprint() {
        XCTAssertNil(CaptureFingerprint.text("Hi there"))
        XCTAssertNil(CaptureFingerprint.text(""))
    }

    func testAPictureWithNoWordsFallsBackToItsBytes() throws {
        let bytes = Data((0..<512).map { UInt8($0 % 251) })
        let fingerprint = try XCTUnwrap(CaptureFingerprint.of(text: "  ", payload: bytes))
        XCTAssertEqual(fingerprint, CaptureFingerprint.payload(bytes))
        XCTAssertNotEqual(fingerprint, CaptureFingerprint.payload(bytes + Data([9])))
    }

    /// Words beat bytes: the same message screenshotted twice is one message
    /// even though the two files differ.
    func testWordsWinOverBytesWhenThereAreWords() {
        let first = CaptureFingerprint.of(text: message, payload: Data([1, 2, 3]))
        let second = CaptureFingerprint.of(text: message, payload: Data([4, 5, 6]))
        XCTAssertEqual(first, second)
    }

    func testNothingAtAllIsNotAFingerprint() {
        XCTAssertNil(CaptureFingerprint.of(text: "", payload: nil))
        XCTAssertNil(CaptureFingerprint.of(text: "", payload: Data()))
    }
}
