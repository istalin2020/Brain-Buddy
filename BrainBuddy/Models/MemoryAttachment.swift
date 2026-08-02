import Foundation
import SwiftData

enum AttachmentKind: String, Codable, CaseIterable {
    case image
    case audio
    case pdf
    case file

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .pdf: return "doc.text"
        case .file: return "doc"
        }
    }
}

/// The raw bytes behind a memory: the photo, the recording, the PDF.
///
/// `@Attribute(.externalStorage)` keeps large payloads out of the SQLite file;
/// CloudKit mirrors them as `CKAsset`s, so a 40 MB PDF syncs the same way a
/// two-line note does.
@Model
final class MemoryAttachment {
    var identifier: UUID = UUID()
    var filename: String = ""
    var kindRaw: String = AttachmentKind.file.rawValue
    var createdAt: Date = Date()
    var byteCount: Int = 0

    /// Audio length in seconds, `0` for everything else.
    var duration: Double = 0

    /// Page count for PDFs, `0` for everything else.
    var pageCount: Int = 0

    /// Text pulled out of this specific attachment. Also mirrored into the
    /// parent's `extractedText` so search only has to read one field.
    var extractedText: String = ""

    @Attribute(.externalStorage)
    var payload: Data? = nil

    /// Small JPEG preview, kept inline so lists scroll without loading payloads.
    var thumbnail: Data? = nil

    var memory: MemoryItem? = nil

    init(
        filename: String,
        kind: AttachmentKind,
        payload: Data?,
        extractedText: String = "",
        duration: Double = 0,
        pageCount: Int = 0,
        thumbnail: Data? = nil
    ) {
        self.identifier = UUID()
        self.filename = filename
        self.kindRaw = kind.rawValue
        self.payload = payload
        self.byteCount = payload?.count ?? 0
        self.extractedText = extractedText
        self.duration = duration
        self.pageCount = pageCount
        self.thumbnail = thumbnail
        self.createdAt = Date()
    }
}

extension MemoryAttachment {
    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Writes the payload to a temporary file so `AVAudioPlayer` / `PDFView`
    /// can read it from disk. Returns `nil` when there is nothing to write.
    func temporaryFileURL() -> URL? {
        guard let payload else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainBuddyAttachments", isDirectory: true)
        let url = directory.appendingPathComponent(identifier.uuidString + "-" + filename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try payload.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
