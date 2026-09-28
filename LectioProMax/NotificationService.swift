import Foundation
import UserNotifications

/// Which notifications you want (Settings → Notifications). Phone
/// settings, not the account's: they stay when you sign out.
enum NotifyPrefs {
    static let changesKey = "notify.scheduleChanges"
    static let messagesKey = "notify.messages"
    static let workKey = "notify.newWork"
    static let lessonsKey = "notify.lessons"
    static let leadKey = "notify.lessonLead"

    /// The lead times on offer, in minutes.
    static let leads = [1, 2, 5, 10, 15, 20, 30]

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var changes: Bool { flag(changesKey, default: true) }
    static var messages: Bool { flag(messagesKey, default: true) }
    static var work: Bool { flag(workKey, default: true) }
    /// Off until you turn it on: six a day is a lot to get unasked.
    static var lessons: Bool { flag(lessonsKey, default: false) }
    static var lead: Int {
        let minutes = UserDefaults.standard.integer(forKey: leadKey)
        return leads.contains(minutes) ? minutes : 5
    }

    static func allows(_ topic: ChangeAlert.Topic) -> Bool {
        switch topic {
        case .schedule: return changes
        case .messages: return messages
        case .work: return work
        }
    }
}

/// Notifications, all made on the phone: reminders you asked for, a nudge
/// before each lesson, and what a background check found (see
/// BackgroundCheck). No server and no push certificate.
///
/// Reminders fire exactly on time, from dates the app already knows. News —
/// a cancelled lesson, a message — can only be found when iOS lets the app
/// check in the background, so it can come late.
enum NotificationService {

    private static let workPrefix = "lectio.work."
    private static let absencePrefix = "lectio.absence."
    private static let lessonPrefix = "lectio.lesson."
    private static let newsPrefix = "lectio.news."

    /// iOS keeps at most 64 waiting notifications per app.
    private static let pendingLimit = 64

    // MARK: - Permission

    /// Asks once. Returns false if the person said no, so the UI can put the
    /// control back rather than pretending the reminder is set.
    static func requestPermission() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await centre.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Every reminder of ours, pending or shown: for signing out, so the
    /// last account's homework doesn't keep ringing.
    static func removeAll() {
        let centre = UNUserNotificationCenter.current()
        centre.removeAllPendingNotificationRequests()
        centre.removeAllDeliveredNotifications()
    }

    // MARK: - Scheduling

    /// Rebuilds every reminder we own from the store. Cheap, and it keeps things
    /// honest when a due date moves or something gets handed in.
    static func reschedule(snapshot: LectioSnapshot,
                           absences: [AbsenceRecord]) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        let ours = pending.map { $0.identifier }
            .filter { $0.hasPrefix(workPrefix) || $0.hasPrefix(absencePrefix) }
        centre.removePendingNotificationRequests(withIdentifiers: ours)

        guard await isAuthorized() else { return }

        for item in snapshot.workItems {
            guard let timing = RemindersStore.timing(for: item.key) else { continue }
            // Nothing to remind about once it's done.
            if snapshot.isCompleted(item) { continue }
            schedule(item, timing: timing, centre: centre)
        }

        for record in absences where RemindersStore.isOn(record.id) {
            scheduleAbsence(record, centre: centre)
        }
    }

    private static func schedule(_ item: WorkItem,
                                 timing: ReminderTiming,
                                 centre: UNUserNotificationCenter) {
        guard let due = item.due, let dueDate = LectioDates.date(fromISO: due) else { return }
        // Danish time, like the deadline itself.
        let calendar = LectioDates.calendar

        var day = dueDate
        var hour = 18
        var minute = 0

        switch timing {
        case .eveningBefore:
            day = calendar.date(byAdding: .day, value: -1, to: dueDate) ?? dueDate
            hour = 18
        case .morningOf:
            hour = 7
            minute = 30
        case .twoHoursBefore:
            let dueMinutes = Lesson.minutes(from: item.dueTime) ?? (12 * 60)
            let target = max(dueMinutes - 120, 6 * 60)
            hour = target / 60
            minute = target % 60
        }

        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        guard let fire = calendar.date(from: components), fire > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = item.code.isEmpty ? "Due soon" : item.code.uppercased() + (timing == .eveningBefore ? " due tomorrow" : " due today")
        content.body = LectioDates.tidy(item.title)
        if !item.dueTime.isEmpty { content.subtitle = "Due at " + item.dueTime }
        content.sound = .default

        // With its calendar and time zone, so it fires at that Danish time
        // even on a phone set to another zone.
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                                                  from: fire),
            repeats: false)
        centre.add(UNNotificationRequest(identifier: workPrefix + item.key,
                                         content: content,
                                         trigger: trigger))
    }

    private static func scheduleAbsence(_ record: AbsenceRecord,
                                        centre: UNUserNotificationCenter) {
        let calendar = LectioDates.calendar
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 8
        components.minute = 0
        var fire = calendar.date(from: components) ?? Date()
        if fire <= Date() {
            fire = calendar.date(byAdding: .day, value: 1, to: fire) ?? fire
        }

        let content = UNMutableNotificationContent()
        content.title = "Absence needs a reason"
        content.body = [record.whenLine, record.code.uppercased()]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                                                  from: fire),
            repeats: false)
        centre.add(UNNotificationRequest(identifier: absencePrefix + record.id,
                                         content: content,
                                         trigger: trigger))
    }

    // MARK: - Before each lesson

    /// Rebuilds the "Maths in 5 min" reminders from the widgets' feed —
    /// the same lessons, cancelled ones left out. They're kept within what
    /// iOS allows, leaving room for homework reminders, soonest first; each
    /// refresh tops them up.
    static func rescheduleLessons(from feed: WidgetFeed?) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(lessonPrefix) }
        centre.removePendingNotificationRequests(withIdentifiers: ours)

        guard let feed, feed.signedIn, NotifyPrefs.lessons, await isAuthorized() else { return }
        let room = max(0, min(40, pendingLimit - (pending.count - ours.count) - 4))
        let lead = NotifyPrefs.lead
        let now = Date()
        var added = 0

        // Only things that start then: not the second day of a trip, nor a
        // day-long note placed at the start of the day.
        for item in feed.items where !item.cancelled && !item.optional && item.beginsHere {
            guard added < room else { break }
            let fire = item.start.addingTimeInterval(-Double(lead * 60))
            guard fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(item.title) in \(lead) min"
            content.body = [item.room, item.teacher].filter { !$0.isEmpty }.joined(separator: " · ")
            if item.changed { content.subtitle = "Changed" }
            content.sound = .default
            content.threadIdentifier = "lessons"
            content.userInfo = ["link": item.link.absoluteString]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: LectioDates.calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: fire),
                repeats: false)
            try? await centre.add(UNNotificationRequest(
                identifier: lessonPrefix + "\(Int(item.start.timeIntervalSince1970))",
                content: content, trigger: trigger))
            added += 1
        }
    }

    // MARK: - News

    /// What a background check found, shown now.
    static func post(_ alerts: [ChangeAlert]) async {
        guard !alerts.isEmpty, await isAuthorized() else { return }
        let centre = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.subtitle = alert.subtitle
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = alert.topic.rawValue
            if let link = alert.link { content.userInfo = ["link": link.absoluteString] }
            try? await centre.add(UNNotificationRequest(identifier: newsPrefix + alert.id,
                                                        content: content, trigger: nil))
        }
    }

    static func cancelAll() {
        let centre = UNUserNotificationCenter.current()
        centre.getPendingNotificationRequests { requests in
            let ours = requests.map { $0.identifier }
                .filter { $0.hasPrefix(workPrefix) || $0.hasPrefix(absencePrefix) }
            centre.removePendingNotificationRequests(withIdentifiers: ours)
        }
        RemindersStore.clear()
    }
}
