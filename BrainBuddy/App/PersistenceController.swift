import Foundation
import SwiftData

/// Owns the SwiftData stack and its CloudKit mirroring.
///
/// The container is built once, up front, with a deliberate ladder of
/// fallbacks: private CloudKit database → local-only store → in-memory store.
/// A second brain that refuses to launch because iCloud is misconfigured is
/// worse than one that quietly runs offline for a session.
final class PersistenceController {
    static let shared = PersistenceController()

    /// Must match the identifier in `Configuration/BrainBuddy.entitlements`.
    static let cloudKitContainerIdentifier = "iCloud.com.brainbuddy.app"

    enum Mode: String {
        case cloud
        case local
        case memory

        var description: String {
            switch self {
            case .cloud: return "Syncing with your private iCloud database."
            case .local: return "Saved on this device only — iCloud mirroring couldn't be set up."
            case .memory: return "Temporary storage only. Notes will be lost when the app closes."
            }
        }
    }

    let container: ModelContainer
    let mode: Mode
    /// Populated when the preferred configuration failed, for the Settings screen.
    let setupWarning: String?

    private init() {
        let schema = Schema([MemoryItem.self, MemoryAttachment.self, MemoryTag.self])
        var warning: String? = nil

        if let cloud = Self.makeContainer(
            schema: schema,
            configuration: ModelConfiguration(
                "BrainBuddy",
                schema: schema,
                cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
            )
        ) {
            container = cloud
            mode = .cloud
            setupWarning = nil
            return
        }

        warning = "iCloud mirroring couldn't be initialized. Check that the app's iCloud container matches \(Self.cloudKitContainerIdentifier) and that you're signed in."

        if let local = Self.makeContainer(
            schema: schema,
            configuration: ModelConfiguration("BrainBuddy", schema: schema, cloudKitDatabase: .none)
        ) {
            container = local
            mode = .local
            setupWarning = warning
            return
        }

        // Last resort: never crash on launch.
        do {
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
            mode = .memory
            setupWarning = (warning ?? "") + " The on-disk store also failed to open."
        } catch {
            fatalError("Brain Buddy couldn't create any model container: \(error)")
        }
    }

    private static func makeContainer(schema: Schema, configuration: ModelConfiguration) -> ModelContainer? {
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            return nil
        }
    }
}
