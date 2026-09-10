import CryptoKit
import Foundation

/// Identifies a capture by what is *in* it, so the same thing saved twice is
/// recognised as the same thing.
///
/// This exists because the ways into this app deliberately favour never losing a
/// capture over never repeating one: the share extension and the Siri queue both
/// delete their file only *after* the memory is saved, so an interrupted import
/// re-runs and arrives twice. Sharing the same screenshot twice, or importing a
/// PDF you already have, does the same thing. The cost was a library with the
/// same document in it four times — and, worse, the same document classified two
/// different ways, because two copies of one text are still two texts.
///
/// The fingerprint is deliberately **not** a hash of the raw bytes:
///
/// - Two screenshots of the same message differ by a clock in the status bar,
///   and their OCR text is identical.
/// - The same PDF re-exported has different bytes and the same words.
///
/// So it hashes the *normalized tokens* — case, punctuation and whitespace
/// removed — and falls back to the payload only when there are no words at all
/// (a photo of a sunset). Hashed rather than stored whole because it lives on a
/// CloudKit-mirrored field and gets compared, never read.
enum CaptureFingerprint {
    /// Enough of a document to identify it. Two files agreeing on their first
    /// four hundred meaningful words are the same file; comparing further only
    /// costs time.
    static let tokenLimit = 400

    /// Below this a "document" is a scrap — a photo with three OCR'd words on
    /// it — and matching on it would merge things that merely look alike.
    static let minimumTokens = 5

    /// `nil` when there is nothing solid enough to match on, which means the
    /// capture is saved without a duplicate check rather than being merged into
    /// something it isn't.
    static func text(_ text: String) -> String? {
        let tokens = Tokenizer.tokens(in: text)
        guard tokens.count >= minimumTokens else { return nil }
        return digest(tokens.prefix(tokenLimit).joined(separator: " "), prefix: "t")
    }

    /// For a capture with no readable words in it. Exact bytes, which is right
    /// here: the same image imported twice *is* the same bytes.
    static func payload(_ data: Data) -> String {
        digest(data, prefix: "b")
    }

    /// Words first, bytes as a fallback.
    static func of(text: String, payload: Data?) -> String? {
        if let fingerprint = Self.text(text) { return fingerprint }
        guard let payload, !payload.isEmpty else { return nil }
        return Self.payload(payload)
    }

    private static func digest(_ value: String, prefix: String) -> String {
        digest(Data(value.utf8), prefix: prefix)
    }

    private static func digest(_ data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: data)
        return prefix + ":" + hash.map { String(format: "%02x", $0) }.joined()
    }
}
