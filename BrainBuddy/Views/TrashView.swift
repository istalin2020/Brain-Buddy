import SwiftData
import SwiftUI

/// Deleted memories, waiting.
///
/// Its own screen rather than a toggle on the brain: the trash is not a region
/// of anybody's cortex, and a filing model that shows deleted things alongside
/// kept ones is lying about what is in there.
@MainActor
struct TrashView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<MemoryItem> { $0.isTrashed },
        sort: \MemoryItem.updatedAt,
        order: .reverse
    )
    private var trashed: [MemoryItem]

    @State private var confirmEmpty = false

    var body: some View {
        Group {
            if trashed.isEmpty {
                EmptyStateView(
                    systemImage: "trash",
                    title: "Trash is empty",
                    message: "Deleted memories wait here until you empty the trash. Nothing is removed from iCloud until then."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !trashed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .confirmationDialog(
            "Permanently delete everything in the trash?",
            isPresented: $confirmEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                services.ingest.emptyTrash(in: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone, and it removes them from iCloud too.")
        }
    }

    private var list: some View {
        List {
            ForEach(trashed) { item in
                MemoryRow(item: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            services.ingest.deletePermanently(item, in: modelContext)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            services.ingest.restore(item, in: modelContext)
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
    }
}
