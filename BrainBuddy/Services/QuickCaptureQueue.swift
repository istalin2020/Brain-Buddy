import Foundation

/// Text captured from outside the app's own screens — Siri, the Shortcuts app,
/// a Home Screen or Lock Screen action — waiting to be filed.
///
/// It exists for one reason: **a capture must never depend on the app being
/// ready.** An App Intent can run while the app is asleep, in a process that may
/// be killed the moment it returns its answer, so it has no business opening a
/// CloudKit-mirrored store, running an embedding pass, or waiting on anything.
/// It appends a file and returns. The app drains the folder on its next
/// foreground pass, through the same `IngestService` path everything else uses,
/// so a thought muttered at a traffic light gets the same title, keywords and
/// embedding treatment as one typed at a desk.
///
/// Unlike `SharedInbox` this lives in the app's *own* container, not an App
/// Group: nothing to configure, nothing to get wrong, and it works in a fresh
/// clone of this repository with no entitlement set up. See `SharedInbox` for
/// the cross-process case, which does need the group.
enum QuickCaptureQueue {
    static let folderName = "QuickCapture"

    static var directoryURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Writes one capture and returns immediately.
    ///
    /// Throws rather than failing quietly: the caller is a Siri request, and
    /// "Saved" when nothing was saved is the one outcome a capture tool must
    /// never produce.
    @discardableResult
    static func enqueue(_ text: String, at date: Date = Date()) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuickCaptureError.empty }
        guard let directoryURL else { throw QuickCaptureError.noStorage }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Timestamped so the drain replays captures in the order they were
        // spoken, and suffixed so two in the same second can't collide.
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        let url = directoryURL.appendingPathComponent(
            "quick-\(stamp)-\(UUID().uuidString.prefix(6)).txt"
        )
        try Data(trimmed.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Oldest first, so captures arrive in the order they were made.
    ///
    /// Ordered by filename rather than modification date: the name carries the
    /// millisecond the capture was *made*, which is what the order should
    /// reflect, and two files written in the same instant would otherwise sort
    /// arbitrarily.
    static func pending() -> [URL] {
        guard let directoryURL else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// How many captures are waiting. Shown in Settings so a hand-off that never
    /// arrived is visible rather than mysterious.
    static var pendingCount: Int { pending().count }
}

enum QuickCaptureError: LocalizedError, Equatable {
    case empty
    case noStorage

    var errorDescription: String? {
        switch self {
        case .empty:
            return "There was nothing to remember."
        case .noStorage:
            return "Brain Buddy couldn't reach its own storage, so nothing was saved."
        }
    }
}
