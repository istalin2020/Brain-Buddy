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

    /// How many reminders a day, and the window they're spread across.
    static let maximumRemindersPerDay = 12
    /// Last hour a reminder may fire. Nothing useful comes of nagging at 2am.
    static let dayEndHour = 21
    /// Floor on the gap between reminders, for when the start time is late enough
    /// that the window can't be divided evenly.
    static let minimumSpacingMinutes = 30

    static func reminderIdentifier(_ slot: Int) -> String {
        "brainbuddy.reminder.\(slot)"
    }

    /// The times of day reminders fire: the first at the chosen hour, the rest
    /// spread evenly to `dayEndHour`.
    static func reminderTimes(startHour: Int, startMinute: Int, count: Int) -> [DateComponents] {
        let slots = max(1, min(count, maximumRemindersPerDay))
        let start = startHour * 60 + startMinute
        let latest = 23 * 60 + 30
        guard slots > 1 else { return [Self.components(atMinuteOfDay: start)] }

        let span = (dayEndHour * 60) - start
        // A start time late in the evening leaves no window to divide, so fall
        // back to a fixed gap rather than stacking every reminder on one minute.
        let spacing = span >= (slots - 1) * minimumSpacingMinutes
            ? span / (slots - 1)
            : minimumSpacingMinutes

        return (0..<slots).map { Self.components(atMinuteOfDay: min(start + $0 * spacing, latest)) }
    }

    private static func components(atMinuteOfDay minute: Int) -> DateComponents {
        var parts = DateComponents()
        parts.hour = (minute / 60) % 24
        parts.minute = minute % 60
        return parts
    }

    /// Schedules the day's reminders, each carrying one thing that's still open.
    ///
    /// **Why the text is baked in.** A local notification's content is fixed when
    /// it's scheduled — the app isn't running at fire time to pick something. So a
    /// pending line is dealt to each slot here, and the whole set is rebuilt
    /// whenever the brief changes: after a rebuild, after you close something, and
    /// when the app comes back to the screen. Between those moments a reminder can
    /// name something you've since dealt with, which is the cost of the system not
    /// waking us up to ask.
    ///
    /// The lines are shuffled and dealt without repetition, refilling from a fresh
    /// shuffle when there are fewer open items than slots — so seven reminders
    /// across three open tasks cycle rather than fixating on one.
    ///
    /// Returns `false` when notifications aren't permitted, so a caller can put its
    /// toggle back rather than leaving a switch on that does nothing.
    @discardableResult
    func scheduleReminders(pending: [String], hour: Int, minute: Int, count: Int) async -> Bool {
        guard await requestAuthorization() else {
            await refreshNextTrigger()
            return false
        }

        cancelReminders()

        let times = Self.reminderTimes(startHour: hour, startMinute: minute, count: count)
        var deck: [String] = []
        var succeeded = true

        for (slot, time) in times.enumerated() {
            if deck.isEmpty { deck = pending.shuffled() }
            let line = deck.popLast()

            let content = UNMutableNotificationContent()
            if let line {
                // The first of the day frames itself as the brief; the rest are
                // single nudges, which is what makes seven a day tolerable.
                content.title = slot == 0 ? "Your brief for today" : "Still open"
                content.body = line
            } else {
                content.title = "Your brief for today"
                content.body = slot == 0
                    ? "What's on, what's still open, and the points worth having in mind."
                    : "Nothing open right now."
            }
            content.sound = .default
            content.userInfo = [NotificationRouter.destinationKey: AppDestination.today.rawValue]
            content.threadIdentifier = Self.morningBriefIdentifier

            let request = UNNotificationRequest(
                identifier: Self.reminderIdentifier(slot),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
            )
            do {
                try await center.add(request)
            } catch {
                succeeded = false
            }
        }

        await refreshNextTrigger()
        return succeeded
    }

    func cancelReminders() {
        let identifiers = (0..<Self.maximumRemindersPerDay).map(Self.reminderIdentifier)
        // The single-notification identifier this replaced, so an old pending
        // request from a previous version can't linger alongside the new set.
        center.removePendingNotificationRequests(withIdentifiers: identifiers + [Self.morningBriefIdentifier])
        nextTrigger = nil
    }

    /// Reapplies the current preference **without ever prompting**.
    ///
    /// Runs at every launch, because the system keeps pending requests across
    /// launches but not across a reinstall or a restore onto a new device —
    /// otherwise reminders would quietly stop arriving on a new phone. Launch is
    /// the wrong moment to ask for permission, though, so this only schedules
    /// when permission already exists.
    func synchronize(enabled: Bool, pending: [String], hour: Int, minute: Int, count: Int) async {
        await refresh()
        guard enabled else {
            cancelReminders()
            return
        }
        guard isAuthorized else { return }
        await scheduleReminders(pending: pending, hour: hour, minute: minute, count: count)
    }

    /// The soonest of the scheduled reminders, for display in Settings.
    private func refreshNextTrigger() async {
        let requests = await center.pendingNotificationRequests()
        nextTrigger = requests
            .filter { $0.identifier.hasPrefix("brainbuddy.reminder.") }
            .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
            .min()
    }
}
