import XCTest
@testable import BrainBuddy

/// Telling voices apart. The numbers here come from the prototype the
/// constants were tuned in, so these tests pin the app to what was measured.
final class SpeakerFeaturesTests: XCTestCase {
    /// One second of a 150 Hz voice-like tone: harmonics falling off as 1/k.
    private var tone: [Float] {
        (0..<16_000).map { n in
            let t = Double(n) / 16_000
            let sum = (1..<20).reduce(0.0) { $0 + (1 / Double($1)) * sin(2 * .pi * 150 * Double($1) * t) }
            return Float(sum * 0.1)
        }
    }

    func testAVoiceIsDescribedTheWayThePrototypeDescribedIt() throws {
        let voice = try XCTUnwrap(SpeakerFeatures.voice(in: tone, range: 0..<16_000))
        XCTAssertEqual(voice.voicedFrames, 96)

        let expected: [Float] = [
            75.193, -22.4481, 8.8474, 13.3747, -10.2577, 5.9629, 5.7224,
            -6.4762, 5.2898, 2.8131, -4.6254, 4.5132, 5.0075
        ]
        XCTAssertEqual(voice.vector.count, expected.count)
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(voice.vector[index], value, accuracy: 0.05, "coefficient \(index)")
        }
    }

    func testItsPitchIsHeard() throws {
        let frames = SpeakerFeatures.voicedFrames(in: tone, range: 0..<16_000)
        XCTAssertEqual(try XCTUnwrap(frames.first).pitch, 16_000 / 107, accuracy: 0.01)
    }

    func testSilenceHasNoVoice() {
        XCTAssertNil(SpeakerFeatures.voice(in: [Float](repeating: 0, count: 16_000), range: 0..<16_000))
    }
}

final class SpeakerClusteringTests: XCTestCase {
    private let deep: [Float] = [70, -20, 9, 12, -9, 5, 5, -6, 5, 3, -4, 4, Float(log(115.0))]
    private let light: [Float] = [64, -15, 5, 15, -11, 7, 3, -4, 6, 1, -3, 5, Float(log(220.0))]

    /// A fixed, made-up variation, so no two utterances sound identical.
    private func wobble(_ base: [Float], _ k: Int) -> [Float] {
        base.enumerated().map { index, value in
            value + 0.3 * SpeakerClustering.scale[index] * Float(sin(Double(k * (index + 1))))
        }
    }

    private func utterance(_ vector: [Float]?, frames: Int = 120, seconds: TimeInterval = 2.5) -> SpeakerClustering.Utterance {
        SpeakerClustering.Utterance(
            voice: vector.map { SpeakerFeatures.Voice(vector: $0, voicedFrames: frames) },
            duration: seconds
        )
    }

    func testTwoDifferentVoicesAreTwoPeople() {
        let utterances = (1...12).map { utterance(wobble($0 % 2 == 1 ? deep : light, $0)) }
        let result = SpeakerClustering.assign(utterances)
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.labels, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1])
    }

    /// The everyday case — a note to yourself — must not come back as a conversation.
    func testOneVoiceIsOnePerson() {
        let result = SpeakerClustering.assign((1...12).map { utterance(wobble(deep, $0)) })
        XCTAssertEqual(result.speakerCount, 1)
        XCTAssertEqual(Set(result.labels), [0])
    }

    /// A word or two from someone else is too little to be sure of.
    func testAShortInterjectionStaysWithTheConversation() {
        let result = SpeakerClustering.assign([
            utterance(wobble(deep, 1), seconds: 3),
            utterance(wobble(deep, 2), seconds: 3),
            utterance(wobble(light, 3), frames: 20, seconds: 0.6),
            utterance(wobble(deep, 4), seconds: 3),
            utterance(nil, frames: 0, seconds: 0.4)
        ])
        XCTAssertEqual(result.labels, [0, 0, 0, 0, 0])
        XCTAssertEqual(result.speakerCount, 1)
    }

    func testNothingToCluster() {
        XCTAssertEqual(SpeakerClustering.assign([]).speakerCount, 0)
    }
}

final class SpeakerTranscriptTests: XCTestCase {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTranscript.Word {
        SpeakerTranscript.Word(text: text, start: start, end: end)
    }

    func testAPauseEndsAnUtterance() {
        let utterances = SpeakerTranscript.utterances(from: [
            word("Hello", 0, 0.4), word("there.", 0.45, 0.9),
            word("How", 1.4, 1.6), word("are", 1.65, 1.8), word("you?", 1.85, 2.2)
        ])
        XCTAssertEqual(utterances.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertEqual(utterances.first?.end, 0.9)
    }

    /// Long stretches are cut, preferring the end of a sentence.
    func testALongUtteranceIsCut() {
        let words = (0..<20).map { index in
            word(index == 7 ? "seven." : "w\(index)", Double(index) * 0.55, Double(index) * 0.55 + 0.5)
        }
        let utterances = SpeakerTranscript.utterances(from: words)
        XCTAssertEqual(utterances.map { $0.text.split(separator: " ").count }, [8, 6, 6])
        XCTAssertTrue(utterances[0].text.hasSuffix("seven."))
    }

    func testTurnsJoinTheSameSpeaker() {
        let utterances = ["One.", "Two.", "Three."].enumerated().map { index, text in
            SpeakerTranscript.Utterance(text: text, start: Double(index), end: Double(index) + 0.5)
        }
        let turns = SpeakerTranscript.turns(utterances, labels: [0, 0, 1])
        XCTAssertEqual(SpeakerTranscript.text(of: turns), "Person 1: One. Two.\n\nPerson 2: Three.")
    }

    private let meeting = """
    Person 1: Shall we start with the drawings for the Muscat site today?

    Person 2: Yes, I will send the revised drawings by Thursday evening.

    Person 1: Good. We agreed to move the site visit to Monday morning.

    Person 2: Fine, and the contractor needs the final quantities before then.
    """

    func testAConversationReadsBack() throws {
        let turns = try XCTUnwrap(SpeakerTranscript.turns(in: meeting, strict: true))
        XCTAssertEqual(turns.map(\.speaker), ["Person 1", "Person 2", "Person 1", "Person 2"])
        XCTAssertEqual(SpeakerTranscript.speakers(in: meeting), ["Person 1", "Person 2"])
    }

    /// A form's labels are not people.
    func testAFormIsNotAConversation() {
        let form = "Name: Joseph\nAge: 40\nName: Anil\nAge: 35"
        XCTAssertNotNil(SpeakerTranscript.turns(in: form))
        XCTAssertNil(SpeakerTranscript.turns(in: form, strict: true))
        XCTAssertNil(SpeakerTranscript.turns(in: "We met at the site. Nothing else was decided."))
    }

    func testRenamingASpeaker() {
        let renamed = SpeakerTranscript.renaming(meeting, from: "Person 2", to: "Anil")
        XCTAssertEqual(SpeakerTranscript.speakers(in: renamed), ["Person 1", "Anil"])
        XCTAssertTrue(renamed.contains("Anil: Yes, I will send"))
    }

    /// Two labels given one name become one person, in the summary too.
    func testGivingTwoSpeakersOneNameMergesThem() {
        let summary = "Speakers: Person 1, Person 2\n\nKey points\n• Person 2: The tender closes on Thursday."
        let merged = SpeakerTranscript.renamingInSummary(summary, from: "Person 2", to: "Person 1")
        XCTAssertEqual(merged, "Speakers: Person 1\n\nKey points\n• Person 1: The tender closes on Thursday.")
    }

    /// A meeting is summarised by speaker: who was there, what was agreed,
    /// and who took on what.
    func testAMeetingSummarySaysWhoSaidWhat() throws {
        let summary = try XCTUnwrap(DiscussionSummarizer.summarize(meeting))
        XCTAssertEqual(summary.speakers, ["Person 1", "Person 2"])
        XCTAssertTrue(summary.followUps.contains { $0.hasPrefix("Person 2: ") && $0.contains("send the revised drawings") },
                      "\(summary.followUps)")
        XCTAssertTrue(summary.decisions.contains { $0.hasPrefix("Person 1: ") && $0.contains("agreed") },
                      "\(summary.decisions)")
        for line in summary.keyPoints + summary.decisions + summary.followUps {
            XCTAssertTrue(line.hasPrefix("Person 1: ") || line.hasPrefix("Person 2: "), line)
        }
        XCTAssertEqual(DiscussionSummarizer.parse(summary.text), summary)
    }
}

final class RecordingTranscriberTests: XCTestCase {
    func testASliceEndsInThePause() {
        // One second of sound, a tenth of silence at 1.5 s, then sound again.
        var samples = [Float](repeating: 0.3, count: 32_000)
        for index in 24_000..<25_600 { samples[index] = 0 }
        let cut = RecordingTranscriber.quietestCut(in: samples, from: 16_000, to: 32_000)
        XCTAssertTrue((24_000...24_000 + 800).contains(cut), "cut at \(cut)")
    }

    func testQuietAudioIsBroughtUpAndSilenceIsSkipped() throws {
        XCTAssertNil(RecordingTranscriber.gain(for: [Float](repeating: 0, count: 8_000)))

        let quiet = (0..<8_000).map { Float(sin(Double($0) / 10)) * 0.07 }
        XCTAssertEqual(try XCTUnwrap(RecordingTranscriber.gain(for: quiet)), 10, accuracy: 0.5)

        let whisper = (0..<8_000).map { Float(sin(Double($0) / 10)) * 0.005 }
        XCTAssertEqual(RecordingTranscriber.gain(for: whisper), 20, "never more than 26 dB")

        let loud = (0..<8_000).map { Float(sin(Double($0) / 10)) * 0.9 }
        XCTAssertEqual(RecordingTranscriber.gain(for: loud), 1, "never turned down")
    }

    func testNoSpeechIsAnAnswerNotAFailure() {
        XCTAssertTrue(RecordingTranscriber.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        XCTAssertFalse(RecordingTranscriber.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1101)))
    }
}
