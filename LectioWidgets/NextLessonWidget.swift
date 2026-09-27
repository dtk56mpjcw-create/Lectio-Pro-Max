import Foundation
import SwiftUI
import WidgetKit

/// Small: the lesson on now, with how far through it you are, and what's
/// next — or, between lessons, the next one. Like Calendar's Up Next.
struct NextLessonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextLesson", provider: FeedProvider()) { entry in
            NextLessonView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Next Lesson")
        .description("The lesson on now or next, with its room.")
        .supportedFamilies([.systemSmall])
    }
}

struct NextLessonView: View {
    let entry: FeedEntry

    var body: some View {
        if let feed = entry.feed, feed.signedIn,
           let item = feed.current(at: entry.date) ?? feed.next(after: entry.date) {
            content(feed, item)
        } else {
            EmptyMessage(feed: entry.feed)
        }
    }

    private func content(_ feed: WidgetFeed, _ item: WidgetFeed.Item) -> some View {
        let isNow = item.start <= entry.date
        let then = feed.next(after: isNow ? entry.date : item.start)
            .flatMap { WidgetFeed.iso($0.start) == WidgetFeed.iso(item.start) ? $0 : nil }

        return VStack(alignment: .leading, spacing: 0) {
            Text(header(item, isNow: isNow).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            HStack(alignment: .top, spacing: 8) {
                Stripe(colour: item.colour, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(WidgetFeed.span(item))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if !WidgetFeed.place(item).isEmpty {
                        Text(WidgetFeed.place(item))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            if isNow {
                ProgressView(timerInterval: item.start...item.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(Color.subject(item.colour))
                .padding(.bottom, then == nil ? 0 : 5)
            }
            if let then {
                Text("Then \(then.title) · \(WidgetFeed.time(then.start))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Now", "Next", "Tomorrow", "Monday" — and "Exam" or "Changed" when
    /// it's worth knowing.
    private func header(_ item: WidgetFeed.Item, isNow: Bool) -> String {
        var parts = [isNow ? "Now" : (WidgetFeed.dayWord(item.start, from: entry.date) == "Today"
                                        ? "Next" : WidgetFeed.dayWord(item.start, from: entry.date))]
        if let tag = item.tag { parts.append(tag) } else if item.changed { parts.append("Changed") }
        return parts.joined(separator: " · ")
    }
}
