import Foundation
import Observation
import UserNotifications

/// The 8 am nudge.
///
/// One repeating local notification, scheduled by the system from a
/// `DateComponents` match — no server, no push certificate, and it keeps firing
/// whether or not the app has been opened in weeks. That's the whole reason the
/// brief itself is built on open rather than in the background: this part is
/// reliable, so the part that has to be reliable lives here.
@MainActor
@Observable
final class NotificationScheduler {
    /// Stable identifier: re-adding a request with the same one replaces it,
    /// which is how changing the time doesn't leave the old one behind.
    static let morningBriefIdentifier = "brainbuddy.morningBrief"

    /// Set once the system prompt has actually been shown, so it's never put in
    /// front of the user twice — and so the first-run ask can tell the difference
    /// between "hasn't decided" and "hasn't been asked".
    private static let hasRequestedKey = "notifications.hasRequested"

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// When the next brief notification is due, for display in Settings.
    private(set) var nextTrigger: Date?

    var hasRequestedPermission: Bool {
        UserDefaults.standard.bool(forKey: Self.hasRequestedKey)
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional
    }

    var isDenied: Bool { authorization == .denied }

    private var center: UNUserNotificationCenter { .current() }

    // MARK: - Authorization

    func refresh() async {
        authorization = await center.notificationSettings().authorizationStatus
        await refreshNextTrigger()
    }

    /// Returns whether we ended up authorized, asking only if we haven't before.
    @discardableResult
    func requestAuthorization() async -> Bool {
        await refresh()
        if isAuthorized { return true }
        if isDenied { return false }

        UserDefaults.standard.set(true, forKey: Self.hasRequestedKey)
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refresh()
        return granted
    }

    // MARK: - Scheduling

    /// Schedules — or reschedules — the daily brief notification.
    ///
    /// Returns `false` when notifications aren't permitted, so the caller can put
    /// the toggle back rather than leaving a switch on that does nothing.
    @discardableResult
    func scheduleMorningBrief(hour: Int, minute: Int) async -> Bool {
        guard await requestAuthorization() else {
            await refreshNextTrigger()
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "Your brief for today"
        content.body = "What's on, what's still open, and the points worth having in mind."
        content.sound = .default
        // Read by the router to open straight onto the Today tab.
        content.userInfo = ["destination": "today"]
        content.threadIdentifier = Self.morningBriefIdentifier

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let request = UNNotificationRequest(
            identifier: Self.morningBriefIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )

        do {
            // Adding with an existing identifier replaces the pending request, so
            // there's no window where two are queued.
            try await center.add(request)
        } catch {
            await refreshNextTrigger()
            return false
        }

        await refreshNextTrigger()
        return true
    }

    func cancelMorningBrief() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningBriefIdentifier])
        nextTrigger = nil
    }

    /// Reapplies the current preference **without ever prompting**.
    ///
    /// Runs at every launch, because the system keeps pending requests across
    /// launches but not across a reinstall or a restore onto a new device —
    /// otherwise the brief would quietly stop arriving on a new phone. Launch is
    /// the wrong moment to ask for permission, though, so this only schedules
    /// when permission already exists.
    func synchronize(enabled: Bool, hour: Int, minute: Int) async {
        await refresh()
        guard enabled else {
            cancelMorningBrief()
            return
        }
        guard isAuthorized else { return }
        await scheduleMorningBrief(hour: hour, minute: minute)
    }

    private func refreshNextTrigger() async {
        let pending = await center.pendingNotificationRequests()
        let request = pending.first { $0.identifier == Self.morningBriefIdentifier }
        nextTrigger = (request?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
    }
}
