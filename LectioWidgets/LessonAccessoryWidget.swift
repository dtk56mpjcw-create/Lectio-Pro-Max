import Foundation
import SwiftUI
import WidgetKit

/// Lock Screen: the lesson on now or next. A line above the clock, a
/// rectangle with the room and how far through it you are, or a ring.
struct LessonAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LessonLockScreen", provider: FeedProvider()) { entry in
            AccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Lesson")
        .description("The lesson on now or next, on the Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct AccessoryView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    private var feed: WidgetFeed? { entry.feed?.signedIn == true ? entry.feed : nil }
    private var current: WidgetFeed.Item? { feed?.current(at: entry.date) }
    private var item: WidgetFeed.Item? { current ?? feed?.next(after: entry.date) }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        default: rectangular
        }
    }

    /// "Maths until 11:25 · 062", "Danish 11:55 · 114".
    private var inline: some View {
        Group {
            if let item {
                let when = current != nil ? "until " + WidgetFeed.time(item.end) : WidgetFeed.time(item.start)
                Text(item.title + " " + when + (item.room.isEmpty ? "" : " · " + item.room))
            } else {
                Text(entry.feed?.signedIn == false ? "Sign in to Lectio Pro Max" : "No more lessons")
            }
        }
    }

    private var rectangular: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.headline)
                        .widgetAccentable()
                        .lineLimit(1)
                    Text(WidgetFeed.span(item) + (item.room.isEmpty ? "" : " · " + item.room))
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let current {
                        ProgressView(timerInterval: current.start...current.end, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .progressViewStyle(.linear)
                        .padding(.top, 3)
                    } else {
                        let word = WidgetFeed.dayWord(item.start, from: entry.date)
                        Text(word == "Today" ? "Next" : word)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.feed?.signedIn == false ? "Open Lectio Pro Max to sign in." : "No more lessons coming up.")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Now: a ring filling up through the lesson, the room inside.
    /// Before: the start time and room.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let current {
                ProgressView(timerInterval: current.start...current.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    Text(current.room.isEmpty ? String(current.title.prefix(3)) : current.room)
                        .minimumScaleFactor(0.6)
                }
                .progressViewStyle(.circular)
                .widgetAccentable()
            } else if let item {
                VStack(spacing: 0) {
                    Text(WidgetFeed.time(item.start))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Text(item.room.isEmpty ? String(item.title.prefix(3)) : item.room)
                        .font(.caption2)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .padding(4)
            } else {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
            }
        }
    }
}
