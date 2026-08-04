import XCTest
@testable import BrainBuddy

/// Covers the rule that decides whether a capture is a link or a note — the
/// thing a share-sheet URL hand-off depends on.
final class LinkDetectionTests: XCTestCase {
    func testBareURLIsDetected() {
        XCTAssertEqual(
            TextAnalysis.bareURL(in: "https://example.com/articles/sleep-better")?.absoluteString,
            "https://example.com/articles/sleep-better"
        )
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(TextAnalysis.bareURL(in: "  \nhttps://example.com\n "))
    }

    func testURLInsideProseIsNotABareURL() {
        // This is a note that happens to contain a link, not a saved link.
        XCTAssertNil(TextAnalysis.bareURL(in: "read this later https://example.com"))
    }

    func testPlainTextIsNotAURL() {
        XCTAssertNil(TextAnalysis.bareURL(in: "dentist appointment on Tuesday"))
        XCTAssertNil(TextAnalysis.bareURL(in: ""))
    }

    /// Only web links get their own kind; a bare email or phone number is a note.
    func testNonHTTPSchemesAreRejected() {
        XCTAssertNil(TextAnalysis.bareURL(in: "someone@example.com"))
        XCTAssertNil(TextAnalysis.bareURL(in: "tel:5551234567"))
    }

    func testLinkTitleUsesHostAndSlug() {
        let url = URL(string: "https://www.example.com/blog/how-to-sleep-better")!
        XCTAssertEqual(TextAnalysis.linkTitle(for: url), "example.com — how to sleep better")
    }

    func testLinkTitleFallsBackToHostForRootAndOpaqueSlugs() {
        XCTAssertEqual(TextAnalysis.linkTitle(for: URL(string: "https://example.com")!), "example.com")
        XCTAssertEqual(TextAnalysis.linkTitle(for: URL(string: "https://example.com/")!), "example.com")
        // A numeric ID is noise, not a title.
        XCTAssertEqual(TextAnalysis.linkTitle(for: URL(string: "https://example.com/p/8831")!), "example.com")
    }

    func testLinkTitleDecodesPercentEscapes() {
        let url = URL(string: "https://example.com/notes/second%20brain")!
        XCTAssertEqual(TextAnalysis.linkTitle(for: url), "example.com — second brain")
    }
}
