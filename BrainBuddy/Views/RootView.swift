import CoreSpotlight
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
                .tabItem { Label("Input", systemImage: "plus.circle.fill") }
                .tag(Tab.capture)

            BrainView()
                .tabItem { Label("Brain", systemImage: "brain.head.profile") }
                .tag(Tab.library)

            AskView()
                .tabItem { Label("Ask", systemImage: "sparkle.magnifyingglass") }
                .tag(Tab.ask)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { _, _ in
            // A spoken answer and an open microphone both belong to the screen
            // you were on. Two tabs dictate through one recognizer — Ask and the
            // capture editor — so ending the session on *any* tab change is what
            // keeps ownership of it unambiguous.
            services.speaker.stop()
            services.transcriber.cancelListening()
        }
        // Anything shared from another app lands in the App Group inbox; import
        // it on launch and on every return to the foreground, which is when a
        // share sheet hand-off typically completes.
        .task {
            await services.ingest.drainSharedInbox(into: modelContext)
            // Anything said to Siri while the app was closed. Filed before the
            // brief is built, so a task you dictated this morning can appear in
            // it straight away.
            await services.ingest.drainQuickCaptures(into: modelContext)
            services.collectPendingRequests()
        }
        // A Spotlight result for one of your memories opens that memory.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            services.open(activity)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task {
                await services.ingest.drainSharedInbox(into: modelContext)
                await services.ingest.drainQuickCaptures(into: modelContext)
                services.collectPendingRequests()
            }
            // A phone left open across midnight should come back to the new day's
            // brief, not yesterday's.
            services.brief.generateIfNeeded(in: modelContext)
            Task { await services.refreshReminders(in: modelContext) }
        }
        // Set by `NotificationRouter` when the morning notification is tapped.
        .onChange(of: services.pendingDestination) { _, destination in
            guard let destination else { return }
            switch destination {
            case .today: selection = .today
            }
            services.pendingDestination = nil
        }
        // A question asked through Siri lands on the tab that answers it;
        // `AskView` runs it and clears it.
        .onChange(of: services.pendingQuestion) { _, question in
            guard question != nil else { return }
            selection = .ask
        }
        // A memory opened from the device's own search shows up in the Brain
        // tab, which pushes it and clears the request.
        .onChange(of: services.pendingMemoryIdentifier) { _, identifier in
            guard identifier != nil else { return }
            selection = .library
        }
    }
}
