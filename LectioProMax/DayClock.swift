import SwiftUI
import Observation

/// Today's date for the whole app, moving on when the day does.
///
/// Anything that shows "today" (the Next line, the Today and Yesterday
/// titles, today's card in the week, the Today button, Homework's "Today"
/// and "Tomorrow") reads `today` from here, so it's drawn again the moment
/// the date changes, also with the app left open overnight. Before this,
/// each page worked the date out once, when it was built, and yesterday's
/// page still said "Next: Science in 1 h 1 min" the morning after (30 Sep).
///
/// The date comes from the system, the way Apple's own apps get it:
/// `NSCalendarDayChanged` at midnight (or as the phone wakes, if it slept
/// through midnight), `significantTimeChangeNotification` when the clock or
/// the time zone changes, and a look when the app comes back to the
/// foreground (ContentView).
@MainActor @Observable
final class DayClock {
    static let shared = DayClock()

    /// Today, the way Lectio writes dates ("2026-09-30"), in Danish time.
    private(set) var today = LectioDates.isoString(from: Date())

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged,
                     UIApplication.significantTimeChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DayClock.shared.refresh() }
            }
        }
    }

    /// Looks at the date again. Only a new day changes `today`, so the
    /// pages are drawn again once a day, not each time this is called.
    func refresh() {
        let now = LectioDates.isoString(from: Date())
        if now != today { today = now }
    }
}
