import Foundation
import UserNotifications

/// Turns a tapped notification into "open this tab".
///
/// Deliberately *not* `@MainActor`: `UNUserNotificationCenterDelegate` carries no
/// isolation, so claiming some here would be a promise the protocol doesn't make.
/// The hop to the main actor is explicit instead, at the one point it's needed.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let destinationKey = "destination"

    private let onDestination: @MainActor (String) -> Void

    init(onDestination: @escaping @MainActor (String) -> Void) {
        self.onDestination = onDestination
        super.init()
    }

    /// Show the banner even when the app is already open. The brief is a morning
    /// prompt; silently swallowing it because the app happened to be foregrounded
    /// is how you miss the one thing it exists to tell you.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let destination = userInfo[Self.destinationKey] as? String else { return }
        let handler = onDestination
        await MainActor.run { handler(destination) }
    }
}
