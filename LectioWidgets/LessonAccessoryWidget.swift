import Foundation
import SwiftUI
import WidgetKit

/// Lock Screen: the lesson on now or next — a line above the clock, a
/// rectangle with the subject big and the room, or a ring. A tap opens it.
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
    @Environment(\.widgetFamily) var family

    private var feed: WidgetFeed? { entry.feed?.signedIn == true ? entry.feed : nil }
    private var current: WidgetFeed.Item? { feed?.current(at: entry.date) }
    private var item: WidgetFeed.Item? { current ?? feed?.next(after: entry.date) }
    /// "Next", "Tomorrow", "Monday".
    private var when: String {
        guard let item else { return "" }
        let word = WidgetFeed.dayWord(item.start, from: entry.date)
        return word == "Today" ? "Next" : word
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            default: rectangular
            }
        }
        .widgetURL(item?.link)
    }

    /// "Maths · 062 until 11:25", "9:50 Danish · 114", "Tomorrow 8:00 Maths".
    private var inline: some View {
        Group {
            if let item {
                if current != nil {
                    Text(item.title + (item.room.isEmpty ? "" : " · " + item.room)
                         + " until " + WidgetFeed.clock(item.end))
                } else if when == "Next" {
                    Text(WidgetFeed.clock(item.start) + " " + item.title
                         + (item.room.isEmpty ? "" : " · " + item.room))
                } else {
                    Text(when + " " + WidgetFeed.clock(item.start) + " " + item.title)
                }
            } else {
                Text(entry.feed?.signedIn == false ? "Sign in to Lectio Pro Max" : "No more lessons")
            }
        }
    }

    /// The subject as big as it fits whole; its time and room; then how
    /// far through it you are, or when it is. Fixed sizes: the rectangle
    /// doesn't grow with the text size, so three lines always fit.
    private var rectangular: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 1) {
                    // The largest size that shows the whole name.
                    ViewThatFits(in: .horizontal) {
                        title(item.title, size: 19)
                        title(item.title, size: 17)
                        title(item.title, size: 15)
                        title(item.title, size: 15)
                            .minimumScaleFactor(0.75)
                    }
                    Text(WidgetFeed.span(item) + (item.room.isEmpty ? "" : " · " + item.room))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let current {
                        ProgressView(timerInterval: current.start...current.end, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .progressViewStyle(.linear)
                        .padding(.top, 4)
                    } else {
                        Text(when)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.feed?.signedIn == false ? "Open Lectio Pro Max to sign in." : "No more lessons coming up.")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func title(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .widgetAccentable()
            .lineLimit(1)
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
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .minimumScaleFactor(0.5)
                }
                .progressViewStyle(.circular)
                .widgetAccentable()
            } else if let item {
                VStack(spacing: 0) {
                    Text(WidgetFeed.clock(item.start))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    Text(item.room.isEmpty ? String(item.title.prefix(3)) : item.room)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
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
