import Foundation

/// The hand-off point between the share extension and the app.
///
/// The extension deliberately does **not** open the SwiftData store. Two
/// processes writing a CloudKit-mirrored store is a whole class of problems, and
/// an extension is memory-capped and killed aggressively — a bad place to run
/// OCR or embedding. Instead it drops the raw file into a shared App Group
/// folder and exits; the app drains that folder through the normal
/// `IngestService` path, so shared items get exactly the same title, OCR,
/// keyword and embedding treatment as anything captured in-app.
///
/// The contract is intentionally almost nothing: *a real file with a real
/// filename*. No manifest, no versioned schema to keep in sync across the
/// process boundary — routing is by file type, which `IngestService.saveFile`
/// already does.
enum SharedInbox {
    /// Must match the App Group in both entitlements files, and the copy in
    /// `BrainBuddyShare/ShareViewController.swift`.
    static let appGroupIdentifier = "group.com.brainbuddy.app"
    static let folderName = "Inbox"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var directoryURL: URL? {
        containerURL?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `false` when the App Group isn't configured for this build, which is the
    /// one thing that silently disables sharing. Surfaced in Settings.
    static var isAvailable: Bool { containerURL != nil }

    @discardableResult
    static func createDirectoryIfNeeded() -> URL? {
        guard let directoryURL else { return nil }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// Files waiting to be imported, oldest first so shares arrive in order.
    static func pendingFiles() -> [URL] {
        guard let directoryURL else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
