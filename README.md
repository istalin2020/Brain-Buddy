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
| **Anything else** | Stored intact with its filename indexed, rather than refused. |

There are no item limits, no character caps, and no subscription gates. Large
payloads use SwiftData's `.externalStorage`, so they live outside the SQLite
file and mirror to CloudKit as `CKAsset`s.

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

1. Select the **BrainBuddy** target → *Signing & Capabilities*.
2. Set your **Team**, and change the bundle identifier from
   `com.brainbuddy.app` to something you own.
3. Change the iCloud container to one you own. It appears in **three** places
   and all three must match:
   - `Configuration/BrainBuddy.entitlements` →
     `com.apple.developer.icloud-container-identifiers`
   - `BrainBuddy/App/PersistenceController.swift` →
     `cloudKitContainerIdentifier`
   - the CloudKit capability in *Signing & Capabilities*

The Simulator runs everything except the document scanner (no camera), and
reaches iCloud only if the simulator is signed in to an Apple Account.

### Tests

```bash
xcodebuild test -scheme BrainBuddy -destination 'platform=iOS Simulator,name=iPhone 16'
```

The suite covers the parts worth pinning down: tokenizer normalization and
stemming, BM25 scoring and IDF non-negativity, vector math and the embedding
blob round-trip, hybrid ranking behavior, answer phrasing, and a SwiftData
schema smoke test (in-memory, no iCloud).

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
  Views/        RootView, CaptureView, VoiceCaptureView, LibraryView,
                MemoryDetailView, AskView, SettingsView, Components/
  Resources/    Assets.xcassets, PrivacyInfo.xcprivacy
BrainBuddyTests/
Configuration/  BrainBuddy.entitlements
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
- **No share extension yet** — importing from other apps goes through the file
  picker. That is the most obvious next addition.
- **The app icon is a generated placeholder.** Replace
  `BrainBuddy/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
  before shipping.
