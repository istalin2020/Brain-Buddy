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
| **Dictation** | A mic inside the capture box types what you say into the note as you say it, so you can speak a thought and still edit it before saving. Distinct from a voice note: this is a keyboard, that keeps the recording. It runs continuously — pause for a minute if you like, nothing already dictated is lost — and only you end it. |
| **Voice** | Recorded to AAC, saved immediately, then transcribed with `SFSpeechRecognizer` (on-device when available). Keeps recording with the screen off, so you can capture a whole discussion. Afterwards you get the transcript, and can turn it into a saved summary. |
| **Image** | Photo library or camera. Text is pulled out with Vision OCR so photos are searchable by their contents. |
| **Scan** | VisionKit's document scanner — edge detection and perspective correction, then OCR per page. |
| **PDF** | Text layer extracted with PDFKit. If the PDF is a scan with no text layer, pages are rasterized and OCR'd. |
| **Link** | A capture that is only a URL becomes a link with a readable `host — slug` title instead of a raw address. |
| **Siri / Shortcuts** | *"Hey Siri, remember this in Brain Buddy."* The sentence is queued and the app never has to open — see below. |
| **Share sheet** | "Brain Buddy" appears in any app's share sheet — links, selected text, photos, PDFs, files. |
| **Anything else** | Stored intact with its filename indexed, rather than refused. |

**Two buttons, one meaning each.** The capture box carries a **mic** and, next
to it, a button that is either **✓** or **↑** — and there is no Save in the
toolbar, because saving belongs where you are already looking. Idle, the pair
reads *speak* and *save*. Tap the mic and it becomes a waveform while the tick
takes its place: **✓ accepts what you said into the box**, and only then does the
button turn back into **↑ to save**.

Accepting and saving are deliberately two decisions. A dictated sentence almost
always has one word the recognizer got wrong, and a single button that stopped
listening *and* filed the note would save it before you had a chance to fix it.
Tapping the waveform finishes the same way the tick does, so no gesture on this
screen can lose words you have already spoken.

**The same thing saved twice is saved once.** Every door into this app favours
never losing a capture over never repeating one — the share extension and the
Siri queue both delete their file only *after* the memory exists, so an
interrupted import re-runs and arrives twice. The cost was a library holding
four copies of one screenshot, and, worse, the same document filed under two
different regions. `CaptureFingerprint` now identifies a capture by its
**normalized words**, not its bytes: two screenshots of one message differ by the
clock in the status bar and agree on every word, and a PDF re-exported has new
bytes and the same text. Words first, bytes only when there are none (a photo of
a sunset), and nothing at all when there are fewer than five words — a scrap of
OCR is not enough to declare two things the same. A duplicate says so on screen
and names what it matched, rather than silently doing nothing.

**Documents are read when they arrive.** A scan, a PDF, a screenshot or a
recording lands as a wall of text with no shape to it, and leaving that until
somebody presses *Create summary* made the library a list of first lines. Now the
summary is written at capture and marked as the app's own work — searchable and
readable immediately, but **kept out of your morning brief** until you press
*Use this in my brief*. That is the same rule OCR text already lived under:
nobody agreed to it, so it cannot hand you a task to tick off.

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

### The morning brief

**Seven reminders a day** and a **Today** tab holding a brief built from what you
already captured.

The first fires at 8:00 and frames the day; the other six are single nudges spread
evenly to 9pm, each naming one thing that's still open. They're dealt from your
open lines shuffled and without repetition, refilling from a fresh shuffle when
there are fewer open items than slots — so three tasks cycle across seven
reminders rather than one being repeated all day. Both the start time and the count
(1–12) are in Settings › Morning brief.

A notification's text is fixed when it's scheduled — iOS doesn't wake the app at
fire time to ask what to say — so the whole set is rebuilt whenever the brief
changes: after a rebuild, after you close or remove a line, and when the app
returns to the screen. Between those moments a reminder can name something you've
since dealt with. That's the cost of the system not asking, and it's stated in
Settings rather than hidden.

What's in the brief:

| Section | Where it comes from |
| --- | --- |
| **Today's schedule** | Dates that land on today, quoted as the sentence you wrote them in. A note from last month saying "quarterly review on the 14th" is exactly what this is for, so this ignores how old the capture is. |
| **Tasks** | Anything still owed, from the last two months. **Every short typed note counts** — that is what a quick capture box is for, and *"EOT submission"* or *"Haffaf Muscat drawing status"* will never phrase itself as a commitment. In longer text and transcripts, a line has to look like work: an **instruction** (*"Send the revised drawings"*, including after a comma — *"Leap meeting, study the stringing execution"*), an **obligation** (*"Method statement to be reviewed by the agency"*), or a first-person commitment. Tag `#todo` to force something in, `#note` to keep it out. |
| **Key points** | Key points out of discussions you summarized in the last week. |

**Long lines get a subject.** A quoted sentence of eighty words is accurate and
useless in something you read standing up, so a long brief line is headed by a
short subject with the exact quote underneath. The subject is derived the same way
a voice note's title is — see below — and is never generated, so it can't claim
the recording was about something nobody mentioned.

**Only what you said feeds the brief.** Text a machine extracted — OCR off a
photo, a PDF's text layer — is reference material, not a commitment. A scanned
lab report contains no tasks, and its printed timestamps are not your calendar;
reading them as one filled a brief with rows like *"2 - 2.54" at 2:00 PM*. So a
line can only come from what you typed, dictated or spoke, or from a summary you
reviewed and saved. To get something out of a document and into your brief, write
it down or summarize the document.

Date detection is correspondingly strict about **bare clock times**.
`NSDataDetector` resolves a time with no day attached against the present moment,
so `12:05` in anything at all reads as an appointment today. A time only counts if
the match names a day too — a weekday, a month, `29/07/2026`, "tomorrow" — or if
the note itself was written today, where "call at 4" plainly means this afternoon.

Every line has a circle you tap to **close** it, or leave open. Closing survives
relaunching and syncs to your other devices, because a brief you can't tick off
is just a search result. Swipe for the same thing, plus *Remove* for a line that
turned out not to be a task at all.

What you closed today collects in a **Completed today** section at the bottom,
collapsed to a count and one tap from being expanded — so ticking something off
gives you the satisfaction of seeing it done, and a way back if you were too
quick. It keys on when a line was closed rather than which day's brief it came
from: a task carried over from last week and ticked this morning was completed
*today*, and filing it under last week is how it would vanish with no way to
reopen it.

**Edit the note and the line changes with it.** A brief was a snapshot of what
a note said the morning it was first noticed, so correcting a figure from 54,000
to 60,000 left Today quoting 54,000 for as long as the line stayed open — worse
than showing nothing, because it looks like a fact you can tick off. Lines are
now matched against the note's current wording and **updated in place**: what
you closed stays closed, a carried-over task keeps its history, and a rewritten
note retires its old line and gets a new one. It runs the moment you finish
editing — including when you leave the screen without pressing Done, which is a
real thing people do — and on **every open and return to the foreground**, not
only on Refresh. "Today's brief is already built" stops new lines being proposed
twice in a day; it must not stop existing ones catching up, which is exactly how
an edit at 11:34 stayed invisible behind a brief built at 11:26.

Timestamps are the fast path, not the truth: a line is also re-read when its own
words are **no longer in the note**, compared on normalized tokens. That catches
an edit merged in from another device, a line written by an older build, or an
`updatedAt` that never moved — and because tidying punctuation leaves tokens
identical, a tidied line never looks edited and can't reconcile on a loop.
Two rules stop it doing damage — a note that yields nothing the builder
recognizes has its lines *left alone*, and a line is only retired if its own
section still produces others. Losing a task you were relying on is far worse
than showing it with stale wording.

**Lines are presented, not just quoted.** The words are yours, verbatim; the
punctuation debris of typing on a phone is not meaning. Doubled full stops
become one ellipsis, a space before a comma closes up, and a line never ends on
a dangling *"with"*. Anything over about forty-five characters gets a short
heading with the exact quote underneath — and a heading has to be *meaningfully*
shorter than the line, or it's the same sentence twice, once in bold. A comma is
only a clause break when whitespace follows it, so *"…the sparing work with
60,000 Omani rial"* can never be headed *"…with 60"*: same class of bug as a
decimal point ending a sentence, and the same reason it matters — a number that
quietly loses four digits reads as a fact.

**One memory, one line.** A scanned meeting invitation used to produce five
rows — the jury round, the schedule, how the session runs, and two restatements
of the same thing — which is one thing to know, reported five times, pushing
everything else off the screen. A brief is a list of things, not a list of
sentences. Which line survives is decided by what a morning needs first:
something happening today beats something to do, which beats something to bear
in mind. Briefs built before this rule collapse themselves the next time you open
the app, and a line you already closed is never collapsed away — ticking
something off is a decision, and the record of it is not a duplicate.

**A line has to say something.** *"29th September mostly 11:50 AM"* is a date, a
filler word and a clock reading; it is true, it was in the transcript, and it is
no use to anyone reading their morning brief. A task or key point now needs at
least two words that are not digits, dates or filler. And the subtitle says how
something reached your brain as a phrase rather than two labels bolted together
with a dot: *Recorded yesterday*, *Noted on Tuesday*, *Photographed 4 Sep*.

Anything you leave open shows up again the next day under **Still open from
before**, with the date it came from — one row with one history, not a fresh copy
every morning. It keeps coming back until you close it, which is the point.
Anything you close stays closed and doesn't come back. **Refresh** in the header
picks up whatever you captured since the brief was built; it only ever adds, and
it says what it did — *"Added 2 new lines"*, *"Nothing new to add"* — because
"added nothing" and "the button is broken" are otherwise indistinguishable.

The inclusive reading of what counts as a task is deliberate, and asymmetric on
purpose: a false positive costs one swipe to Remove, a false negative costs the
thing you were trying not to forget. A dated line
is the exception: standup on Tuesday and standup on Wednesday are the same
sentence and two different occurrences.

**On "generated at 8 am".** iOS gives no app a guaranteed slot to run at a fixed
time. Rather than pretend otherwise, the 8 am *notification* is the alarm — that
part the system delivers reliably, whether or not you've opened the app in weeks —
and the brief is built the moment you open it, stamped with when that was.
Building it reads only local data and takes milliseconds, so opening the
notification and reading the brief are one gesture. The time is adjustable in
Settings › Morning brief, and permission is asked for the first time the Today tab
is on screen rather than as a cold prompt at first launch.

### Recording a discussion

Voice capture is built for the long case, not just the ten-second reminder:

- **The screen can go off.** Recording continues when the phone locks or you
  switch apps. A phone call pauses it and it resumes by itself afterwards.
  Settings › Voice recording turns this off, and "off" means *pause* — you never
  lose what was already captured, you just stop capturing while you're away.

  This rests on one plist key, `UIBackgroundModes` containing `audio`, which is
  why the app ships an explicit `Configuration/BrainBuddy-Info.plist` instead of
  a generated one: the key has to be an **array**, and a build setting holding a
  space-separated string is not reliably one. Get it wrong and there is no build
  error — iOS just suspends the app a few seconds after it leaves the screen, so
  recording looks like it stopped and then resumed when you came back. Settings ›
  Voice recording reports whether the running build actually has it, read back
  from the bundle rather than assumed, and the recorder pauses deliberately
  rather than being frozen mid-word if it's missing.
- **Long audio is transcribed in full.** `SFSpeechURLRecognitionRequest` is built
  for utterances and gives up somewhere past a minute, so recordings are sliced
  into 45-second segments and transcribed one at a time, with progress shown. One
  unintelligible minute is skipped rather than losing the other thirty-nine.
- **You choose the spoken language, and how accurate to be.** Settings ›
  Transcription. Both matter more than they sound:
  - A recognizer set to the wrong language doesn't fail, it *spells what it hears*
    as words from the language it expects. Tamil through an `en-GB` recognizer
    comes back as confident English nonsense. If you mix English into another
    language — as most bilingual speakers do — the regional variant (`en-IN`,
    `ta-IN`) is usually the best single choice.
  - The on-device model is built for short dictation and degrades badly on a long
    multi-speaker recording; no amount of segmenting fixes that. **Higher accuracy
    transcription** uses Apple's speech servers instead, and is the one thing in
    this app that sends your data anywhere. Off by default, named plainly.
- **A recording gets a subject, not its first sentence.** Transcribed speech has
  no title in it, and taking the opening seventy characters names a memory after
  its throat-clearing — *"I would like to know when I we are going to leave from
  home and we…"*. `Headline` derives one instead, in order: a **commitment** with
  its scaffolding stripped ("Close the excess tower material approval from PCH"),
  otherwise the **recurring subjects** ("Home, gold, place"), otherwise the most
  informative sentence. Still extractive — words that were said, minus the filler
  in front of them. A title you typed always wins over a derived one, and you can
  always edit it.
- **Playback has a real timeline.** Drag to scrub, ±15 seconds, `h:mm:ss` past the
  hour. Transcription will always get some of a long conversation wrong, so the
  recording is the source of truth — being able to jump to the part you
  half-remember is what makes it checkable.
- **You see the transcript before you leave.** The recording is saved *first* —
  a crash or a failed transcription can never cost you the audio — and then the
  transcript appears with a **Create summary** button.
- **Summaries are extractive and opt-in.** Key points and follow-ups (anything
  somebody committed to: *have to*, *will*, *let's*, *priority*) are pulled out as
  verbatim sentences. Nothing is generated, so a summary can't invent a decision
  nobody made. It is a draft until you press **Save**, and saving indexes it — so
  a two-hour meeting becomes findable by the three things that mattered in it.

Any long memory can be summarized later, too: open it and the Summary section is
there, including for OCR'd scans and imported PDFs.

**Documents are not transcripts, and are prepared differently.** The summarizer
was built for speech — a wall of sentences. A scanned email or an agenda arrives
already bulleted and labelled, and feeding that in raw produced summaries reading
`• • Date & Time:` with lines that were nothing but `Jury Panel:`. Two rules fix
both: list markers are stripped (they're the source's formatting; the summary
adds its own), and **a label is joined to its value** — "Date & Time:" is not a
key point, "Date & Time: Wednesday 9 September, 11:30" is. A trailing label with
nothing under it is dropped.

**And it says each thing once.** Plain overlap missed the common case: *"Your
jury round is scheduled"* and *"Your AI Hackathon Jury Round — Wed, 9 Sep,
11:30"* share two words out of ten, scored as different points, and both
appeared. Containment catches it — the shorter line is almost entirely inside the
longer one — with a two-word floor so a pair of short lines can't merge on one
coincidence. Subjects are filtered too: *"Topics: Jury, Sep, idea, minutes"* was
half date and filler, and a date is not what something was about.

### Siri, Shortcuts and iPhone Search

Two ways in and out of your brain that don't involve opening the app.

**"Hey Siri, remember this in Brain Buddy."** The thought is caught at the moment
you have it — walking, driving, halfway out the door — and that moment does not
survive unlocking a phone, finding an app and waiting for a store to open. So the
App Intent does the least possible work: it appends the sentence to a folder and
returns. The app drains that folder on its next foreground pass, through the same
`IngestService` path everything else uses, so a thought muttered at a traffic
light gets the same title, keywords and embedding treatment as one typed at a
desk. Nothing you say is ever waiting on a spinner, and nothing is lost if the
intent's process is killed the moment it answers.

Unlike the share extension's hand-off this queue lives in the app's **own**
container rather than an App Group — nothing to configure, so it works in a fresh
clone with no entitlements set up. Settings shows the count if anything is ever
waiting, and offers to file it now.

Two more phrases are registered: *"Ask Brain Buddy…"*, which opens the app with
the question already run, and *"What's on today in Brain Buddy"*, which opens
your brief. Those two need the whole retrieval stack, so they open the app; the
one that matters most — capture — does not.

**Your notes also turn up in iPhone Search.** Pull down on the Home Screen, type
"cladding", and your own note is in the results next to your apps and your mail;
tapping it opens that memory in the Brain tab. This is the difference between an
app you have to remember to open and a brain that is simply *there*. Publishing
happens at `IngestService.finalize` — the single point every capture and every
edit passes through — so an edited note can never leave a stale entry behind, and
trashing one removes it immediately. The index is local to the device and carries
a title, a short summary and keywords: never attachments, never full transcripts.
Settings has the switch, and turning it off actually deletes what was published
rather than merely stopping new donations.

### Connections

Open any memory and the memories that belong with it are already there, each
with the reason it was linked: *"Both tagged #site"*, *"Both mention cladding"*,
*"Reads like the same subject"*.

This is the part a folder can't do. You save a note in March and record a
discussion in July and never connect them, because remembering to connect things
is the work you downloaded a second brain to avoid. `ConnectionFinder` uses three
signals, in order of how much they mean:

1. **Shared tags** — you chose those words yourself, so nothing else is that
   deliberate.
2. **Shared uncommon words**, weighted by how rare they are *in your own
   library*. This is what separates a real link from a coincidence: two notes
   containing "cladding" are about the same thing, two notes containing "project"
   are not. Rarity is measured against your library rather than a general word
   list, because the words that mean nothing in *your* notes are the ones you
   write constantly — a word appearing in half of everything you've saved is
   furniture, and is ignored outright.
3. **Meaning**, from the sentence embeddings already stored for search, with a
   floor under it: unrelated English prose sits around 0.5 cosine, so anything
   short of clearly-similar has to count for nothing.

Weak links are **dropped rather than padded out** to fill the section. A wrong
connection costs more than an empty space, because it teaches you not to trust
the ones that are right. Scoring runs off the main actor over flattened
`Sendable` values — the model objects never cross the boundary.

### The review

Today answers *"what now"*. The **Review** — one tap from Today, over 7 or 30
days — answers *"how is this actually going"*, and it is the one thing in the app
that speaks without being asked a question. So it has to earn the interruption:
no streaks, no vanity metrics, no "you're doing great". Four things you can act
on:

- **Done** — what you closed, because closing things is invisible otherwise.
- **Still open** — oldest first, with how long each has been sitting there. The
  age is the useful number: a task open for nine days is a decision you have been
  avoiding, and saying so is more useful than listing it.
- **What you kept coming back to** — the subjects that recur across the period's
  captures, which is usually not what you would have guessed.
- **Questions you left hanging** — sentences you typed that end in a question
  mark and never came back to. People note questions constantly and never revisit
  them; a second brain that can't hand them back is losing the most valuable
  thing it holds. Deliberately literal: a derived "this looks like a question"
  would be wrong often enough to be annoying, and a typed question mark is you
  saying so outright.

It shares as **plain text**, because the useful thing to do with a review is
paste it into the message you were already about to write.

### The brain

The **Brain** tab is a brain: a 3D model you turn with a drag, zoom with a
pinch, and tap to open a region.

It replaced a grid of boxes, which is a filing cabinet with the doors painted
on. The point of the model is that **position is an index** — the fastest one a
person has, and the one a list can never use. So every region sits where the
cortex actually does that job, and after two visits you stop reading labels and
just point:

| Region | Where it sits | Why there |
| --- | --- | --- |
| **Work** | Frontal lobe | The part that plans things. Sub-divided into **Email**, **Reminders** and **Notes**, because work is always too big to be one room. |
| **Family** | Limbic core | The emotional-memory structures, in the middle, half-hidden behind everything else. |
| **Friends & relatives** | Parietal lobe | Social cognition lives around the temporoparietal junction. |
| **Images** | Occipital lobe | The visual cortex, at the back of the head. |
| **Video & voice** | Temporal lobe | The auditory cortex, out to the side. |
| **General** | Cerebellum | Everything that didn't need a room of its own. |

**The surface is generated, not downloaded.** There is no mesh file in this
repository and there shouldn't be — a scanned brain is tens of megabytes, needs
a licence, and has to be re-exported every time the look changes. `BrainMesh`
builds it from a formula: an ellipsoid at roughly cerebral proportions, folded
by three layers of sine waves into gyri, with the **longitudinal fissure** cut
deliberately down the midline (that single groove is what separates a brain from
a blob), a tapered forehead, a temporal bulge and a flattened underside. Then a
cerebellum with tight parallel ridges, and a stem.

It is drawn twice over: a translucent additive volume so the shape reads as
solid, and a **wireframe** over the top so it reads as *drawn*. Either alone
looks like a mistake; together they look like a hologram. A pulsing core in the
middle does real work — it separates the near surface from the far one when
everything is lines — and the camera has bloom turned up so the bright parts
glow.

**Every document is wired to it.** One node per memory, on a filament running
back to the part of the cortex it was filed under, arranged on a golden-angle
spiral around its region's direction so clusters stay evenly dense and each
document keeps its place between visits — which is the entire point of putting
them in space. Zoomed out, that reads as a shape with a nervous system.

**Zoom in and the near nodes say what they are.** Names appear on the nodes
closest to the camera, by distance rather than by zoom level, so a crowded region
reveals itself gradually and turning the brain reveals whatever came forward.
Tap a node and its document opens in the list below — the region switches to
follow it and the row scrolls to you, because a list that silently expanded
something below the fold would look like nothing happened.

Under the model the same six regions appear as chips, dimming everything that
isn't the one you picked. That is not a duplicate control: a node is a small
target, some sit behind the brain until you turn it, and VoiceOver cannot tap a
mesh. The chips are the accessible, one-handed path to the same place.

**Three steps to a document, each a bigger commitment than the last.** The model
or the list gives you names and dates. Tap a name and its key summary opens
underneath it. Tap the summary and the whole note opens on its own page. That is
what stops a region holding thirty files from being thirty paragraphs.

**One category per memory, and a long document has to earn it.** In six words,
one match is the subject; in six hundred, one match is a coincidence — and it
was: two scans of the same bank message landed in two different regions because
one of them contained a family word exactly once. Past sixty distinct words a
document has to say it twice, which is what keeps near-identical things filed
together.

**Filing is explainable, and you can overrule it.** `BrainClassifier` runs three
passes: a `#tag` you typed settles it outright; then what the thing *is* (a photo
goes to the visual cortex whatever it is about, or the map stops feeling
consistent); then what it *says*, against a small lexicon per region, with the
most hits winning and nothing forced anywhere — unmatched memories go to General.
Both sides of every word comparison are stemmed to a fixpoint, because the search
stemmer applies one rule per word: `"meetings"` stops at `"meeting"` while the
lexicon's `"meeting"` becomes `"meet"`, and compared directly they would never
match. Classification runs off the main actor and only when the library or the
filter changes.

**No search box — a date filter instead.** Ask is the search; this screen answers
*"what was I doing in August"*. Pick **Day**, **Month** or **Year** and the row
underneath fills with the periods you actually captured in, newest first (a month
with nothing in it isn't worth a tap, and scrolling real months beats guessing in
a date picker). The filter feeds the model itself: regions shrink, swell and
empty as you move through time.

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

**Numbers are treated as numbers.** A period between two digits is a decimal
point, not a sentence break — so a lab row reads back as `TSH 5.46 0.270 - 4.20
uIU/mL`, and `5.46` is one searchable token rather than a `5` and a `46`.
Getting this wrong is worse than finding nothing: `TSH 5` looks like an answer.

**Which line gets quoted is its own ranking problem.** Counting matched words
picks the wrong line surprisingly often: *"what is my TSH value from the latest
report"* matches `report` on three header lines of a lab report and `tsh` on one
result row, so counting alone answers with a date. The line picker therefore
weights each matched term by how rare it is — within the document, and across
everything you've saved — then rewards the **label-then-value** shape, where a
matched term sits immediately before a number. `TSH 5.46` has it; `Reported Date
: 29/07/2026` doesn't. A bare label is joined to the line beneath it, because OCR
splits table rows into separate observations more often than you'd like.

Words like *latest*, *recent* and *most* are stripped from questions along with
the rest of the conversational filler: they say which result you want, not what
it's about, and ranking already applies a recency boost.

Tap the microphone and the same pipeline runs on live dictation. The composed
answer is **extractive** — it quotes what you actually stored, with a "from your
note yesterday…" preamble. It never generates prose, so it can't tell you
something your notes don't say.

**Answers are silent.** They appear as text, and a **Read aloud** button hands
that text to `AVSpeechSynthesizer` when *you* ask for it. An app that starts
talking the moment you look something up is unusable in a meeting, on a train, or
next to someone asleep. Settings can flip it back to speaking automatically.

Asking also empties the question box, so the next question doesn't need the last
one cleared out by hand — the question you asked stays on screen above the answer.
That makes search explicit (press return, tap the mic, tap a suggestion) rather
than debounced on every keystroke; a box that clears itself can't also be
searched as you type it.

### iCloud sync

SwiftData mirrors to the **private** CloudKit database
(`iCloud.com.brainbuddy.app`). The Settings tab surfaces real account status,
storage mode, and when the last remote change arrived — because silent sync
failure is the worst possible outcome for a second brain.

If CloudKit can't be initialized the app falls back to a local store, then to an
in-memory store, and says so in Settings. It never refuses to launch.

### Privacy

Transcription, OCR and embedding all run on-device by default. Nothing is sent to
any server other than Apple's iCloud, and there are no third-party SDKs,
analytics, or network calls of our own.

The one exception is opt-in and off until you turn it on: **Settings ›
Transcription › Higher accuracy** hands recordings to Apple's speech servers,
because the on-device model is not good enough for a long multi-speaker
conversation. Leaving it off keeps everything local at the cost of accuracy —
that trade is yours to make, which is why it's a switch and not a default.

---

## Building it

Requires **Xcode 16 or newer** (the project uses file-system-synchronized
groups) and an iOS 17+ device or simulator.

```bash
open BrainBuddy.xcodeproj
```

Then, before running on a device:

1. Select the **BrainBuddy** target → *Signing & Capabilities*. Set your **Team**
   on both the **BrainBuddy** and **BrainBuddyShare** targets. Confirm
   **Background Modes → Audio** is ticked; Settings › Voice recording inside the
   app tells you whether the build you're running actually has it.
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
detection and link titling, summarizer behavior (including the property that
matters most — every summary line is quoted verbatim from the transcript), what
lands in a morning brief and what's correctly left out of it, the stored-summary
round trip the brief depends on, recognising a capture that has arrived before,
the one-line-per-memory rule and the clean-up that applies it to briefs built
without it, what a summarizer does with a bulleted document and how it avoids
saying the same thing twice, the reconciliation that rewords a brief line
when its note is edited (and the guards that stop it deleting one), the
presentation rules that keep a thousands separator out of a headline, which
region of the cortex a memory is filed in (and the stemming fixpoint that makes
its lexicons work at all), the day/month/year filter, which memories land in
which brain box (and
which subjects are too rare to earn one), the row-summary rule that stops a
heading being repeated underneath itself, which links `ConnectionFinder` will and
won't make (including the one that matters — a word you write constantly links
nothing), what a review reports over a fixed period, the Siri capture queue's
never-lose-anything contract, what is and isn't published to iPhone Search, and a
SwiftData schema smoke test (in-memory, no iCloud).

`BriefBuilder` is tested against a fixed calendar date, so "what shows up in
tomorrow's brief" is pinned down rather than dependent on when the suite runs.

---

## Layout

```
BrainBuddy/
  App/          BrainBuddyApp, AppServices (shared singletons), PersistenceController,
                BrainBuddyIntents (Siri / Shortcuts + the hand-off mailbox)
  Models/       MemoryItem, MemoryAttachment, MemoryTag, BriefEntry  (SwiftData + CloudKit),
                BrainRegion (the cortex map), BrainBox (subject grouping for the review)
  Search/       Tokenizer, BM25Index, VectorMath, EmbeddingService,
                SearchEngine (hybrid ranking), AnswerComposer
  Services/     IngestService (the one capture path), TextAnalysis, TextRecognizer,
                PDFTextExtractor, AudioRecorder, SpeechTranscriber, SpeechSpeaker,
                DiscussionSummarizer, Headline, AudioPlayerController,
                CloudSyncMonitor
  Services/     … BriefBuilder (what goes in a brief) + BriefService (persistence
                and keeping lines in step with edited notes), BriefText (presentation),
                NotificationScheduler, NotificationRouter
  Services/     … SharedInbox (App Group hand-off from the extension),
                QuickCaptureQueue (Siri hand-off), SpotlightIndexer (iPhone Search),
                ConnectionFinder (automatic links), ReviewBuilder (the review),
                BrainClassifier (which region a memory lands in), PeriodFilter,
                CaptureFingerprint (the same thing, saved twice)
  Views/        RootView, TodayView, ReviewView, CaptureView (Input),
                VoiceCaptureView, BrainView (the 3D brain) + TrashView,
                MemoryDetailView, AskView, SettingsView,
                Components/ (incl. BrainMesh — the surface as a formula —
                and BrainSceneView — the hologram, the wiring and the labels)
  Resources/    Assets.xcassets, PrivacyInfo.xcprivacy
BrainBuddyShare/  ShareViewController — the share extension
BrainBuddyTests/
Configuration/  entitlements + Info.plist for both targets
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
- **Segment boundaries can clip a word.** Long recordings are split every 45
  seconds with no overlap, so a word straddling a boundary may lose a syllable.
  Overlapping the slices would duplicate whole phrases instead, which reads worse.
- **Continuous dictation rolls the recognizer over between passes.** iOS
  finalizes a recognition pass whenever you pause and caps a single pass at
  roughly a minute, so long dictation starts a fresh pass and banks the previous
  text. The audio engine keeps running across the swap, but a word spoken in the
  few milliseconds it takes can still be clipped.

  Worse, it doesn't always *say* a pass ended: on-device recognition will quietly
  begin a new utterance inside the same task, with no `isFinal` and no error, just
  a shorter transcript. So banking is triggered by the text itself — a result that
  doesn't extend the previous one is treated as a new utterance. Continuity is
  judged on words, tolerant of the recognizer revising its own tail ("by two" →
  "buy 2"), and a result whose first word differs or which loses most of its
  length is a restart. A genuinely new utterance that happens to begin with the
  same word as the last one can lose a word or two at the seam.
- **Summaries have no speaker labels.** `SFSpeechRecognizer` doesn't diarize, so a
  two-person discussion transcribes as one voice. Key points and follow-ups are
  quoted correctly; who said them isn't recorded.
- **Background recording needs the app to have been foregrounded to start.** iOS
  won't let a suspended app begin recording — start it, then lock the screen.
- **The brief is built on open, not at 8 am.** See above; the notification is what
  the system guarantees, not the computation.
- **Date detection is `NSDataDetector`, so it's as good as your phrasing.** "Review
  on the 14th at 3pm" is found; "review next time we meet" isn't a date and won't
  be treated as one.
- **Briefs can duplicate a line across devices.** Two phones that both build
  today's brief before iCloud has synced the other's entries will each add it. The
  duplicate is visible and closable rather than silent, which is the better failure
  for a checklist.
- **The app icon is a generated placeholder.** Replace
  `BrainBuddy/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
  before shipping.
