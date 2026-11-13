import Foundation

/// Puts dictated words into a note at the cursor, and leaves your own edits
/// alone.
///
/// The Input box used to take a snapshot of the note when the mic was pressed
/// and then, on every word heard, rebuild the note as *snapshot + everything
/// heard so far*. That had two consequences people ran into at once:
///
/// - **Edits made while listening were erased.** Delete a word, fix a spelling,
///   and the next word the recognizer heard rebuilt the note from the snapshot
///   — and pressing ✓ did it once more with the final transcript.
/// - **Speech always went to the end.** The snapshot was the whole note, so
///   there was nowhere to put the words but after it, wherever the cursor was.
///
/// This keeps a **live span** instead: the stretch of the note holding the
/// words still being heard. Only that span is ever rewritten. Everything
/// outside it is yours, and when you edit, the span moves with the text:
///
/// - **An edit before the span** shifts it along.
/// - **An edit after it** leaves it where it is.
/// - **An edit inside it**, or **moving the cursor somewhere else**, settles
///   the words heard so far — they become ordinary text, exactly as you left
///   them — and the next words go wherever the cursor now is.
///
/// Offsets are UTF-16, the units a text view's selection uses, so nothing is
/// converted between here and the screen.
///
/// Pure and free of UIKit and the recognizer, so every one of those rules is
/// pinned by a test.
struct DictationSplice: Equatable {
    /// The whole note, dictated words included.
    private(set) var text: String

    /// Where the words still being heard sit in `text`.
    private(set) var live: NSRange

    /// How many words of the recognizer's running transcript are already in
    /// the note as ordinary text.
    private(set) var settledWordCount = 0

    /// The last word settled, for finding the place again when the recognizer
    /// revises the words just before it — which it does as it hears more.
    private var settledTail: String?

    /// The running transcript, as last heard.
    private var transcript = ""

    /// Starts listening with the cursor at `cursor`. A selection is kept, and
    /// the words go after it: dictation never deletes anything you wrote.
    init(text: String, cursor: NSRange) {
        self.text = text
        let length = (text as NSString).length
        let end = cursor.location + cursor.length
        self.live = NSRange(location: min(max(0, end), length), length: 0)
    }

    /// Where the caret belongs while listening: just after the words being
    /// heard, so you can watch them arrive.
    var caret: NSRange {
        NSRange(location: live.location + live.length, length: 0)
    }

    // MARK: - Hearing

    /// The recognizer's running transcript changed. Only the live span is
    /// rewritten; the recognizer's final, better-punctuated pass goes through
    /// here too, and so can only ever touch the words still live.
    mutating func hear(_ transcript: String) {
        self.transcript = transcript
        render(words(after: transcript))
    }

    private mutating func render(_ words: [String]) {
        let note = text as NSString
        var insertion = words.joined(separator: " ")

        if !insertion.isEmpty {
            // Spaces where they are missing and nowhere else: speaking into the
            // middle of a sentence must not run words together, and speaking
            // at the start of a line must not indent it.
            let beforeIndex = live.location - 1
            if beforeIndex >= 0, !Self.isSpace(note.character(at: beforeIndex)) {
                insertion = " " + insertion
            }
            let afterIndex = live.location + live.length
            if afterIndex < note.length {
                let after = note.character(at: afterIndex)
                if !Self.isSpace(after), !Self.closesAPhrase(after) { insertion += " " }
            }
        }

        text = note.replacingCharacters(in: live, with: insertion)
        live = NSRange(location: live.location, length: (insertion as NSString).length)
    }

    /// The words heard since the last settle.
    ///
    /// The transcript is cumulative for the whole session, so the words
    /// already settled are skipped. Counting alone is not quite enough: the
    /// recognizer revises its most recent words as it hears more — "Tommy"
    /// becomes "Dommy", "micro mouse" becomes "micromouse" — and a revision
    /// just before the settle point shifts the count. So the last settled
    /// word is looked for near where it should be, and the new words start
    /// after it.
    private func words(after transcript: String) -> [String] {
        let all = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard settledWordCount > 0 else { return all }

        if let tail = settledTail, !all.isEmpty {
            let expected = settledWordCount - 1
            let nearby = (max(0, expected - 2)...min(all.count - 1, expected + 2))
            let order = [expected] + nearby.reversed().filter { $0 != expected }
            for index in order where index >= 0 && index < all.count && Self.same(all[index], tail) {
                return Array(all.dropFirst(index + 1))
            }
        }
        return Array(all.dropFirst(settledWordCount))
    }

    // MARK: - Your edits

    /// You typed, deleted or pasted while listening. `selection` is the cursor
    /// after the edit.
    mutating func userEdited(to newText: String, selection: NSRange) {
        guard newText != text else {
            userMoved(selection)
            return
        }

        let old = text as NSString
        let new = newText as NSString

        // The stretch that changed: everything between the part both versions
        // start with and the part they end with.
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let changedStart = prefix
        let changedEnd = old.length - suffix
        let delta = new.length - old.length

        text = newText
        let liveEnd = live.location + live.length

        if changedEnd <= live.location {
            // Entirely before the words being heard — including typing right
            // at the insertion point, after which dictation carries on after
            // what you typed.
            live.location += delta
        } else if changedStart > liveEnd {
            // Entirely after them: nothing to do.
        } else {
            // Into them — or right at their end. Typing a comma straight after
            // the words just heard is continuing the sentence, and the next
            // words belong after the comma, not in front of it. Either way the
            // words heard so far are yours now, as edited.
            settle(at: selection)
        }
    }

    /// You moved the cursor, or selected something, without changing the text.
    mutating func userMoved(_ selection: NSRange) {
        let liveEnd = live.location + live.length
        // Inside the words being heard, or at their end — where the caret is
        // kept — is just the caret following them. Their *start* is not: a tap
        // there is a tap in front of them, and the next words belong there.
        let isFollowing = live.length == 0
            ? selection.location == live.location
            : selection.location > live.location && selection.location <= liveEnd
        if selection.length == 0, isFollowing {
            return
        }
        settle(at: NSRange(location: selection.location + selection.length, length: 0))
    }

    /// Makes everything heard so far ordinary text, and starts a new live span
    /// at `cursor`.
    private mutating func settle(at cursor: NSRange) {
        let heard = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        settledWordCount = heard.count
        settledTail = heard.last
        let length = (text as NSString).length
        live = NSRange(location: min(max(0, cursor.location), length), length: 0)
    }

    // MARK: - Helpers

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Punctuation that attaches to the word before it, so no space goes
    /// between a dictated word and it.
    private static func closesAPhrase(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet(charactersIn: ".,;:!?)]}'’”").contains(scalar)
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        let trim = CharacterSet.punctuationCharacters
        return lhs.trimmingCharacters(in: trim).lowercased() == rhs.trimmingCharacters(in: trim).lowercased()
    }
}
