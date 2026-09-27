import Foundation
import Observation
import UserNotifications

/// Where a tap on a widget or a notification should land. RootView picks
/// the tab; the Schedule tab goes to the day and opens the lesson.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// A fresh id each time, so tapping the same widget twice goes there
    /// twice.
    struct Request: Equatable {
        let id = UUID()
        let route: AppLink.Route
    }

    var request: Request?

    func open(_ url: URL) {
        guard let route = AppLink.route(url) else { return }
        request = Request(route: route)
    }
}

/// Taps on the app's notifications go where they're about (see AppLink),
/// and a reminder that comes while the app is open still shows.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run { AppRouter.shared.open(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
