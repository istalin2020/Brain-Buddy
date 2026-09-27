import XCTest
@testable import BrainBuddy

/// The reader: a question with one answer gets that answer, not a walk
/// through every document that shared a word with it. The fixture is the
/// reported case — "What is my name?" answered with five passages.
final class AnswerExtractorTests: XCTestCase {
    private let note = UUID()
    private let foodNote = UUID()
    private let bankSlip = UUID()
    private let labReport = UUID()
    private let emptyForm = UUID()

    /// The five documents from the reported screen, in the order search
    /// ranked them.
    private var library: [AnswerExtractor.Document] {
        [
            .init(
                id: note,
                authored: "My name is Joseph Stalin, from Tirunelveli district, Tamil Nadu state. I work as an engineer.",
                rank: 0
            ),
            .init(
                id: foodNote,
                authored: "Rough cost per photo (768px downscale). One call returns the food name, portion estimate, calories, protein, fiber, iron, carbs and fat.",
                rank: 1
            ),
            .init(
                id: bankSlip,
                authored: "",
                extracted: "The transaction with the entered reference ID is submitted\nDebit Account Name: JOSEPH STALIN KASPAR Beneficiary Account Number: 000590500004974",
                rank: 2
            ),
            .init(
                id: labReport,
                authored: "",
                extracted: "DEPARTMENT OF LABORATORY MEDICINE\nFile.No : 14397468\nName : JOSEPH STALIN KASPAR\nReport No : 1141055\nTSH 5.46 0.270 - 4.20 uIU/mL",
                rank: 3
            ),
            .init(id: emptyForm, authored: "", extracted: "BADR\nPatient Name\nAge\nSex", rank: 4)
        ]
    }

    // MARK: - The reported case

    func testWhatIsMyNameIsAnsweredWithTheName() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "What is my name?"))
        let answer = try XCTUnwrap(AnswerExtractor.answer(question, in: library))

        XCTAssertEqual(answer.value, "Joseph Stalin")
        XCTAssertEqual(answer.sentence, "Your name is Joseph Stalin.")
        XCTAssertEqual(answer.markdown, "Your name is **Joseph Stalin**.")
    }

    /// Only the documents that say so are sources: the note first, then the
    /// two forms that agree with it. "The food name" and an empty "Patient
    /// Name" label are not evidence of anything.
    func testOnlyTheDocumentsThatSaySoAreSources() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "What is my name?"))
        let answer = try XCTUnwrap(AnswerExtractor.answer(question, in: library))

        XCTAssertEqual(answer.evidence.first?.source, note, "what you wrote about yourself comes first")
        XCTAssertEqual(Set(answer.evidence.map(\.source)), [note, bankSlip, labReport])
    }

    /// Without the note, the forms still answer — agreeing with each other is
    /// what makes a label on a scan trustworthy.
    func testTwoFormsThatAgreeAreEnough() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "What is my name?"))
        let answer = try XCTUnwrap(AnswerExtractor.answer(question, in: library.filter { $0.id != note }))
        XCTAssertEqual(answer.value, "Joseph Stalin Kaspar", "shown the way a person writes it")
    }

    func testANumberNextToItsLabelIsRead() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "What is my TSH value from the latest report?"))
        XCTAssertEqual(question.slot, "tsh value")
        XCTAssertEqual(question.kind, .number)
        XCTAssertEqual(try XCTUnwrap(AnswerExtractor.answer(question, in: library)).value, "5.46")
    }

    func testWithNothingToReadItSaysNothing() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "What is my passport number?"))
        XCTAssertNil(AnswerExtractor.answer(question, in: library))
    }

    // MARK: - Understanding the question

    func testQuestionsWithOneAnswerAreRecognised() {
        XCTAssertEqual(AnswerExtractor.question(from: "who am I?")?.slot, "name")
        XCTAssertEqual(AnswerExtractor.question(from: "What's my blood group")?.slot, "blood group")
        XCTAssertEqual(AnswerExtractor.question(from: "Tell me my phone number")?.kind, .phone)
        XCTAssertEqual(AnswerExtractor.question(from: "When is my dentist appointment?")?.kind, .date)
        XCTAssertEqual(AnswerExtractor.question(from: "How much is the rent?")?.kind, .amount)
        XCTAssertEqual(AnswerExtractor.question(from: "What is the rent?")?.isPersonal, false)
    }

    /// A dictation restart is dropped before the question is read.
    func testADictationRestartIsDropped() {
        XCTAssertEqual(AnswerExtractor.question(from: "My name, what is my name?")?.slot, "name")
    }

    /// A question about a list wants the list — those keep the passage reply.
    func testListQuestionsAreNotOneAnswerQuestions() {
        XCTAssertNil(AnswerExtractor.question(from: "Water, all the things are What all the things are there on my purchase list?"))
        XCTAssertNil(AnswerExtractor.question(from: "What are my reminders?"))
        XCTAssertNil(AnswerExtractor.question(from: "What did I save about the dentist?"))
        XCTAssertNil(AnswerExtractor.question(from: "Show me everything from last week"))
    }

    // MARK: - Reading

    /// How people introduce themselves, in something they wrote — found even
    /// when search never matched the note.
    func testMyselfIsAnIntroduction() throws {
        let answer = try XCTUnwrap(AnswerExtractor.answer(
            AnswerExtractor.Question(slot: "name", isPersonal: true, kind: .name),
            in: [.init(id: UUID(), authored: "Myself Joseph Stalin from Tirunelveli.", rank: nil)]
        ))
        XCTAssertEqual(answer.value, "Joseph Stalin")
    }

    func testIAmGoingIsNotAName() {
        XCTAssertNil(AnswerExtractor.answer(
            AnswerExtractor.Question(slot: "name", isPersonal: true, kind: .name),
            in: [.init(id: UUID(), authored: "I am going to the market at 5.", rank: 0)]
        ))
    }

    func testAFreeTextFactIsCutAtTheEndOfTheThought() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "what's my blood group?"))
        let answer = try XCTUnwrap(AnswerExtractor.answer(
            question,
            in: [.init(id: UUID(), authored: "My blood group is O+ and I donate yearly.", rank: 0)]
        ))
        XCTAssertEqual(answer.value, "O+")
    }

    func testAnAmountKeepsItsCurrency() throws {
        let question = try XCTUnwrap(AnswerExtractor.question(from: "How much is the rent?"))
        let answer = try XCTUnwrap(AnswerExtractor.answer(
            question,
            in: [.init(id: UUID(), authored: "The rent is 400 OMR per month, due on the 5th.", rank: 0)]
        ))
        XCTAssertTrue(answer.value.hasPrefix("400 OMR"), "got \(answer.value)")
        XCTAssertEqual(answer.sentence, "The rent is \(answer.value).")
    }

    // MARK: - Cleaning

    /// A form's value runs straight into the next label.
    func testTheNextLabelIsTakenOffAValue() {
        XCTAssertEqual(
            AnswerExtractor.clean("JOSEPH STALIN KASPAR Beneficiary Account Number: 000590500004974", kind: .name),
            "JOSEPH STALIN KASPAR"
        )
        XCTAssertEqual(AnswerExtractor.dropTrailingLabel("Joseph Stalin Phone"), "Joseph Stalin")
    }

    func testALabelIsNeverAName() {
        XCTAssertNil(AnswerExtractor.clean("Age", kind: .name))
        XCTAssertNil(AnswerExtractor.clean("Patient Name", kind: .name))
    }

    func testAgreementIsWordForWordContainment() {
        XCTAssertTrue(AnswerExtractor.agree("Joseph Stalin", "JOSEPH STALIN KASPAR", kind: .name))
        XCTAssertFalse(AnswerExtractor.agree("Joseph Stalin", "Anil Kumar", kind: .name))
        XCTAssertTrue(AnswerExtractor.agree("+968 9123 4567", "91234567", kind: .phone))
    }
}
