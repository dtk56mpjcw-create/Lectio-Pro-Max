import SwiftUI

// MARK: - The week, as a list of days

/// The week the way Calendar's list and Fantastical show one: a card per
/// day, a line per lesson, full names instead of codes. The old timetable
/// grid squeezed five days across a phone and cut every name down to three
/// letters; here nothing is cut, and it reads top to bottom like the day.
///
/// Tap a day's header to open the day, a lesson to open the lesson. Days
/// already over this week fold down to one line, so the week starts where
/// you are.
struct WeekAgenda: View {
    let week: ScheduleWeek
    let monday: String
    let className: String
    var onPick: (String) -> Void

    var body: some View {
        let today = LectioDates.isoString(from: Date())
        let dates = Self.dates(in: week, monday: monday)
        let modules = week.resolvedModules
        let plans = dates.map { Self.plan(for: $0, in: week, modules: modules, className: className) }
        // Past days fold only while something in this week is still to
        // come; looking back at a finished week, you want all of it.
        let stillAhead = dates.contains { $0 >= today }

        if plans.allSatisfy(\.isEmpty) {
            EmptyNotice(icon: "sun.max", text: "No lessons this week")
        } else {
            VStack(spacing: 12) {
                ForEach(Array(zip(dates, plans)), id: \.0) { date, plan in
                    if date == today {
                        TimelineView(.everyMinute) { context in
                            WeekDayCard(date: date, plan: plan, isToday: true,
                                        startsFolded: false, now: context.date, onPick: onPick)
                        }
                    } else {
                        WeekDayCard(date: date, plan: plan, isToday: false,
                                    startsFolded: stillAhead && date < today, now: nil, onPick: onPick)
                    }
                }
            }
        }
    }

    // MARK: Working it out

    /// Monday to Friday always; the weekend only when something's on.
    static func dates(in week: ScheduleWeek, monday: String) -> [String] {
        var out = (0..<5).map { LectioDates.shift(iso: monday, byDays: $0) }
        for extra in [5, 6] {
            let date = LectioDates.shift(iso: monday, byDays: extra)
            if week.days.contains(where: { $0.date == date && $0.lessons.contains { !$0.isAllDay } }) {
                out.append(date)
            }
        }
        return out
    }

    static func plan(for date: String, in week: ScheduleWeek,
                     modules: [ScheduleModule], className: String) -> DayPlan {
        let day = week.days.first { $0.date == date }
            ?? ScheduleDay(date: date, label: LectioDates.dayLabel(iso: date), lessons: [])
        return DayPlan.build(day, modules: modules, className: className)
    }

    /// Under the week's title: "21 – 25 Sep · 19 lessons · 6 with homework".
    static func subtitle(week: ScheduleWeek?, monday: String, className: String) -> String? {
        guard let week else { return nil }
        let days = Self.dates(in: week, monday: monday)
        guard let first = days.first, let last = days.last else { return nil }
        let modules = week.resolvedModules
        let lessons = days
            .flatMap { Self.plan(for: $0, in: week, modules: modules, className: className).slots }
            .flatMap(\.main)
            .filter(\.isClassLesson)
        var parts = [Self.range(first, last)]
        if lessons.isEmpty {
            parts.append("No lessons")
        } else {
            parts.append(lessons.count == 1 ? "1 lesson" : "\(lessons.count) lessons")
            let homework = lessons.filter { !$0.homework.isEmpty }.count
            if homework > 0 { parts.append("\(homework) with homework") }
        }
        return parts.joined(separator: " · ")
    }

    /// "21 – 25 Sep", or "28 Sep – 2 Oct" across a month.
    private static func range(_ first: String, _ last: String) -> String {
        let a = LectioDates.dayLabel(iso: first).split(separator: " ").map(String.init)
        let b = LectioDates.dayLabel(iso: last).split(separator: " ").map(String.init)
        guard a.count == 3, b.count == 3 else { return "" }
        return a[2] == b[2] ? "\(a[1]) – \(b[1]) \(b[2])" : "\(a[1]) \(a[2]) – \(b[1]) \(b[2])"
    }
}

private extension DayPlan {
    var isEmpty: Bool {
        allDay.isEmpty && before.isEmpty && after.isEmpty && !slots.contains(where: \.hasAnything)
    }
}

// MARK: - A day

/// One line of a day card.
private struct WeekRow: Identifiable {
    enum Kind {
        case allDay(Lesson)
        case lesson(Lesson)
        case cancelled(Lesson)
        case free
        case outside(Lesson)
    }

    let id: String
    let kind: Kind
    /// The module number down the side: "2", or "1–2" for a double.
    var label: String = ""
    var first: ScheduleModule? = nil
    var last: ScheduleModule? = nil

    var lesson: Lesson? {
        switch kind {
        case .allDay(let l), .lesson(let l), .cancelled(let l), .outside(let l): return l
        case .free: return nil
        }
    }

    /// The day's lines, top to bottom: all-day items, anything before
    /// school, each module from your first to your last (a free one in
    /// between says so; a double is one line), then after school.
    static func rows(_ plan: DayPlan) -> [WeekRow] {
        var out: [WeekRow] = []
        for item in plan.allDay { out.append(WeekRow(id: "a|" + item.id, kind: .allDay(item))) }
        for item in plan.before { out.append(WeekRow(id: "b|" + item.id, kind: .outside(item))) }

        let busy = plan.slots.indices.filter { plan.slots[$0].hasAnything }
        if let from = busy.first, let to = busy.last {
            for slot in plan.slots[from...to] {
                let n = slot.module.number
                if !slot.main.isEmpty {
                    for (k, lesson) in slot.main.enumerated() {
                        out.append(WeekRow(id: "m\(n)|" + lesson.id, kind: .lesson(lesson),
                                           label: k == 0 ? "\(n)" : "", first: slot.module, last: slot.module))
                    }
                } else if !slot.continuing.isEmpty {
                    for lesson in slot.continuing {
                        if let j = out.lastIndex(where: { row in
                            if case .lesson(let l) = row.kind { return l.id == lesson.id }
                            return false
                        }) {
                            out[j].label = "\(out[j].first?.number ?? n)–\(n)"
                            out[j].last = slot.module
                        } else {
                            out.append(WeekRow(id: "c\(n)|" + lesson.id, kind: .lesson(lesson),
                                               label: "\(n)", first: slot.module, last: slot.module))
                        }
                    }
                } else if let cancelled = slot.cancelled.first {
                    out.append(WeekRow(id: "x\(n)|" + cancelled.id, kind: .cancelled(cancelled),
                                       label: "\(n)", first: slot.module, last: slot.module))
                } else {
                    out.append(WeekRow(id: "f\(n)", kind: .free,
                                       label: "\(n)", first: slot.module, last: slot.module))
                }
            }
        }

        for item in plan.after { out.append(WeekRow(id: "z|" + item.id, kind: .outside(item))) }
        return out
    }
}

private struct WeekDayCard: View {
    let date: String
    let plan: DayPlan
    let isToday: Bool
    let startsFolded: Bool
    let now: Date?
    var onPick: (String) -> Void

    @State private var unfolded = false

    private var folded: Bool { startsFolded && !unfolded }
    private var nowMinutes: Int? { now.map { DayList.minutes(of: $0) } }

    var body: some View {
        let rows = WeekRow.rows(plan)
        VStack(spacing: 0) {
            header(rows)
            if !rows.isEmpty {
                Divider()
                if folded {
                    foldedLine(rows)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, WeekLine.textInset) }
                        line(row)
                    }
                }
            }
        }
        .contentCard(radius: Metrics.inner + 4)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(0.7), lineWidth: 1.5)
            }
        }
    }

    // MARK: Header

    /// "Monday 21 Sep ··· 8:00–15:15 ›" — opens the day.
    private func header(_ rows: [WeekRow]) -> some View {
        let title = ScheduleTab.dayTitle(date)
        let short = LectioDates.dayLabel(iso: date)              // "Mon 21 Sep"
        // "Today · Sat 26 Sep"; a weekday name already says the weekday.
        let dateText = title == LectioDates.longLabel(iso: date).split(separator: " ").first.map(String.init)
            ? String(short.drop { $0 != " " }.dropFirst())
            : short
        return Button {
            onPick(date)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isToday ? Palette.accent : Color.primary)
                Text(dateText)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(hours ?? (rows.isEmpty ? "Nothing on" : ""))
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel(LectioDates.longLabel(iso: date) + (hours.map { ", " + $0 } ?? ""))
        .accessibilityHint("Opens the day")
    }

    /// From your first module to your last: "8:00–15:15".
    private var hours: String? {
        let busy = plan.slots.filter { !$0.isFree }
        guard let first = busy.first, let last = busy.last else { return nil }
        return first.module.shortStart + "–" + last.module.shortEnd
    }

    // MARK: Lines

    @ViewBuilder
    private func line(_ row: WeekRow) -> some View {
        if let item = row.lesson {
            OpenButton(lesson: item, dayISO: date, asRow: true) {
                WeekLine(row: row, state: timing(row))
            }
        } else {
            WeekLine(row: row, state: timing(row))
        }
    }

    /// Where a module stands against the clock, today.
    private func timing(_ row: WeekRow) -> WeekLine.Timing {
        guard let nowMinutes, let first = row.first, let last = row.last else { return .later }
        if nowMinutes >= last.endMinutes { return .over }
        if nowMinutes >= first.startMinutes { return .now }
        return .later
    }

    /// A folded day: what it had, in one line; tap to see it again.
    private func foldedLine(_ rows: [WeekRow]) -> some View {
        var seen: Set<String> = []
        let names = rows.compactMap { row -> String? in
            if case .lesson(let l) = row.kind { return l.headline }
            return nil
        }
        .filter { seen.insert($0).inserted }
        let summary = names.isEmpty
            ? rows.compactMap { $0.lesson?.headline }.joined(separator: " · ")
            : names.joined(separator: " · ")

        return Button {
            withAnimation(.snappy) { unfolded = true }
        } label: {
            HStack(spacing: 8) {
                Text(summary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11.5, weight: .bold))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel("Show the day: " + summary)
    }
}

// MARK: - A line

/// Module number, a mark in the subject's colour, the name, and what's
/// worth knowing on the right: homework, a change, the room.
private struct WeekLine: View {
    enum Timing { case over, now, later }

    /// Where the name starts, for the dividers between lines.
    static let textInset: CGFloat = 14 + 30 + 10 + 4 + 10

    let row: WeekRow
    let state: Timing
    @Environment(\.colorScheme) private var scheme

    private var isFree: Bool {
        if case .free = row.kind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            side
                .frame(width: 30)
            Capsule()
                .fill(stripe)
                .frame(width: 4, height: 20)
            WeekLineMain(row: row, over: state == .over)
                .frame(maxWidth: .infinity, alignment: .leading)
            WeekLineTrailing(row: row)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isFree ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The module number; a calendar for an all-day item.
    @ViewBuilder
    private var side: some View {
        if case .allDay = row.kind {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Text(row.label)
                .font(.system(size: row.label.count > 2 ? 12.5 : 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state == .now ? Palette.accent : Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var stripe: Color {
        switch row.kind {
        case .lesson(let l) where l.isClassLesson:
            return Color.subjectStripe(l.code, in: scheme).opacity(state == .over ? 0.5 : 1)
        case .lesson, .outside:
            return Color(.systemGray3)
        case .cancelled:
            return Color(.systemGray4)
        case .allDay, .free:
            return .clear
        }
    }
}

/// The name, and for a lesson its topic after it in grey.
private struct WeekLineMain: View {
    let row: WeekRow
    let over: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch row.kind {
            case .allDay(let item):
                Text(item.headline)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            case .lesson(let lesson):
                if lesson.isPrivateEvent {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(lesson.headline)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(over ? Color(.secondaryLabel) : Color.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let topic = topic(lesson) {
                    Text(topic)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .cancelled(let lesson):
                Text(lesson.headline)
                    .font(.system(size: 15.5, weight: .medium))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("Cancelled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.negative)
                    .lineLimit(1)
            case .outside(let item):
                Text(item.headline)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(over ? Color(.secondaryLabel) : Color.primary)
                    .lineLimit(1)
            case .free:
                Text("Free")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The first line of the topic, if it says anything the name doesn't.
    private func topic(_ lesson: Lesson) -> String? {
        guard let raw = lesson.topic else { return nil }
        let first = LectioDates.tidy(raw).components(separatedBy: "\n").first ?? ""
        guard !first.isEmpty, first.lowercased() != lesson.headline.lowercased() else { return nil }
        return first
    }
}

/// Homework, a change, and the room (or the time, for something outside
/// the modules; the span, for an all-day item).
private struct WeekLineTrailing: View {
    let row: WeekRow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            switch row.kind {
            case .lesson(let lesson):
                if !lesson.homework.isEmpty {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(lesson.isClassLesson
                                         ? Color.subjectStripe(lesson.code, in: scheme)
                                         : Color(.secondaryLabel))
                        .accessibilityLabel("Homework")
                }
                if lesson.changed && lesson.isClassLesson {
                    Circle().fill(Palette.warning).frame(width: 7, height: 7)
                        .accessibilityLabel("Changed")
                }
                room(lesson)
            case .outside(let item):
                if !item.start.isEmpty {
                    Text(short(item.start) + "–" + short(item.end))
                        .font(.system(size: 13.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            case .allDay(let item):
                if let span = item.allDay, !span.isEmpty {
                    Text(span)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            case .cancelled, .free:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func room(_ lesson: Lesson) -> some View {
        if !lesson.room.isEmpty {
            Text(LessonText.abbreviated(lesson.room))
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
}

// MARK: - Pressing a row

/// A row inside a card lights up under the finger, as a list row does,
/// instead of shrinking like a whole card.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
