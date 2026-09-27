import Foundation
import SwiftUI
import WidgetKit

/// Small: the lesson on now, with how far through it you are, or the next
/// one — subject, time and room, big, on the subject's tint. A tap opens
/// that lesson.
struct NextLessonWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextLesson", provider: FeedProvider()) { entry in
            NextLessonView(entry: entry)
        }
        .configurationDisplayName("Next Lesson")
        .description("The lesson on now or next, with its room.")
        .supportedFamilies([.systemSmall])
    }
}

struct NextLessonView: View {
    let entry: FeedEntry

    var body: some View {
        if let focus = Focus(entry.feed, at: entry.date), let item = focus.item {
            HeroCard(item: item, label: focus.label, now: entry.date,
                     roomFont: .system(.title, design: .rounded).weight(.bold))
                .widgetURL(item.link)
                .containerBackground(for: .widget) {
                    ZStack {
                        Rectangle().fill(.background)
                        Tint(colour: item.colour)
                    }
                }
        } else {
            EmptyMessage(feed: entry.feed)
                .containerBackground(.background, for: .widget)
        }
    }
}
