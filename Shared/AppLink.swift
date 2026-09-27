import Foundation

/// Links into the app, from a widget or a notification, so a tap lands on
/// what it showed rather than wherever the app was:
///
///     lectiopromax://day?date=2026-09-28
///     lectiopromax://lesson?date=2026-09-28&key=id:123&start=8:00
///     lectiopromax://homework
///     lectiopromax://messages
///
/// The scheme is registered in the app's Info.plist (CFBundleURLTypes).
enum AppLink {
    static let scheme = "lectiopromax"

    enum Route: Equatable {
        case day(String)
        /// `key` is Lectio's own id for the lesson (see ScheduleWatch.lessonKey);
        /// `start` finds it when there isn't one.
        case lesson(date: String, start: String, key: String?)
        case homework
        case messages
    }

    static func day(_ iso: String) -> URL {
        make("day", ["date": iso])
    }

    static func lesson(date: String, start: String, key: String?) -> URL {
        var query = ["date": date, "start": start]
        if let key, !key.isEmpty { query["key"] = key }
        return make("lesson", query)
    }

    static let homework = make("homework", [:])
    static let messages = make("messages", [:])

    static func route(_ url: URL) -> Route? {
        guard url.scheme == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value
        }
        switch url.host {
        case "day":
            return value("date").map { Route.day($0) }
        case "lesson":
            guard let date = value("date") else { return nil }
            return .lesson(date: date, start: value("start") ?? "", key: value("key"))
        case "homework":
            return .homework
        case "messages":
            return .messages
        default:
            return nil
        }
    }

    private static func make(_ host: String, _ query: [String: String]) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return parts.url ?? URL(string: scheme + "://" + host)!
    }
}
