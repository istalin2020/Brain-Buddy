import XCTest
@testable import BrainBuddy

/// The queue that catches what you say to Siri. Its whole job is to never lose
/// anything, so what's tested is the contract: written before the intent
/// returns, readable in order afterwards.
final class QuickCaptureQueueTests: XCTestCase {
    override func tearDown() {
        QuickCaptureQueue.pending().forEach(QuickCaptureQueue.remove)
        super.tearDown()
    }

    func testAnEmptyCaptureIsRefusedRatherThanQueued() {
        XCTAssertThrowsError(try QuickCaptureQueue.enqueue("   \n  ")) { error in
            XCTAssertEqual(error as? QuickCaptureError, .empty)
        }
        XCTAssertTrue(QuickCaptureQueue.pending().isEmpty)
    }

    func testACaptureSurvivesTheRoundTrip() throws {
        let url = try QuickCaptureQueue.enqueue("  Tell Sam the survey moved to Friday  ")

        XCTAssertTrue(QuickCaptureQueue.pending().contains(url))
        // Trimmed on the way in, so the app doesn't have to guess later.
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "Tell Sam the survey moved to Friday"
        )
    }

    func testCapturesComeBackOldestFirst() throws {
        let first = try QuickCaptureQueue.enqueue("First thing", at: Date(timeIntervalSince1970: 1_000))
        let second = try QuickCaptureQueue.enqueue("Second thing", at: Date(timeIntervalSince1970: 2_000))

        let pending = QuickCaptureQueue.pending()
        let firstIndex = try XCTUnwrap(pending.firstIndex(of: first))
        let secondIndex = try XCTUnwrap(pending.firstIndex(of: second))
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    func testRemovingLeavesTheQueueEmpty() throws {
        let url = try QuickCaptureQueue.enqueue("Something")
        XCTAssertEqual(QuickCaptureQueue.pendingCount, 1)
        QuickCaptureQueue.remove(url)
        XCTAssertEqual(QuickCaptureQueue.pendingCount, 0)
    }
}
