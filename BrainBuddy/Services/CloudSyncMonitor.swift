import CloudKit
import CoreData
import Foundation
import Observation

/// Reports whether iCloud sync is actually working.
///
/// SwiftData's CloudKit mirroring is silent by design — it either works or it
/// doesn't, with no UI. That is a bad deal for an app whose whole promise is
/// "your brain is everywhere", so this watches the account status and the
/// remote-change notifications the mirroring stack posts, and surfaces both.
@MainActor
@Observable
final class CloudSyncMonitor {
    enum Status: Equatable {
        case unknown
        case syncing
        case available
        case noAccount
        case restricted
        case error(String)

        var title: String {
            switch self {
            case .unknown: return "Checking iCloud…"
            case .syncing: return "Syncing with iCloud"
            case .available: return "Synced with iCloud"
            case .noAccount: return "Not signed in to iCloud"
            case .restricted: return "iCloud is restricted"
            case .error: return "iCloud sync problem"
            }
        }

        var detail: String {
            switch self {
            case .unknown:
                return "Looking up your iCloud account."
            case .syncing:
                return "Sending recent changes to your other devices."
            case .available:
                return "Everything you capture is mirrored to your private iCloud database."
            case .noAccount:
                return "Sign in to iCloud in the Settings app to sync across devices. Your notes are still saved on this device."
            case .restricted:
                return "iCloud is unavailable on this device, likely due to parental controls or a device policy. Notes are saved locally."
            case .error(let reason):
                return reason
            }
        }

        var systemImage: String {
            switch self {
            case .unknown: return "icloud"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .available: return "checkmark.icloud"
            case .noAccount: return "icloud.slash"
            case .restricted: return "lock.icloud"
            case .error: return "exclamationmark.icloud"
            }
        }

        var isHealthy: Bool { self == .available || self == .syncing }
    }

    private(set) var status: Status = .unknown
    private(set) var lastChangeReceived: Date?

    private var observers: [Task<Void, Never>] = []
    private var settleTask: Task<Void, Never>?

    init() {
        observeAccountChanges()
        observeRemoteChanges()
    }

    func refresh() async {
        let container = CKContainer(identifier: PersistenceController.cloudKitContainerIdentifier)
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                status = .available
            case .noAccount:
                status = .noAccount
            case .restricted:
                status = .restricted
            case .couldNotDetermine:
                status = .error("Couldn't reach iCloud. Sync will resume when the connection comes back.")
            case .temporarilyUnavailable:
                status = .error("iCloud is temporarily unavailable. Sync will resume automatically.")
            @unknown default:
                status = .unknown
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func observeAccountChanges() {
        let task = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                await self.refresh()
            }
        }
        observers.append(task)
    }

    /// The CloudKit mirroring stack posts `NSPersistentStoreRemoteChange`
    /// whenever it imports changes from another device.
    private func observeRemoteChanges() {
        let task = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                guard let self else { return }
                self.noteRemoteChange()
            }
        }
        observers.append(task)
    }

    private func noteRemoteChange() {
        lastChangeReceived = Date()
        if status.isHealthy { status = .syncing }

        // Collapse a burst of imports into a single "syncing" flash.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.status == .syncing { self.status = .available }
        }
    }
}
