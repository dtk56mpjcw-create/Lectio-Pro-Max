import Foundation
import SwiftUI
import WidgetKit

/// Medium and large: the lesson on now or next, big, and the rest of the
/// day beside or under it; once school's out, the next day's. A tap on a
/// lesson opens it; anywhere else opens that day.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: FeedProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("The lesson on now or next, and the rest of the day.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if let focus = Focus(entry.feed, at: entry.date) {
            Group {
                if family == .systemLarge { large(focus) } else { medium(focus) }
            }
            .widgetURL(AppLink.day(focus.day.date))
        } else {
            EmptyMessage(feed: entry.feed)
        }
    }

    // MARK: Medium: the one that matters, and what follows

    private func medium(_ focus: Focus) -> some View {
        HStack(spacing: 12) {
            lead(focus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            following(focus, large: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Large: the day's title, the one that matters, and the rest

    private func large(_ focus: Focus) -> some View {
        let dayStart = WidgetFeed.startOfDay(focus.day.date) ?? entry.date
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(WidgetFeed.dayWord(dayStart, from: entry.date))
                    .font(.title3.weight(.bold))
                Text(WidgetFeed.shortDate(dayStart))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let note = focus.day.note {
                    Text(note)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            lead(focus)
                .frame(height: 104)
            following(focus, large: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Pieces

    /// The card for the lesson that matters, or what the day is.
    @ViewBuilder
    private func lead(_ focus: Focus) -> some View {
        if let item = focus.item {
            Link(destination: item.link) {
                HeroCard(item: item, label: focus.label, now: entry.date)
                    .padding(10)
                    .background { Tint(colour: item.colour) }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(focus.label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(focus.day.note ?? "No lessons")
                    .font(.headline)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { Tint(colour: "gray") }
        }
    }

    /// The rest of the day — or, when there's none, the next day's under
    /// its name. As many as fit; the rest counted.
    @ViewBuilder
    private func following(_ focus: Focus, large: Bool) -> some View {
        let heading = focus.rest.isEmpty ? focus.later?.label : nil
        let items = focus.rest.isEmpty ? (focus.later?.items ?? []) : focus.rest
        if items.isEmpty {
            Text(focus.item == nil ? "" : "Nothing after this")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else {
            // The longest list that fits the space.
            if large {
                ViewThatFits(in: .vertical) {
                    list(items, heading: heading, limit: 6, topics: true)
                    list(items, heading: heading, limit: 5, topics: true)
                    list(items, heading: heading, limit: 4, topics: true)
                    list(items, heading: heading, limit: 3, topics: true)
                    list(items, heading: heading, limit: 2, topics: true)
                }
            } else {
                ViewThatFits(in: .vertical) {
                    list(items, heading: heading, limit: 3, topics: false)
                    list(items, heading: heading, limit: 2, topics: false)
                    list(items, heading: heading, limit: 1, topics: false)
                }
            }
        }
    }

    private func list(_ items: [WidgetFeed.Item], heading: String?, limit: Int, topics: Bool) -> some View {
        // A "more" line takes a row's place.
        let shown = items.count > limit ? Array(items.prefix(max(limit - 1, 1))) : items
        return VStack(alignment: .leading, spacing: 6) {
            if let heading {
                Text(heading.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { item in
                Link(destination: item.link) {
                    CompactRow(item: item, showsTopic: topics)
                }
            }
            if items.count > shown.count {
                Text("\(items.count - shown.count) more")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
            }
        }
    }
}
