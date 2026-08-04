import SwiftData
import SwiftUI

@MainActor
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: Tab = .capture

    enum Tab: Hashable {
        case capture, library, ask, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "plus.circle.fill") }
                .tag(Tab.capture)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                .tag(Tab.library)

            AskView()
                .tabItem { Label("Ask", systemImage: "sparkle.magnifyingglass") }
                .tag(Tab.ask)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { _, newValue in
            // Leaving the Ask tab should silence a spoken answer immediately.
            if newValue != .ask {
                services.speaker.stop()
                services.transcriber.cancelListening()
            }
        }
        // Anything shared from another app lands in the App Group inbox; import
        // it on launch and on every return to the foreground, which is when a
        // share sheet hand-off typically completes.
        .task { await services.ingest.drainSharedInbox(into: modelContext) }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { await services.ingest.drainSharedInbox(into: modelContext) }
        }
    }
}
