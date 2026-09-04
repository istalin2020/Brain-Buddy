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
    @State private var showTrash = false
    @State private var confirmEmptyTrash = false
    /// Which box is open. An id rather than a `BrainBox` so a rebuild of the
    /// index doesn't lose the selection.
    @State private var selectedBox = "everything"
    /// Built off the library and kept, because reading subjects out of every
    /// memory is two `NLTagger` passes each — cheap once, ruinous per redraw.
    @State private var index = BrainBoxIndex()

    /// Owned rather than implicit, so a memory tapped in the device's own search
    /// can be pushed from outside this view.
    @State private var path: [MemoryItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            // Resolved once per body pass: ranking the whole library is far too
            // expensive to run again for the empty check and the row count.
            let items = displayedItems
            Group {
                // With a box open, an empty result still shows the grid — losing
                // it would leave no way back to Everything.
                if items.isEmpty, showTrash || index.boxes.count <= 1 {
                    emptyState
                } else {
                    list(items)
                }
            }
            .navigationTitle(showTrash ? "Trash" : "Brain")
            .searchable(text: $query, prompt: showTrash ? "Search trash" : "Filter your brain")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
            // Rebuilt when the library changes rather than on every redraw.
            .task(id: librarySignature) { rebuildBoxes() }
            // Set when a Spotlight result is tapped. Collected on appearance
            // too, because the request usually arrives before this tab exists.
            .task { openPendingMemory() }
            .onChange(of: services.pendingMemoryIdentifier) { _, _ in openPendingMemory() }
        }
    }

    /// Pushes the memory the system search asked for, once.
    private func openPendingMemory() {
        guard let identifier = services.pendingMemoryIdentifier else { return }
        services.pendingMemoryIdentifier = nil
        guard let match = allMemories.first(where: { $0.identifier == identifier }) else { return }
        // Replaces whatever was on screen: you asked for this note by name.
        path = [match]
    }

    /// Changes when anything that could move a memory between boxes changes.
    private var librarySignature: String {
        let newest = allMemories.first?.updatedAt.timeIntervalSince1970 ?? 0
        return "\(allMemories.count)-\(Int(newest))"
    }

    private func rebuildBoxes() {
        index = BrainBoxBuilder.build(
            from: allMemories
                .filter { !$0.isTrashed }
                .map {
                    BrainBoxItem(
                        id: $0.identifier,
                        kind: $0.kind,
                        tags: $0.tagNames,
                        text: $0.searchableText
                    )
                }
        )
        // A box can disappear when the memory that justified it is edited away.
        if !index.boxes.contains(where: { $0.id == selectedBox }) {
            selectedBox = "everything"
        }
    }

    // MARK: - Content

    private func list(_ items: [MemoryItem]) -> some View {
        List {
            if !showTrash, index.boxes.count > 1 {
                Section {
                    BrainBoxGrid(boxes: index.boxes, selection: $selectedBox)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if items.isEmpty {
                    Text(query.isEmpty ? "This box is empty." : "Nothing in this box matches.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
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
                Text(listHeading(count: items.count))
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
                    ? "Head to Input to add your first memory."
                    : "Try the Ask tab — it searches by meaning as well as by keyword.")
        )
    }

    // MARK: - Filtering

    private var openBox: BrainBox? {
        index.boxes.first { $0.id == selectedBox }
    }

    private func listHeading(count: Int) -> String {
        let noun = count == 1 ? "memory" : "memories"
        guard let openBox, openBox.filter != .everything else { return "\(count) \(noun)" }
        return "\(openBox.title) · \(count) \(noun)"
    }

    private var scopedItems: [MemoryItem] {
        allMemories.filter { item in
            guard item.isTrashed == showTrash else { return false }
            // Trash is a place, not a box; the grid is hidden there.
            if showTrash { return true }
            guard let openBox else { return true }
            return index.contains(item, in: openBox)
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
