import Foundation
import SwiftUI
import WidgetKit

/// Medium: the lesson on now or next as a card, the rest of the day beside
/// it. Large: the day's agenda — every lesson left, with its topic, the one
/// that matters highlighted — and the homework due. Once school's out, the
/// next day. A tap on a lesson opens it; on homework, the Homework tab;
/// anywhere else, that day.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: FeedProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("The lesson on now or next and the rest of the day. The large size adds topics and homework.")
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

    // MARK: - Medium: the one that matters, and what follows

    private func medium(_ focus: Focus) -> some View {
        HStack(spacing: 12) {
            lead(focus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            following(focus)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

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
    /// its name. As many as fit; what doesn't is counted: on a line of its
    /// own when there's room, otherwise as "+1" on the last row.
    @ViewBuilder
    private func following(_ focus: Focus) -> some View {
        let heading = focus.rest.isEmpty ? focus.later?.label : nil
        let items = focus.rest.isEmpty ? (focus.later?.items ?? []) : focus.rest
        if items.isEmpty {
            Text(focus.item == nil ? "" : "Nothing after this")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else {
            ViewThatFits(in: .vertical) {
                list(items, heading: heading, rows: 4, countLine: true)
                list(items, heading: heading, rows: 4, countLine: false)
                list(items, heading: heading, rows: 3, countLine: true)
                list(items, heading: heading, rows: 3, countLine: false)
                list(items, heading: heading, rows: 2, countLine: false)
                list(items, heading: heading, rows: 1, countLine: false)
            }
        }
    }

    private func list(_ items: [WidgetFeed.Item], heading: String?, rows: Int,
                      countLine: Bool) -> some View {
        let shown = Array(items.prefix(rows))
        let hidden = items.count - shown.count
        return VStack(alignment: .leading, spacing: 4) {
            if let heading {
                Text(heading.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                Link(destination: item.link) {
                    CompactRow(item: item,
                               extra: !countLine && hidden > 0 && index == shown.count - 1 ? "+\(hidden)" : nil)
                }
            }
            if countLine && hidden > 0 {
                Text("\(hidden) more")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
            }
        }
    }

    // MARK: - Large: the day's agenda and its homework

    private func large(_ focus: Focus) -> some View {
        let dayStart = WidgetFeed.startOfDay(focus.day.date) ?? entry.date
        let lessons = ([focus.item].compactMap { $0 } + focus.rest)
            .sorted { $0.start < $1.start }
        let later = focus.later
        let work = focus.day.work ?? []

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(WidgetFeed.dayWord(dayStart, from: entry.date))
                    .font(.title3.weight(.bold))
                Text(WidgetFeed.shortDate(dayStart))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(focus.day.note ?? count(lessons))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // The fullest version that fits: every lesson and up to three
            // pieces of homework, then less homework, then fewer lessons.
            ViewThatFits(in: .vertical) {
                agenda(lessons, focus: focus, later: later, rows: 8, work: work, workRows: 3)
                agenda(lessons, focus: focus, later: later, rows: 8, work: work, workRows: 2)
                agenda(lessons, focus: focus, later: later, rows: 8, work: work, workRows: 1)
                agenda(lessons, focus: focus, later: later, rows: 8, work: work, workRows: 0)
                agenda(lessons, focus: focus, later: nil, rows: 8, work: work, workRows: 0)
                agenda(lessons, focus: focus, later: nil, rows: 5, work: work, workRows: 0)
                agenda(lessons, focus: focus, later: nil, rows: 4, work: work, workRows: 0)
                agenda(lessons, focus: focus, later: nil, rows: 3, work: work, workRows: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// "4 lessons", counting the real ones.
    private func count(_ lessons: [WidgetFeed.Item]) -> String {
        let n = lessons.filter { !$0.cancelled && !$0.optional }.count
        return n == 1 ? "1 lesson" : "\(n) lessons"
    }

    private func agenda(_ lessons: [WidgetFeed.Item], focus: Focus,
                        later: (label: String, items: [WidgetFeed.Item])?,
                        rows: Int, work: [WidgetFeed.Work], workRows: Int) -> some View {
        let shown = Array(lessons.prefix(rows))
        let hidden = lessons.count - shown.count
        return VStack(alignment: .leading, spacing: 5) {
            if lessons.isEmpty, let note = focus.day.note {
                Text(note)
                    .font(.headline)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                Link(destination: item.link) {
                    AgendaRow(item: item, highlighted: item == focus.item, now: entry.date,
                              extra: hidden > 0 && index == shown.count - 1 ? "+\(hidden)" : nil)
                }
            }
            if let later, !later.items.isEmpty {
                Text(later.label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(later.items.prefix(3), id: \.self) { item in
                    Link(destination: item.link) {
                        AgendaRow(item: item, highlighted: false, now: entry.date, extra: nil)
                    }
                }
            }
            if workRows > 0 && !work.isEmpty {
                Link(destination: AppLink.homework) {
                    WorkList(work: work, rows: workRows)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// A lesson in the day's agenda: time, subject and room, its topic under
/// them. The one on now or next sits on its subject's tint.
struct AgendaRow: View {
    let item: WidgetFeed.Item
    let highlighted: Bool
    let now: Date
    let extra: String?

    private var isNow: Bool { item.start <= now && now < item.end && !item.cancelled }

    private var second: String {
        if item.cancelled { return "Cancelled" }
        var parts: [String] = []
        if isNow { parts.append("Now · until " + WidgetFeed.clock(item.end)) }
        if let tag = item.tag { parts.append(tag) }
        if item.optional { parts.append("After school") }
        if !item.topic.isEmpty { parts.append(item.topic) }
        if parts.isEmpty, !item.teacher.isEmpty { parts.append(item.teacher) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Stripe(colour: item.cancelled ? "gray" : item.colour, width: 3, height: 30)
            Text(WidgetFeed.clock(item.start))
                .font(.subheadline.weight(highlighted ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(highlighted ? .primary : .secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(item.cancelled)
                    .foregroundStyle(item.cancelled ? .secondary : .primary)
                    .lineLimit(1)
                if !second.isEmpty {
                    Text(second)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !item.room.isEmpty && !item.cancelled {
                Text(item.room)
                    .font(.subheadline.weight(highlighted ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? .primary : .secondary)
                    .lineLimit(1)
            }
            if let extra {
                Text(extra)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, highlighted ? 5 : 0)
        .padding(.horizontal, highlighted ? 6 : 0)
        .background {
            if highlighted { Tint(colour: item.colour) }
        }
        .padding(.horizontal, highlighted ? -6 : 0)
        .opacity(item.optional ? 0.7 : 1)
    }
}

/// "HOMEWORK" and what's due, one line each, the rest counted.
struct WorkList: View {
    let work: [WidgetFeed.Work]
    let rows: Int

    var body: some View {
        let shown = Array(work.prefix(rows))
        let hidden = work.count - shown.count
        VStack(alignment: .leading, spacing: 3) {
            Text("HOMEWORK")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(shown, id: \.self) { piece in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(Color.subject(piece.colour))
                        .frame(width: 7, height: 7)
                        .widgetAccentable()
                    Text("\(Text(piece.subject).fontWeight(.semibold))  \(Text(piece.text).foregroundStyle(.secondary))")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hidden > 0 && piece == shown.last {
                        Text("+\(hidden)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
