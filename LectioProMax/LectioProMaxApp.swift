import SwiftUI
import UserNotifications

@main
struct LectioProMaxApp: App {
    init() {
        // Before launch finishes, so a tap that opened the app is routed.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Text grows with the reader's setting up to the third
                // accessibility size (about 2.3×); past that the timetable's
                // columns can't hold a time.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        // iOS wakes the app now and then to look for news (see BackgroundCheck).
        .backgroundTask(.appRefresh(BackgroundCheck.taskID)) {
            await BackgroundCheck.run()
        }
    }
}
