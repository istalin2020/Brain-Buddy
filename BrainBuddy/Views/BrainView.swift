import SwiftData
import SwiftUI

/// Your brain, as a brain.
///
/// The old version of this screen was a grid of boxes, which is a filing
/// cabinet with the doors painted on. This one puts everything in the place the
/// cortex would put it — work in the frontal lobe, photos in the visual cortex,
/// recordings in the auditory one — so finding something becomes *pointing at
/// where it lives* rather than reading labels. Position is the fastest index a
/// person has, and it is the one a list can never use.
///
/// There is no search box: Ask is the search. Here you narrow by **when**, turn
/// the model, and open a region.
@MainActor
struct BrainView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<MemoryItem> { !$0.isTrashed },
        sort: \MemoryItem.createdAt,
        order: .reverse
    )
    private var memories: [MemoryItem]

    @State private var scope: PeriodScope = .all
    @State private var period: BrainPeriod?
    @State private var map = BrainMap()
    /// Every document currently on screen, as nodes wired to the brain — newest
    /// first, so when there are more than the scene holds it keeps the ones you
    /// are most likely to be after. Stored rather than computed: this feeds a
    /// `UIViewRepresentable`, which reads it on every redraw.
    @State private var sceneFiles: [BrainSceneFile] = []
    @State private var selection: BrainRegion?
    @State private var section: WorkSection?
    @State private var openFile: UUID?
    @State private var resetToken = 0
    /// Position of the HUD sweep line, 0 at the top, 1 past the bottom.
    @State private var sweep: CGFloat = 0
    /// Owned rather than implicit, so a memory tapped in the device's own search
    /// can be pushed from outside this view.
    @State private var path: [MemoryItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                periodBar
                stage
                regionStrip
                Divider()
                panel
            }
            .navigationTitle("Brain")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TrashView()
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
            }
            .task(id: signature) { await rebuild() }
            // A node tapped on the model belongs to a region that may not be the
            // one on screen. Open it, rather than selecting something invisible.
            .onChange(of: openFile) { _, newValue in
                guard let newValue, let file = file(withID: newValue) else { return }
                if selection != file.region {
                    selection = file.region
                    section = nil
                }
            }
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
        guard let match = memories.first(where: { $0.identifier == identifier }) else { return }
        // Replaces whatever was on screen: you asked for this note by name.
        path = [match]
    }

    // MARK: - When

    private var periodBar: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $scope) {
                ForEach(PeriodScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if !periods.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(periods) { candidate in
                            periodChip(candidate)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onChange(of: scope) { _, newValue in
            // Landing on the newest slice is right almost always, and it means
            // switching to "Month" shows you something rather than nothing.
            period = newValue == .all ? nil : periods.first
            openFile = nil
        }
    }

    private func periodChip(_ candidate: BrainPeriod) -> some View {
        let isSelected = period?.id == candidate.id
        return Button {
            period = isSelected ? nil : candidate
            openFile = nil
        } label: {
            Text(candidate.label)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    isSelected ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - The model

    /// The model, on its own dark stage, framed like a scan.
    ///
    /// Always dark, in both appearances: everything in the scene is drawn by
    /// adding light, and adding light to a white page is invisible. The HUD
    /// around it — grid, corner brackets, a readout, a slow sweep — is not
    /// decoration for its own sake. It says *this is an instrument showing you
    /// something*, which is the frame in which a glowing translucent brain
    /// reads as a scan rather than as a mistake.
    private var stage: some View {
        BrainSceneView(
            files: sceneFiles,
            counts: map.counts,
            workSections: workSectionCounts,
            highlight: selection,
            selectedFile: $openFile,
            resetToken: resetToken
        )
            .frame(height: 400)
            .background(Color(uiColor: BrainSceneBuilder.Palette.stage))
            .overlay { hud }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    resetToken += 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(8)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Straighten the view")
            }
            .overlay(alignment: .bottom) {
                Text(openFile == nil
                     ? "Drag to turn · pinch in to read the nodes · tap one"
                     : "Tap the summary below to open the document")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Self.hudTint.opacity(0.75))
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal)
            .onAppear {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    sweep = 1
                }
            }
    }

    private static let hudTint = Color(uiColor: BrainSceneBuilder.Palette.wire)

    /// The instrument frame over the scene: a faint grid, brackets in the
    /// corners, a readout, and a sweep line that never stops. All of it lets
    /// touches through — the brain underneath is what you interact with.
    private var hud: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var grid = Path()
                let step: CGFloat = 32
                var x = step
                while x < size.width {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y = step
                while y < size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(grid, with: .color(Color.white.opacity(0.045)), lineWidth: 0.5)

                let inset: CGFloat = 12
                let arm: CGFloat = 22
                var brackets = Path()
                for corner in [
                    (CGPoint(x: inset, y: inset), CGFloat(1), CGFloat(1)),
                    (CGPoint(x: size.width - inset, y: inset), CGFloat(-1), CGFloat(1)),
                    (CGPoint(x: inset, y: size.height - inset), CGFloat(1), CGFloat(-1)),
                    (CGPoint(x: size.width - inset, y: size.height - inset), CGFloat(-1), CGFloat(-1))
                ] {
                    let (origin, dx, dy) = corner
                    brackets.move(to: CGPoint(x: origin.x, y: origin.y + dy * arm))
                    brackets.addLine(to: origin)
                    brackets.addLine(to: CGPoint(x: origin.x + dx * arm, y: origin.y))
                }
                context.stroke(brackets, with: .color(Self.hudTint.opacity(0.85)), lineWidth: 1.5)
            }

            GeometryReader { geometry in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Self.hudTint.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 48)
                    .offset(y: sweep * (geometry.size.height + 48) - 48)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("MEMORY MAP")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Self.hudTint)
                Text(readout)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Self.hudTint.opacity(0.7))
            }
            .padding(.leading, 22)
            .padding(.top, 20)
        }
        .allowsHitTesting(false)
    }

    private var readout: String {
        let scope = period?.label ?? "ALL TIME"
        return "\(map.total) MEMORIES · \(scope.uppercased()) · \(sceneFiles.count) ON MAP"
    }

    /// Work's rooms, for the Work callout's second line.
    private var workSectionCounts: [WorkSection: Int] {
        Dictionary(uniqueKeysWithValues: WorkSection.allCases.map { ($0, map.count(.work, section: $0)) })
    }



    /// The same six regions as a row of chips.
    ///
    /// Not a duplicate control: a lobe is a small target on a phone, some of
    /// them hide behind others until you turn the model, and VoiceOver can't
    /// tap a 3D mesh at all. The chips are the accessible, one-handed path to
    /// exactly the same thing.
    private var regionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrainRegion.display) { region in
                    regionChip(region)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func regionChip(_ region: BrainRegion) -> some View {
        let count = map.count(region)
        let isSelected = selection == region
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = isSelected ? nil : region
                section = nil
                openFile = nil
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: region.systemImage)
                    .font(.caption)
                Text(region.shortTitle)
                    .font(.footnote.weight(.medium))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(
                region.tint.opacity(isSelected ? 0.3 : 0.12),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(region.tint.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            }
            .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(region.tint))
        }
        .buttonStyle(.plain)
    }

    // MARK: - What's inside

    @ViewBuilder
    private var panel: some View {
        ScrollViewReader { proxy in
            Group {
                if let selection {
                    regionPanel(selection)
                } else {
                    overviewPanel
                }
            }
            // Opening a node on the model has to bring its row to you; a list
            // that silently expanded a row somewhere below the fold would look
            // like nothing happened.
            .onChange(of: openFile) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func regionPanel(_ region: BrainRegion) -> some View {
        let files = map.files(in: region, section: region == .work ? section : nil)

        return List {
            Section {
                if files.isEmpty {
                    Text(period == nil
                         ? "Nothing filed here yet."
                         : "Nothing here in this period.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    fileRow(file).id(file.id)
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: region.systemImage)
                        Text(region.title)
                            .font(.headline)
                        Spacer(minLength: 4)
                        Text(region.anatomy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(region.tint)

                    Text(region.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)

                    if region == .work { workSections }
                }
                .padding(.vertical, 6)
                .textCase(nil)
            }
        }
        .listStyle(.plain)
    }

    private var workSections: some View {
        HStack(spacing: 8) {
            sectionChip(nil, title: "All", systemImage: "tray.full", count: map.count(.work))
            ForEach(WorkSection.allCases) { candidate in
                sectionChip(
                    candidate,
                    title: candidate.title,
                    systemImage: candidate.systemImage,
                    count: map.count(.work, section: candidate)
                )
            }
        }
        .padding(.top, 2)
    }

    private func sectionChip(_ candidate: WorkSection?, title: String, systemImage: String, count: Int) -> some View {
        let isSelected = section == candidate
        return Button {
            section = candidate
            openFile = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(
                isSelected ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    /// With nothing open: the newest things in the brain, whichever region they
    /// landed in, each carrying its region's colour. Somewhere to start.
    private var overviewPanel: some View {
        let recent = map.files
            .values
            .flatMap { $0 }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(12)

        return List {
            Section {
                if recent.isEmpty {
                    Text(period == nil
                         ? "Nothing captured yet. Anything you add from Input lands in one of these regions."
                         : "Nothing captured in this period.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(recent)) { file in
                    fileRow(file, showsRegion: true).id(file.id)
                }
            } header: {
                Text("\(map.total) \(map.total == 1 ? "memory" : "memories") · newest first")
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - One document

    /// Name first. Tap it and the key summary opens underneath; tap the summary
    /// and the whole note opens on its own page. Three steps, each one a bigger
    /// commitment than the last — which is what stops a list of thirty files
    /// from being thirty paragraphs.
    @ViewBuilder
    private func fileRow(_ file: BrainFile, showsRegion: Bool = false) -> some View {
        let isOpen = openFile == file.id

        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    openFile = isOpen ? nil : file.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: file.kind.systemImage)
                        .font(.caption)
                        .foregroundStyle(file.region.tint)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if showsRegion {
                            Text(file.region.shortTitle)
                                .font(.caption2)
                                .foregroundStyle(file.region.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(file.createdAt.filedDateDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { summaryCard(file) }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let item = item(for: file) {
                Button(role: .destructive) {
                    services.ingest.moveToTrash(item, in: modelContext)
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func summaryCard(_ file: BrainFile) -> some View {
        if let item = item(for: file) {
            NavigationLink(value: item) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Key summary", systemImage: "text.alignleft")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(file.region.tint)

                    Text(file.summary.isEmpty ? "No extra detail — the name says it." : file.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Text("Read the whole thing")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(file.region.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }

    // MARK: - Data

    private var periods: [BrainPeriod] {
        PeriodFilter.periods(for: scope, in: memories.map(\.createdAt))
    }

    private var filtered: [MemoryItem] {
        guard let period else { return memories }
        return memories.filter { period.contains($0.createdAt) }
    }

    /// Changes whenever anything could move a memory between regions, or change
    /// which memories are on screen at all.
    private var signature: String {
        let newest = memories.first?.updatedAt.timeIntervalSince1970 ?? 0
        return "\(memories.count)-\(Int(newest))-\(scope.rawValue)-\(period?.id ?? "none")"
    }

    private func file(withID id: UUID) -> BrainFile? {
        map.files.values.flatMap { $0 }.first { $0.id == id }
    }

    private func item(for file: BrainFile) -> MemoryItem? {
        memories.first { $0.identifier == file.id }
    }

    /// Classification is a token pass over the whole library, so it runs off the
    /// main actor and only when the signature above changes — never per redraw.
    private func rebuild() async {
        let inputs = filtered.map { BrainFileInput($0) }

        let built = await Task.detached(priority: .userInitiated) {
            BrainClassifier.map(inputs)
        }.value

        map = built
        sceneFiles = built.files
            .values
            .flatMap { $0 }
            .sorted { $0.createdAt > $1.createdAt }
            .map { BrainSceneFile(id: $0.id, title: $0.title, region: $0.region) }

        // A filter change can take the open document off the screen; leaving its
        // id set would silently re-open it the next time it came back.
        if let openFile {
            let survives = built.files.values.flatMap { $0 }.contains { $0.id == openFile }
            if !survives { self.openFile = nil }
        }
    }
}
