# Brain Buddy

An iOS second brain. Capture anything — typed text, voice, photos, PDFs — then
find it again by typing or by *talking to it*, and get the answer read back out
of your own notes. Everything syncs through your private iCloud database.

Built with SwiftUI + SwiftData (CloudKit mirroring), iOS 17+.

---

## What it does

### Capture (unlimited, any form)

| Input | How it's handled |
| --- | --- |
| **Text** | Typed straight into the capture box. `#hashtags` become tags automatically. |
| **Voice** | Recorded to AAC, saved immediately, then transcribed with `SFSpeechRecognizer` (on-device when available). |
| **Image** | Photo library or camera. Text is pulled out with Vision OCR so photos are searchable by their contents. |
| **Scan** | VisionKit's document scanner — edge detection and perspective correction, then OCR per page. |
| **PDF** | Text layer extracted with PDFKit. If the PDF is a scan with no text layer, pages are rasterized and OCR'd. |
| **Link** | A capture that is only a URL becomes a link with a readable `host — slug` title instead of a raw address. |
| **Share sheet** | "Brain Buddy" appears in any app's share sheet — links, selected text, photos, PDFs, files. |
| **Anything else** | Stored intact with its filename indexed, rather than refused. |

There are no item limits, no character caps, and no subscription gates. Large
payloads use SwiftData's `.externalStorage`, so they live outside the SQLite
file and mirror to CloudKit as `CKAsset`s.

The **share extension** is deliberately dumb: it copies the shared payload into
an App Group folder and exits. Extensions are memory-capped and killed
aggressively — a bad place to run OCR or write a CloudKit-mirrored store — so
the app drains that folder through the same `IngestService` path, and shared
items get identical title / OCR / keyword / embedding treatment. The entire
contract across the process boundary is *"a real file with a real filename"*;
routing is by file type, so there's no manifest or versioned schema to keep in
sync between two binaries. Files are deleted only **after** their memory is
saved, so an interrupted import loses nothing.

### Search (typed or spoken)

The **Ask** tab is a hybrid retriever:

1. **BM25 keyword search** over an in-memory inverted index — exact tokens,
   names, order numbers, rare words.
2. **Semantic search** using Apple's on-device `NLEmbedding` sentence vectors —
   finds notes whose *meaning* matches, even when you don't recall your wording.

The two normalized scores are fused (`0.62` lexical / `0.38` semantic), then
nudged by query-term coverage, recency, and pinned status. Query text is
stripped of conversational filler first, so *"hey, what did I save about the
dentist?"* searches for `dentist`.

Tap the microphone and the same pipeline runs on live dictation. The composed
answer is **extractive** — it quotes what you actually stored, with a "from your
note yesterday…" preamble — and `AVSpeechSynthesizer` reads it aloud. It never
generates prose, so it can't tell you something your notes don't say.

### iCloud sync

SwiftData mirrors to the **private** CloudKit database
(`iCloud.com.brainbuddy.app`). The Settings tab surfaces real account status,
storage mode, and when the last remote change arrived — because silent sync
failure is the worst possible outcome for a second brain.

If CloudKit can't be initialized the app falls back to a local store, then to an
in-memory store, and says so in Settings. It never refuses to launch.

### Privacy

Transcription, OCR and embedding all run on-device. Nothing is sent to any
server other than Apple's iCloud, and there are no third-party SDKs, analytics,
or network calls of our own.

---

## Building it

Requires **Xcode 16 or newer** (the project uses file-system-synchronized
groups) and an iOS 17+ device or simulator.

```bash
open BrainBuddy.xcodeproj
```

Then, before running on a device:

1. Select the **BrainBuddy** target → *Signing & Capabilities*. Set your **Team**
   on both the **BrainBuddy** and **BrainBuddyShare** targets.
2. Change the bundle identifiers to something you own. They're currently
   `com.istalin.brainbuddy`, plus `.share` for the extension and `.tests` for the
   test bundle — the extension's identifier must stay prefixed by the app's.
3. Change the iCloud container to one you own. It appears in **three** places
   and all three must match:
   - `Configuration/BrainBuddy.entitlements` →
     `com.apple.developer.icloud-container-identifiers`
   - `BrainBuddy/App/PersistenceController.swift` →
     `cloudKitContainerIdentifier`
   - the CloudKit capability in *Signing & Capabilities*
4. Change the App Group the share extension hands off through. It appears in
   **four** places and all four must match:
   - `Configuration/BrainBuddy.entitlements`
   - `Configuration/BrainBuddyShare.entitlements`
   - `BrainBuddy/Services/SharedInbox.swift` → `appGroupIdentifier`
   - `BrainBuddyShare/ShareViewController.swift` → `appGroupIdentifier`

   If the App Group isn't set up, everything else still works — Settings ›
   Sharing says so explicitly instead of dropping shares on the floor.

The Simulator runs everything except the document scanner (no camera), and
reaches iCloud only if the simulator is signed in to an Apple Account.

### Tests

```bash
xcodebuild test -scheme BrainBuddy -destination 'platform=iOS Simulator,name=iPhone 16'
```

The suite covers the parts worth pinning down: tokenizer normalization and
stemming, BM25 scoring and IDF non-negativity, vector math and the embedding
blob round-trip, hybrid ranking behavior, answer phrasing, link-vs-note
detection and link titling, and a SwiftData schema smoke test (in-memory, no
iCloud).

---

## Layout

```
BrainBuddy/
  App/          BrainBuddyApp, AppServices (shared singletons), PersistenceController
  Models/       MemoryItem, MemoryAttachment, MemoryTag  (SwiftData + CloudKit)
  Search/       Tokenizer, BM25Index, VectorMath, EmbeddingService,
                SearchEngine (hybrid ranking), AnswerComposer
  Services/     IngestService (the one capture path), TextAnalysis, TextRecognizer,
                PDFTextExtractor, AudioRecorder, SpeechTranscriber, SpeechSpeaker,
                AudioPlayerController, CloudSyncMonitor
  Services/     … SharedInbox (App Group hand-off from the extension)
  Views/        RootView, CaptureView, VoiceCaptureView, LibraryView,
                MemoryDetailView, AskView, SettingsView, Components/
  Resources/    Assets.xcassets, PrivacyInfo.xcprivacy
BrainBuddyShare/  ShareViewController — the share extension
BrainBuddyTests/
Configuration/  entitlements for both targets + the extension's Info.plist
```

The ranking layer is deliberately free of SwiftData and UIKit: `SearchEngine`
works on plain `SearchDocument` values, with a thin adapter in
`Search/MemorySearch.swift` bridging stored `MemoryItem`s. That is what makes
search behavior testable without a device or a container.

---

## Known limits

- **Search loads all memories into memory to rank them.** Fine into the tens of
  thousands of notes; past that, the BM25 index should be persisted rather than
  rebuilt from a full fetch. The index is already cached between searches and
  invalidated by a corpus signature.
- **PDF OCR is capped at 40 pages** per document so importing a huge scan can't
  hang. The text layer, when present, is never truncated.
- **Embeddings are English-first.** `NLEmbedding` falls back across languages
  and then to word-vector averaging; if the OS has no model at all, search
  degrades to keyword-only rather than failing.
- **Shared items import when you next open the app**, not at share time — that's
  the deliberate consequence of keeping OCR and embedding out of the extension.
  Settings › Sharing shows anything still waiting.
- **The app icon is a generated placeholder.** Replace
  `BrainBuddy/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
  before shipping.
