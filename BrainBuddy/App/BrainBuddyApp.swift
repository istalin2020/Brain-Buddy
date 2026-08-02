import SwiftData
import SwiftUI

@MainActor
@main
struct BrainBuddyApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .task { services.prepare() }
        }
        .modelContainer(PersistenceController.shared.container)
    }
}
