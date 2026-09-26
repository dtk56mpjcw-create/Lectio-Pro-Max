import SwiftUI
import Observation

/// The reminders, observable: set one from a swipe or a long-press and the
/// row's bell appears at once, wherever it was set from.
///
/// RemindersStore stays the record (NotificationService reads it); this only
/// tells SwiftUI when it changes.
@MainActor
@Observable
final class ReminderBook {
    static let shared = ReminderBook()

    /// Bumped on every change; reading it is what makes a view depend on it.
    private var version = 0

    private init() {}

    func timing(for key: String) -> ReminderTiming? {
        _ = version
        return RemindersStore.timing(for: key)
    }

    /// For signing out: the store is emptied; the bells go at once.
    func forgetAll() {
        version += 1
    }

    /// Sets or clears a reminder. False when notifications are off for the
    /// app, in which case nothing is changed.
    func set(_ timing: ReminderTiming?, for key: String) async -> Bool {
        if timing != nil {
            guard await NotificationService.requestPermission() else { return false }
        }
        RemindersStore.set(timing, for: key)
        withAnimation(.snappy) { version += 1 }
        return true
    }
}
