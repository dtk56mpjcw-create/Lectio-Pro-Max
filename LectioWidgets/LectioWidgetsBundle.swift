import Foundation
import SwiftUI
import WidgetKit

/// Lectio Pro Max's widgets. They only ever read the feed the app writes
/// (see WidgetFeed): no network, no sign-in.
@main
struct LectioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextLessonWidget()
        TodayWidget()
        LessonAccessoryWidget()
    }
}

// MARK: - Timeline

struct FeedEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written a feed.
    let feed: WidgetFeed?
}

/// One entry now and one at every start and end of a lesson, so each widget
/// moves on by itself through the day. The app reloads them whenever the
/// schedule changes.
struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: .now, feed: WidgetFeed.sample(around: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        let feed = WidgetFeed.load()
        // The widget gallery shows an example until there's something real.
        if context.isPreview && (feed == nil || feed?.days.isEmpty == true) {
            completion(FeedEntry(date: .now, feed: WidgetFeed.sample(around: .now)))
        } else {
            completion(FeedEntry(date: .now, feed: feed))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        let now = Date()
        let feed = WidgetFeed.load()
        var entries = [FeedEntry(date: now, feed: feed)]
        for moment in feed?.moments(after: now) ?? [] {
            entries.append(FeedEntry(date: moment, feed: feed))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Shared pieces

extension Color {
    /// A subject's colour by the name the app stores (one of Apple's
    /// system colours), so a subject looks the same here as in the app.
    static func subject(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return .gray
        }
    }
}

/// The lesson stripe, as the app draws it: a little darker in light mode
/// so yellow and green still read as a mark.
struct Stripe: View {
    let colour: String
    var width: CGFloat = 4
    var height: CGFloat? = nil
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let base = Color.subject(colour)
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(scheme == .dark ? base : base.mix(with: .black, by: 0.35))
            .frame(width: width, height: height)
            .widgetAccentable()
    }
}

/// Nothing to show: signed out, or nothing coming up.
struct EmptyMessage: View {
    let feed: WidgetFeed?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: feed?.signedIn == false || feed == nil ? "person.crop.circle" : "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var text: String {
        guard let feed else { return "Open Lectio Pro Max to see your lessons here." }
        if !feed.signedIn { return "Open Lectio Pro Max to sign in." }
        return "No more lessons coming up."
    }
}

extension WidgetFeed {
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMM"
        return f
    }()

    /// "Today", "Tomorrow", "Monday", for the day a moment falls on.
    static func dayWord(_ date: Date, from now: Date) -> String {
        let day = iso(date)
        if day == iso(now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), day == iso(tomorrow) {
            return "Tomorrow"
        }
        return weekdayFormatter.string(from: date)
    }

    /// "29 Sep".
    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    /// "9:50", Danish time, as Lectio writes it.
    static func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "9:50–11:25".
    static func span(_ item: Item) -> String {
        time(item.start) + "–" + time(item.end)
    }

    /// "062 · AM".
    static func place(_ item: Item) -> String {
        [item.room, item.teacher].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// An example day for the widget gallery, around the time it's shown.
    static func sample(around now: Date) -> WidgetFeed {
        let step: TimeInterval = 300
        let base = Date(timeIntervalSinceReferenceDate:
                            (now.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let items = [
            Item(title: "Maths", topic: "Vectors", room: "062", teacher: "AM",
                 start: at(-30), end: at(65), colour: "blue"),
            Item(title: "Danish", topic: "Poetry", room: "114", teacher: "KF",
                 start: at(80), end: at(175), colour: "red"),
            Item(title: "English", topic: "Essay writing", room: "064", teacher: "JN",
                 start: at(205), end: at(300), colour: "purple"),
            Item(title: "History", topic: "The Cold War", room: "012", teacher: "Chr",
                 start: at(310), end: at(405), colour: "orange"),
        ]
        return WidgetFeed(signedIn: true, days: [Day(date: iso(now), items: items)])
    }
}
