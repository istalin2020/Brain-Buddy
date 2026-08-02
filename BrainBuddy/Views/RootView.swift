import SwiftUI

@MainActor
struct RootView: View {
    @Environment(AppServices.self) private var services
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
    }
}
