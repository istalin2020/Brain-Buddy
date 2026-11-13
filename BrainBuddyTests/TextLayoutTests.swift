import CoreGraphics
import XCTest
@testable import BrainBuddy

/// Recognized text put back into the rows it was printed in. The fixture is the
/// reported lab report, whose table came back scrambled: "Sample Type- WHOLE
/// BLOOD" was joined to "13.20", the RDW CV result from the row above, and
/// the app showed "WHOLE BLOOD 13.20" as if the report said it.
final class TextLayoutTests: XCTestCase {
    /// The report's rows as printed: each cell's text and its left edge.
    private let printed: [[(String, Double)]] = [
        [("Patient Name", 0.10), (": Mr. JOSEPH STALIN KASPAR", 0.22), ("Age/Sex", 0.58), (": 40 Year(s) / Male", 0.68)],
        [("RDW CV", 0.13), ("13.20", 0.47), ("%", 0.62), ("11 - 16", 0.71)],
        [("Sample Type-", 0.13), ("WHOLE BLOOD", 0.30)],
        [("RDW (RED CELL DISTRIBUTION", 0.13), ("36.50", 0.47), ("fl", 0.62), ("35 - 56", 0.71)],
        [("BLOOD SUGAR[FASTING]", 0.10), ("6.67", 0.47), ("mmol/L", 0.62)]
    ]

    /// The cells as Vision would report them from a photo tilted by `degrees`,
    /// in a deliberately unhelpful order.
    private func photographed(tiltedBy degrees: Double) -> [TextLayout.Piece] {
        let slope = tan(degrees * .pi / 180)
        var pieces: [TextLayout.Piece] = []
        for (row, cells) in printed.enumerated() {
            let top = 0.20 + Double(row) * 0.03
            let height = 0.012
            for (text, left) in cells {
                let width = 0.011 * Double(text.count)
                let bottom = 1 - top - height + (left + width / 2) * slope
                pieces.append(TextLayout.Piece(
                    text: text,
                    box: CGRect(x: left, y: bottom, width: width, height: height),
                    slope: slope
                ))
            }
        }
        // Vision's order is not reading order.
        return pieces.reversed().enumerated().sorted { $0.offset % 3 < $1.offset % 3 }.map(\.element)
    }

    private func flattened(_ rows: [String]) -> [String] {
        rows.map { $0.replacingOccurrences(of: TextLayout.columnSeparator, with: " ") }
    }

    private var expected: [String] {
        printed.map { $0.map(\.0).joined(separator: " ") }
    }

    func testALevelTableComesBackAsItsRows() {
        XCTAssertEqual(flattened(TextLayout.rows(from: photographed(tiltedBy: 0))), expected)
    }

    /// A phone photo is never level. Across a wide table even a small tilt
    /// moves the right-hand column by half a row.
    func testATiltedPhotoStillComesBackAsItsRows() {
        for degrees in [1.0, -1.5, 2.5] {
            XCTAssertEqual(
                flattened(TextLayout.rows(from: photographed(tiltedBy: degrees))),
                expected,
                "tilted \(degrees)°"
            )
        }
    }

    /// The reported line is gone: nothing puts "WHOLE BLOOD" next to a number.
    func testTheSampleTypeIsNeverGluedToAResult() {
        let rows = TextLayout.rows(from: photographed(tiltedBy: 1))
        XCTAssertFalse(rows.contains { $0.contains("WHOLE BLOOD") && $0.contains(where: \.isNumber) })
    }

    /// Cells far apart on a row are separate columns, so two fields on one
    /// printed line stay two facts.
    func testDistantCellsAreSeparatedAsColumns() throws {
        let header = try XCTUnwrap(TextLayout.rows(from: photographed(tiltedBy: 0)).first)
        XCTAssertTrue(header.contains("KASPAR" + TextLayout.columnSeparator + "Age/Sex"), "got \(header)")
    }

    func testTheSkewIsMeasuredFromTheTextItself() {
        let slope = tan(2 * Double.pi / 180)
        XCTAssertEqual(TextLayout.pageSkew(of: photographed(tiltedBy: 2)), slope, accuracy: 0.0001)
    }

    /// A rotated stamp or label is not the page's tilt.
    func testAnImplausibleSkewIsIgnored() {
        let stamp = TextLayout.Piece(text: "PAID IN FULL", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05), slope: 0.8)
        XCTAssertEqual(TextLayout.pageSkew(of: [stamp]), 0)
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(TextLayout.rows(from: []).isEmpty)
        XCTAssertEqual(TextLayout.text(from: [TextLayout.Piece(text: "  ", box: CGRect(x: 0, y: 0, width: 0.1, height: 0.01))]), "")
    }
}
