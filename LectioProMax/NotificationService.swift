import Foundation
import UserNotifications

/// On-device reminders for the specific things you've asked to be reminded of.
///
/// Everything is scheduled locally from dates the app already knows, so it fires
/// exactly on time and needs no server and no push certificate. What it
/// deliberately can't do is tell you about something *new* that arrives while
/// the app is closed — that needs the app to be woken in the background.
enum NotificationService {

    private static let workPrefix = "lectio.work."
    private static let absencePrefix = "lectio.absence."

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
        let calendar = Calendar.current

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

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
            repeats: false)
        centre.add(UNNotificationRequest(identifier: workPrefix + item.key,
                                         content: content,
                                         trigger: trigger))
    }

    private static func scheduleAbsence(_ record: AbsenceRecord,
                                        centre: UNUserNotificationCenter) {
        let calendar = Calendar.current
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
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
            repeats: false)
        centre.add(UNNotificationRequest(identifier: absencePrefix + record.id,
                                         content: content,
                                         trigger: trigger))
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
