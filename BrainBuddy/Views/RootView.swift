import SwiftData
import SwiftUI

@MainActor
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Today's brief is the landing screen: the 8 am notification says "check the
    /// app", so the app should open on the thing it told you to check.
    @State private var selection: Tab = .today

    enum Tab: Hashable {
        case today, capture, library, ask, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(Tab.today)

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
        .task {
            await services.ingest.drainSharedInbox(into: modelContext)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { await services.ingest.drainSharedInbox(into: modelContext) }
            // A phone left open across midnight should come back to the new day's
            // brief, not yesterday's.
            services.brief.generateIfNeeded(in: modelContext)
        }
        // Set by `NotificationRouter` when the morning notification is tapped.
        .onChange(of: services.pendingDestination) { _, destination in
            guard let destination else { return }
            switch destination {
            case .today: selection = .today
            }
            services.pendingDestination = nil
        }
    }
}
