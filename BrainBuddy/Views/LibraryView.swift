import SwiftData
import SwiftUI

/// Everything you have ever captured, newest first, with pinned items on top.
@MainActor
struct LibraryView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MemoryItem.createdAt, order: .reverse)
    private var allMemories: [MemoryItem]

    @State private var query = ""
    @State private var kindFilter: MemoryKind?
    @State private var showTrash = false
    @State private var confirmEmptyTrash = false

    var body: some View {
        NavigationStack {
            // Resolved once per body pass: ranking the whole library is far too
            // expensive to run again for the empty check and the row count.
            let items = displayedItems
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    list(items)
                }
            }
            .navigationTitle(showTrash ? "Trash" : "Library")
            .searchable(text: $query, prompt: showTrash ? "Search trash" : "Filter your brain")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $kindFilter) {
                            Text("All types").tag(MemoryKind?.none)
                            ForEach(MemoryKind.allCases) { kind in
                                Label(kind.title, systemImage: kind.systemImage).tag(MemoryKind?.some(kind))
                            }
                        }
                        Divider()
                        Toggle("Show trash", isOn: $showTrash)
                        if showTrash {
                            Button("Empty trash", role: .destructive) { confirmEmptyTrash = true }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .confirmationDialog(
                "Permanently delete everything in the trash?",
                isPresented: $confirmEmptyTrash,
                titleVisibility: .visible
            ) {
                Button("Delete permanently", role: .destructive) {
                    services.ingest.emptyTrash(in: modelContext)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone, and it removes them from iCloud too.")
            }
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
        }
    }

    // MARK: - Content

    private func list(_ items: [MemoryItem]) -> some View {
        List {
            Section {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        MemoryRow(item: item, snippet: snippet(for: item))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if showTrash {
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
                        } else {
                            Button(role: .destructive) {
                                services.ingest.moveToTrash(item, in: modelContext)
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            item.isPinned.toggle()
                            item.touch()
                        } label: {
                            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                }
            } header: {
                Text(items.count == 1 ? "1 memory" : "\(items.count) memories")
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: showTrash ? "trash" : "tray",
            title: showTrash ? "Trash is empty" : (query.isEmpty ? "Nothing here yet" : "No matches"),
            message: showTrash
                ? "Deleted memories wait here until you empty the trash."
                : (query.isEmpty
                    ? "Head to Capture to add your first memory."
                    : "Try the Ask tab — it searches by meaning as well as by keyword.")
        )
    }

    // MARK: - Filtering

    private var scopedItems: [MemoryItem] {
        allMemories.filter { item in
            guard item.isTrashed == showTrash else { return false }
            if let kindFilter, item.kind != kindFilter { return false }
            return true
        }
    }

    /// Short queries stay a literal filter (predictable while you type); longer
    /// ones go through the ranking engine so meaning matches show up here too.
    private var displayedItems: [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pinnedFirst(scopedItems) }

        if trimmed.count < 3 {
            let needle = trimmed.lowercased()
            return pinnedFirst(scopedItems.filter { $0.searchableText.lowercased().contains(needle) })
        }

        return services.search.search(query: trimmed, in: scopedItems, limit: 200).map(\.item)
    }

    private func pinnedFirst(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func snippet(for item: MemoryItem) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        return SearchEngine.snippet(for: Tokenizer.queryTokens(in: trimmed), in: item.searchableText)
    }
}
