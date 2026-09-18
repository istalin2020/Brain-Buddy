import SwiftData
import SwiftUI

/// The review: what you finished, what's still open, what you kept coming back
/// to, and the questions you left hanging.
///
/// Built on demand rather than pushed at you on a schedule — a review you didn't
/// ask for is a notification, and this app already has enough opinions about
/// when to interrupt you.
@MainActor
struct ReviewView: View {
    @Query(filter: #Predicate<MemoryItem> { !$0.isTrashed })
    private var memories: [MemoryItem]

    @Query private var entries: [BriefEntry]

    @State private var period: Period = .week
    @State private var review: Review?

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30

        var id: Int { rawValue }
        var title: String { self == .week ? "7 days" : "30 days" }
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if let review {
                summaryCard(review)

                ForEach(review.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                        }
                    } header: {
                        Label(group.title, systemImage: group.systemImage)
                    } footer: {
                        Text(group.caption)
                    }
                }

                if review.groups.isEmpty {
                    Section {
                        Text(review.isEmpty
                             ? "Nothing captured and nothing closed in this period."
                             : "Captures, but nothing to act on — no open tasks and no repeated subjects.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ProgressView("Reading your brain…")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let review {
                ToolbarItem(placement: .topBarTrailing) {
                    // The useful thing to do with a review is paste it into the
                    // message you were about to write, so it shares as text.
                    ShareLink(item: ReviewBuilder.shareText(for: review)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: signature) { rebuild() }
    }

    // MARK: - Content

    private func summaryCard(_ review: Review) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(review.title)
                    .font(.title3.weight(.semibold))
                Text(ReviewBuilder.headline(for: review))
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                if !review.mix.isEmpty {
                    Text(review.mix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ item: Review.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.note.isEmpty {
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Building

    /// Rebuilt when the period changes or the library does, not on every redraw:
    /// the subject pass reads topics out of every capture in the period.
    private var signature: String {
        "\(period.rawValue)-\(memories.count)-\(entries.count)"
    }

    private func rebuild() {
        review = ReviewBuilder.build(
            memories: memories.map {
                ReviewMemory(
                    id: $0.identifier,
                    title: $0.displayTitle,
                    text: $0.text.isEmpty ? $0.extractedText : $0.text,
                    kind: $0.kind,
                    tags: $0.tagNames,
                    createdAt: $0.createdAt
                )
            },
            tasks: entries.map {
                ReviewTask(
                    subject: $0.subject,
                    day: $0.day,
                    isClosed: $0.isClosed,
                    closedAt: $0.closedAt
                )
            },
            days: period.rawValue
        )
    }
}
