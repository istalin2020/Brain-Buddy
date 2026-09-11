import SwiftUI

/// One region of the cortex, and the kind of memory it holds.
///
/// The mapping is not decoration. Each region sits where the brain actually
/// does that job — images in the visual cortex at the back, recordings in the
/// auditory cortex at the side, work in the frontal lobe that plans things —
/// so the model teaches you where your own things live after about two visits.
/// That is the whole reason for showing a brain rather than a grid of boxes:
/// **position becomes memory.** A grid has to be read; a shape can be pointed at.
enum BrainRegion: String, CaseIterable, Identifiable, Sendable {
    /// Frontal lobe — planning, deadlines, decisions.
    case work
    /// Limbic core — the emotional-memory structures, sitting in the middle.
    case family
    /// Parietal, around the temporoparietal junction — social cognition.
    case friends
    /// Occipital lobe — the visual cortex.
    case images
    /// Temporal lobe — the auditory cortex.
    case media
    /// Cerebellum — everything that didn't need somewhere special.
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Work"
        case .family: return "Family"
        case .friends: return "Friends & relatives"
        case .images: return "Images"
        case .media: return "Video & voice"
        case .general: return "General"
        }
    }

    /// Short enough for a chip under the model.
    var shortTitle: String {
        switch self {
        case .friends: return "Friends"
        case .media: return "Video"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .work: return "briefcase"
        case .family: return "house"
        case .friends: return "person.2"
        case .images: return "photo"
        case .media: return "play.rectangle"
        case .general: return "circle.grid.2x2"
        }
    }

    /// The anatomy, named on screen. It is what makes the position learnable
    /// rather than arbitrary.
    var anatomy: String {
        switch self {
        case .work: return "Frontal lobe"
        case .family: return "Limbic core"
        case .friends: return "Parietal lobe"
        case .images: return "Visual cortex"
        case .media: return "Auditory cortex"
        case .general: return "Cerebellum"
        }
    }

    var blurb: String {
        switch self {
        case .work: return "Where the brain plans — so this is where work lives."
        case .family: return "The emotional-memory core, in the middle of everything."
        case .friends: return "Social cognition sits here. So do the people in your life."
        case .images: return "The visual cortex. Photos and scans, at the back of the head."
        case .media: return "The auditory cortex. Recordings and video, at the side."
        case .general: return "Everything that didn't need a room of its own."
        }
    }

    var tint: Color {
        switch self {
        case .work: return Color(red: 0.45, green: 0.42, blue: 0.95)
        case .family: return Color(red: 0.95, green: 0.45, blue: 0.55)
        case .friends: return Color(red: 0.95, green: 0.68, blue: 0.35)
        case .images: return Color(red: 0.30, green: 0.78, blue: 0.72)
        case .media: return Color(red: 0.62, green: 0.55, blue: 0.98)
        case .general: return Color(red: 0.55, green: 0.60, blue: 0.70)
        }
    }

    /// The order the chips are shown in: most-used compartments first.
    static let display: [BrainRegion] = [.work, .family, .friends, .images, .media, .general]
}

/// Work is the one region that is always too big to be one room.
enum WorkSection: String, CaseIterable, Identifiable, Sendable {
    case email
    case reminders
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: return "Email"
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .email: return "envelope"
        case .reminders: return "bell"
        case .notes: return "text.alignleft"
        }
    }
}

/// One memory, flattened for classification. Keeps the classifier off SwiftData
/// so "what lands where" is testable without a device.
struct BrainFileInput: Sendable {
    let id: UUID
    let title: String
    /// The concise line shown under the name — see `MemoryItem.listSummary`.
    let summary: String
    /// What the classifier reads.
    let text: String
    let tags: [String]
    let kind: MemoryKind
    let source: String
    let attachmentNames: [String]
    let createdAt: Date

    init(
        id: UUID,
        title: String,
        summary: String = "",
        text: String = "",
        tags: [String] = [],
        kind: MemoryKind = .note,
        source: String = "",
        attachmentNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.text = text
        self.tags = tags
        self.kind = kind
        self.source = source
        self.attachmentNames = attachmentNames
        self.createdAt = createdAt
    }
}

/// A classified memory, ready to render.
struct BrainFile: Identifiable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let createdAt: Date
    let kind: MemoryKind
    let region: BrainRegion
    /// Only ever set for `.work`.
    let section: WorkSection?
}

/// The whole library, sorted into the brain.
struct BrainMap: Sendable {
    var files: [BrainRegion: [BrainFile]] = [:]

    var total: Int { files.values.reduce(0) { $0 + $1.count } }

    func count(_ region: BrainRegion) -> Int { files[region]?.count ?? 0 }

    func count(_ region: BrainRegion, section: WorkSection) -> Int {
        (files[region] ?? []).filter { $0.section == section }.count
    }

    /// Newest first, optionally narrowed to one of Work's rooms.
    func files(in region: BrainRegion, section: WorkSection? = nil) -> [BrainFile] {
        let all = files[region] ?? []
        guard let section else { return all }
        return all.filter { $0.section == section }
    }

    var counts: [BrainRegion: Int] {
        BrainRegion.allCases.reduce(into: [:]) { result, region in
            result[region] = count(region)
        }
    }
}
