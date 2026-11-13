import CoreGraphics
import Foundation

/// Puts recognized text back into the rows it was printed in.
///
/// Apple's recognizer reads characters very well and returns each run of text
/// as its own box — a lab report's `RDW CV`, its `13.20`, its `%` and its
/// `11 - 16` are four boxes. Joining those boxes in the order they come back
/// scrambles a table: on one report it put *"Sample Type- WHOLE BLOOD"* next to
/// *"13.20"*, the result from the row above, and search then presented
/// "WHOLE BLOOD 13.20" as if the report said it. It never did.
///
/// This is the layout step every OCR pipeline runs after recognition — PaddleOCR
/// and docTR both do a version of it: boxes whose vertical centres line up are
/// one row, and a row reads left to right. Two refinements make it hold up on
/// photographs rather than clean scans:
///
/// - **Tilt.** A phone photo of a page is rarely level, and across a wide table
///   a one-degree tilt moves the right-hand column by half a row. The page's
///   slope is measured from the text boxes themselves, and every box is
///   compared at the same horizontal position before rows are formed.
/// - **Columns.** Cells far apart on a row are separated by a tab rather than a
///   space, so "Patient Name : Mr. JOSEPH STALIN KASPAR" and "Age/Sex : 40" on
///   the same printed line stay two facts, not one run-on value.
///
/// Pure and free of Vision, so the rules are testable with plain rectangles.
enum TextLayout {
    /// One recognized run of text.
    struct Piece: Equatable {
        let text: String
        /// Normalized to the image, origin at the bottom-left — Vision's
        /// convention, kept so callers can pass boxes straight through.
        let box: CGRect
        /// Rise over run of the text's own baseline, in the same normalized
        /// space. Zero for level text.
        let slope: Double

        init(text: String, box: CGRect, slope: Double = 0) {
            self.text = text
            self.box = box
            self.slope = slope
        }
    }

    /// The separator between two cells of a row that are far apart.
    static let columnSeparator = "\t"

    /// Past this, the page is not tilted, it is something else — a rotated
    /// label, a stamp — and correcting for it would do more harm than good.
    static let maximumSkew = 0.15

    static func text(from pieces: [Piece]) -> String {
        rows(from: pieces).joined(separator: "\n")
    }

    static func rows(from pieces: [Piece]) -> [String] {
        let usable = pieces.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.box.height > 0
        }
        guard !usable.isEmpty else { return [] }

        let skew = pageSkew(of: usable)

        // Each box's centre, carried back along the page's slope to the left
        // edge. On a tilted photo, two cells of the same printed row have
        // different centres but the same projected one.
        struct Placed {
            let piece: Piece
            let level: Double
        }
        let placed = usable
            .map { Placed(piece: $0, level: Double($0.box.midY) - Double($0.box.midX) * skew) }
            // Top of the page first; Vision's y grows upward.
            .sorted { $0.level > $1.level }

        var rows: [[Placed]] = []
        for item in placed {
            if let current = rows.last {
                let level = current.map(\.level).reduce(0, +) / Double(current.count)
                let height = max(Double(item.piece.box.height), medianHeight(current.map(\.piece)))
                if abs(item.level - level) <= 0.5 * height {
                    rows[rows.count - 1].append(item)
                    continue
                }
            }
            rows.append([item])
        }

        return rows.map { row in
            join(row.map(\.piece).sorted { $0.box.minX < $1.box.minX })
        }
    }

    /// Joins one row's cells, with a tab where the gap is a column rather than
    /// a space between words.
    private static func join(_ cells: [Piece]) -> String {
        var line = ""
        var previous: Piece?
        for cell in cells {
            let text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous {
                let gap = Double(cell.box.minX - previous.box.maxX)
                let characterWidth = Double(previous.box.width) / Double(max(previous.text.count, 1))
                line += gap > max(2.5 * characterWidth, 0.015) ? columnSeparator : " "
            }
            line += text
            previous = cell
        }
        return line
    }

    /// The page's tilt: the median slope of the boxes wide enough to measure
    /// one. A short box — "%", "fl" — has a slope that is mostly noise.
    static func pageSkew(of pieces: [Piece]) -> Double {
        let slopes = pieces
            .filter { $0.box.width > 0.08 && $0.slope.isFinite }
            .map(\.slope)
            .sorted()
        guard !slopes.isEmpty else { return 0 }
        let median = slopes[slopes.count / 2]
        return abs(median) <= maximumSkew ? median : 0
    }

    private static func medianHeight(_ pieces: [Piece]) -> Double {
        let heights = pieces.map { Double($0.box.height) }.sorted()
        return heights.isEmpty ? 0 : heights[heights.count / 2]
    }
}
