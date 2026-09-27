import Foundation
import SwiftUI
import WidgetKit

/// Lectio Pro Max's widgets. They only ever read the feed the app writes
/// (see WidgetFeed): no network, no sign-in. A tap opens the app on what
/// the widget showed (see AppLink).
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

// MARK: - What to show

/// The lesson that matters at a moment — on now, or next — and what
/// follows it that day; when nothing does, the next school day.
struct Focus {
    /// "Now", "Next", "Tomorrow", "Monday".
    let label: String
    let day: WidgetFeed.Day
    let item: WidgetFeed.Item?
    let rest: [WidgetFeed.Item]
    /// The next day's lessons, when nothing else is left on this one.
    let later: (label: String, items: [WidgetFeed.Item])?

    init?(_ feed: WidgetFeed?, at now: Date) {
        guard let feed, feed.signedIn, let day = feed.day(at: now) else { return nil }
        self.day = day
        let isToday = day.date == WidgetFeed.iso(now)
        let dayWord = WidgetFeed.dayWord(WidgetFeed.startOfDay(day.date) ?? now, from: now)
        // Today: what's on or still to come. Another day: all of it.
        let open = day.items.filter { !isToday || $0.end > now }
        let item = open.first { !$0.cancelled && !$0.optional }
        self.item = item
        if let item {
            label = isToday ? (item.start <= now ? "Now" : "Next") : dayWord
            rest = open.filter { $0 != item && $0.start >= item.start }
        } else {
            label = dayWord
            rest = open
        }
        if rest.isEmpty,
           let next = feed.days.first(where: { $0.date > day.date && !$0.items.isEmpty }) {
            later = (WidgetFeed.dayWord(WidgetFeed.startOfDay(next.date) ?? now, from: now),
                     next.items.filter { !$0.optional })
        } else {
            later = nil
        }
    }

    /// Where a tap on the whole widget goes.
    var link: URL { item?.link ?? AppLink.day(day.date) }
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

/// A lesson's card tint, as in the app's day.
struct Tint: View {
    let colour: String
    @Environment(\.colorScheme) var scheme

    var body: some View {
        ContainerRelativeShape()
            .fill(Color.subject(colour).opacity(scheme == .dark ? 0.24 : 0.14))
    }
}

/// The one that matters: its time, subject and room, big, on its tint.
struct HeroCard: View {
    let item: WidgetFeed.Item
    let label: String
    let now: Date
    var roomFont: Font = .system(.title2, design: .rounded).weight(.bold)

    private var isNow: Bool { item.start <= now && now < item.end }

    /// "NOW", "TOMORROW · EXAM", "NEXT · CHANGED".
    private var header: String {
        var parts = [label]
        if let tag = item.tag {
            parts.append(tag)
        } else if item.changed {
            parts.append("Changed")
        }
        return parts.joined(separator: " · ").uppercased()
    }

    var body: some View {
        HStack(spacing: 9) {
            Stripe(colour: item.colour)
            VStack(alignment: .leading, spacing: 1) {
                Text(header)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(WidgetFeed.span(item))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(item.room.isEmpty ? " " : item.room)
                        .font(roomFont)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Spacer(minLength: 0)
                    Text(item.teacher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isNow {
                    ProgressView(timerInterval: item.start...item.end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(Color.subject(item.colour))
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A lesson in a list: stripe, subject, and its time and room under it.
struct CompactRow: View {
    let item: WidgetFeed.Item
    var showsTopic = false

    private var detail: String {
        if item.cancelled { return WidgetFeed.clock(item.start) + " · Cancelled" }
        var parts = [WidgetFeed.clock(item.start)]
        if !item.room.isEmpty { parts.append(item.room) }
        if showsTopic, !item.topic.isEmpty { parts.append(item.topic) }
        if item.optional { parts.append("After school") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Stripe(colour: item.cancelled ? "gray" : item.colour, width: 3, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(item.cancelled)
                    .foregroundStyle(item.cancelled ? .secondary : .primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(item.optional ? 0.7 : 1)
    }
}

/// Nothing to show: signed out, or nothing coming up.
struct EmptyMessage: View {
    let feed: WidgetFeed?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: feed?.signedIn == false || feed == nil ? "person.crop.circle" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline.weight(.medium))
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

    /// "9:50–11:25".
    static func span(_ item: Item) -> String {
        clock(item.start) + "–" + clock(item.end)
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
