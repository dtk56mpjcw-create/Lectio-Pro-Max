import Foundation
import SwiftUI
import WidgetKit

/// Medium and large: the rest of today's lessons, in their colours; once
/// school's out, the next day's.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: FeedProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("The rest of today's lessons. After school, the next day's.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    private var large: Bool { family == .systemLarge }
    /// Rows that fit: one line each in medium, two in large.
    private var fits: Int { large ? 6 : 3 }

    var body: some View {
        if let feed = entry.feed, feed.signedIn, let day = feed.day(at: entry.date) {
            content(day)
        } else {
            EmptyMessage(feed: entry.feed)
        }
    }

    private func content(_ day: WidgetFeed.Day) -> some View {
        let isToday = day.date == WidgetFeed.iso(entry.date)
        // Today: what's on or still to come. Another day: all of it.
        let items = isToday ? day.items.filter { $0.end > entry.date } : day.items
        let shown = Array(items.prefix(items.count > fits ? fits - 1 : fits))
        let firstDate = WidgetFeed.startOfDay(day.date) ?? entry.date

        return VStack(alignment: .leading, spacing: large ? 9 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(WidgetFeed.dayWord(firstDate, from: entry.date))
                    .font(.headline)
                Text(WidgetFeed.shortDate(firstDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let note = day.note {
                    Text(note)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if items.isEmpty, let note = day.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { item in
                LessonRow(item: item, now: entry.date, detailed: large)
            }
            if items.count > shown.count {
                Text("\(items.count - shown.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One lesson: stripe, start, subject, room. In large, its topic under it.
struct LessonRow: View {
    let item: WidgetFeed.Item
    let now: Date
    let detailed: Bool

    private var isNow: Bool { item.start <= now && now < item.end && !item.cancelled }
    private var second: String? {
        if item.cancelled { return "Cancelled" }
        if item.optional { return "After school" + (item.topic.isEmpty ? "" : " · " + item.topic) }
        return item.topic.isEmpty ? item.tag : item.topic
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Stripe(colour: item.cancelled ? "gray" : item.colour, width: 3,
                   height: detailed && second != nil ? 32 : 17)
            Text(WidgetFeed.time(item.start))
                .font(.subheadline.weight(isNow ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isNow ? .primary : .secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(item.cancelled)
                    .foregroundStyle(item.cancelled ? .secondary : .primary)
                    .lineLimit(1)
                if detailed, let second {
                    Text(second)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !item.room.isEmpty && !item.cancelled {
                Text(item.room)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(item.optional ? 0.65 : 1)
    }
}
