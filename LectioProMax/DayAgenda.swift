import SwiftUI

// MARK: - The day

/// The day as the school runs it: one row per module, your lesson in each
/// as a block in its subject's colour, free modules as free, and anything
/// else going on in a module folded into a line under it. All-day items sit
/// in a strip on top; things outside the modules come before or after.
///
/// Equatable so a page rebuilds only when its own day changes; today's
/// clock ticks inside on its own.
struct DayList: View, Equatable {
    let day: ScheduleDay?
    let modules: [ScheduleModule]
    let className: String

    static func == (lhs: DayList, rhs: DayList) -> Bool {
        lhs.day == rhs.day && lhs.modules == rhs.modules && lhs.className == rhs.className
    }

    var body: some View {
        if let day, !day.lessons.isEmpty {
            let plan = DayPlan.build(day, modules: modules, className: className)
            if day.date == LectioDates.isoString(from: Date()) {
                TimelineView(.everyMinute) { context in
                    DayContent(plan: plan, dayISO: day.date, now: context.date)
                }
            } else {
                DayContent(plan: plan, dayISO: day.date, now: nil)
            }
        } else {
            EmptyNotice(icon: "sun.max", text: "Nothing scheduled")
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func minutes(of date: Date) -> Int {
        let c = Lesson.sharedCalendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

private struct DayContent: View {
    let plan: DayPlan
    let dayISO: String
    let now: Date?

    private var nowMinutes: Int? { now.map { DayList.minutes(of: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.allDay.isEmpty {
                AllDayStrip(items: plan.allDay, dayISO: dayISO)
            }

            ForEach(plan.before) { item in
                OutsideRow(lesson: item, dayISO: dayISO)
            }

            ForEach(Array(plan.slots.enumerated()), id: \.element.id) { index, slot in
                if let line = nowLine(before: index) {
                    NowLine(text: line)
                }
                ModuleRow(slot: slot, dayISO: dayISO, now: now)
            }

            if let nowMinutes, let end = plan.schoolEnd, nowMinutes >= end {
                DoneLine()
            }

            if !plan.after.isEmpty {
                Text("AFTER SCHOOL")
                    .font(.system(size: 12.5, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 6)
                ForEach(plan.after) { item in
                    OutsideRow(lesson: item, dayISO: dayISO)
                }
            }
        }
    }

    /// Today, before a module you're waiting for: what's next and when.
    private func nowLine(before index: Int) -> String? {
        guard let nowMinutes else { return nil }
        let slot = plan.slots[index]
        guard !slot.isFree, nowMinutes < slot.module.startMinutes else { return nil }
        // Only for the first module still to come.
        let earlierAhead = plan.slots[..<index].contains { !$0.isFree && nowMinutes < $0.module.endMinutes }
        guard !earlierAhead else { return nil }
        guard let lesson = (slot.main + slot.continuing).first else { return nil }
        let start = lesson.startMinutes ?? slot.module.startMinutes
        let room = lesson.room.isEmpty ? "" : " · " + LessonText.abbreviated(lesson.room)
        return "Next: " + lesson.headline + " in " + DayList.duration(start - nowMinutes) + room
    }
}

// MARK: - A module

private struct ModuleRow: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?

    private var nowMinutes: Int? { now.map { DayList.minutes(of: $0) } }
    private var isCurrent: Bool {
        guard let nowMinutes else { return false }
        return nowMinutes >= slot.module.startMinutes && nowMinutes < slot.module.endMinutes
    }
    private var isPast: Bool {
        if let nowMinutes { return nowMinutes >= slot.module.endMinutes }
        return dayISO < LectioDates.isoString(from: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            label
            if slot.isFree {
                FreeCard(slot: slot, dayISO: dayISO)
            } else {
                SlotCard(slot: slot, dayISO: dayISO, now: now, isCurrent: isCurrent, isPast: isPast)
            }
        }
    }

    /// The module's number, big, and its times: the day's rhythm down the side.
    private var label: some View {
        VStack(spacing: 1) {
            Text("\(slot.module.number)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? Palette.accent : (isPast ? Color(.secondaryLabel) : Color.primary))
            Text(slot.module.shortStart)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(slot.module.shortEnd)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(width: 38)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Module \(slot.module.number), \(slot.module.start) to \(slot.module.end)")
    }
}

/// A module with something on: each lesson as a coloured block, and the
/// rest folded underneath.
private struct SlotCard: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?
    let isCurrent: Bool
    let isPast: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array((slot.main + slot.continuing).enumerated()), id: \.element.id) { index, lesson in
                if index > 0 { Divider() }
                OpenButton(lesson: lesson, dayISO: dayISO) {
                    LessonBlock(lesson: lesson,
                                module: slot.module,
                                continued: slot.main.isEmpty,
                                now: isCurrent ? now : nil,
                                faded: isPast)
                }
            }
            let rest = slot.others + slot.cancelled
            if !rest.isEmpty {
                Divider()
                OthersLine(items: rest, dayISO: dayISO)
            }
        }
        .contentCard(radius: Metrics.inner + 4)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
    }
}

/// One lesson, in its subject's colour.
private struct LessonBlock: View {
    let lesson: Lesson
    let module: ScheduleModule
    let continued: Bool
    let now: Date?
    let faded: Bool

    @Environment(\.colorScheme) private var scheme

    private var colour: Color {
        lesson.isClassLesson ? Color.forSubject(lesson.code) : Color(.systemGray)
    }
    private var stripe: Color {
        lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray)
    }

    /// Only when it isn't simply the module: "13:45–15:15".
    private var ownTimes: String? {
        guard lesson.start != module.start || lesson.end != module.end,
              !lesson.start.isEmpty else { return nil }
        return lesson.start + "–" + lesson.end
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(stripe.opacity(faded ? 0.45 : 1))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(lesson.headline)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !lesson.room.isEmpty {
                        Text(LessonText.abbreviated(lesson.room))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                if continued {
                    Text("Continues · until " + lesson.end)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else if let topic = lesson.topic {
                    Text(LectioDates.tidy(topic))
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                marks

                if let now { progress(now) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(backgroundStrength))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    /// Enough colour to tell subjects apart at a glance, not so much that
    /// the text stops reading as text.
    private var backgroundStrength: Double {
        let base = scheme == .dark ? 0.24 : 0.13
        return faded ? base * 0.55 : base
    }

    private var marks: some View {
        HStack(spacing: 9) {
            let who = LessonText.abbreviated(lesson.teacher)
            if !who.isEmpty { Text(who).lineLimit(1) }
            if let ownTimes { Text(ownTimes).monospacedDigit().lineLimit(1) }
            if !lesson.homework.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(stripe)
                    Text("Homework")
                }
            }
            if !lesson.note.isEmpty {
                Image(systemName: "text.bubble")
                    .accessibilityLabel("Note")
            }
            // Only on your own lessons: on an exam day everything is
            // "changed", and the word stopped meaning anything.
            if lesson.changed && lesson.isClassLesson {
                HStack(spacing: 3) {
                    Circle().fill(Palette.warning).frame(width: 6, height: 6)
                    Text("Changed").foregroundStyle(Palette.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func progress(_ now: Date) -> some View {
        let start = lesson.startMinutes ?? module.startMinutes
        let end = max(lesson.endMinutes ?? module.endMinutes, start + 1)
        let current = DayList.minutes(of: now)
        let fraction = min(max(Double(current - start) / Double(end - start), 0), 1)
        let left = max(end - current, 0)

        return HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(stripe).frame(width: max(proxy.size.width * fraction, 4))
                }
            }
            .frame(height: 5)
            Text(DayList.duration(left) + " left")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.top, 5)
    }
}

/// Everything else in a module — optional things, clubs, events, and your
/// cancelled lessons — as one line; tap it for the list.
private struct OthersLine: View {
    let items: [Lesson]
    let dayISO: String
    @State private var open = false

    /// Each name once: Lectio can list the same event twice.
    private var summary: String {
        var seen: Set<String> = []
        let held = items.filter { !$0.cancelled }.map(\.headline)
        let cancelled = items.filter(\.cancelled).map { $0.headline + " cancelled" }
        return (held + cancelled)
            .filter { seen.insert($0.lowercased()).inserted }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(summary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Also in this module: " + summary)

            if open {
                ForEach(items) { item in
                    Divider().padding(.leading, 12)
                    OpenButton(lesson: item, dayISO: dayISO) {
                        SmallItem(lesson: item)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                }
            }
        }
    }
}

/// A free module: plainly free, with what was cancelled and anything else
/// on at the time.
private struct FreeCard: View {
    let slot: DayPlan.Slot
    let dayISO: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The cancelled lesson still opens: its note says why.
            if let cancelled = slot.cancelled.first {
                OpenButton(lesson: cancelled, dayISO: dayISO) { header }
            } else {
                header
            }

            let rest = slot.others + slot.cancelled.dropFirst()
            if !rest.isEmpty {
                Divider()
                OthersLine(items: Array(rest), dayISO: dayISO)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(Color(.tertiaryLabel))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Free")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            if let cancelled = slot.cancelled.first {
                Text("·").foregroundStyle(.tertiary)
                Text(cancelled.headline)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("cancelled")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.negative)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Around the modules

/// Things on this day outside any module — before school or after it.
private struct OutsideRow: View {
    let lesson: Lesson
    let dayISO: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 1) {
                Text(short(lesson.start))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(short(lesson.end))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 38)
            .padding(.top, 10)

            OpenButton(lesson: lesson, dayISO: dayISO) {
                SmallItem(lesson: lesson)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(radius: Metrics.inner + 2)
            }
        }
    }

    private func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
}

/// One line for something small: colour mark, name, time, room.
private struct SmallItem: View {
    let lesson: Lesson
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray2))
                .frame(width: 7, height: 7)
            Text(lesson.headline)
                .font(.system(size: 15, weight: .medium))
                .strikethrough(lesson.cancelled)
                .foregroundStyle(lesson.cancelled ? Color(.secondaryLabel) : Color.primary)
                .lineLimit(1)
            if lesson.cancelled {
                Text("Cancelled")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.negative)
            }
            Spacer(minLength: 4)
            if !lesson.start.isEmpty {
                Text(lesson.start + "–" + lesson.end)
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !lesson.room.isEmpty {
                Text(LessonText.abbreviated(lesson.room))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// All-day items as a row of chips: there, but not in the way.
private struct AllDayStrip: View {
    let items: [Lesson]
    let dayISO: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("All day")
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: 38)
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(items) { item in
                        OpenButton(lesson: item, dayISO: dayISO) {
                            HStack(spacing: 5) {
                                Text(item.headline)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                if let span = item.allDay, !span.isEmpty {
                                    Text(span)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Lines

/// Where you are between modules: in the accent colour, so it's the first
/// thing you find.
private struct NowLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Rectangle().fill(Palette.accent.opacity(0.5)).frame(height: 1)
        }
        .padding(.leading, 15)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct DoneLine: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13.5, weight: .semibold))
            Text("School's out")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - Opening

/// Opens a lesson (pushed) or, for your own private event, its editor.
/// A card shrinks under the finger; a row in a list (`asRow`) lights up.
struct OpenButton<Content: View>: View {
    let lesson: Lesson
    let dayISO: String
    var asRow = false
    @ViewBuilder var label: () -> Content

    @EnvironmentObject private var session: LectioSession
    @Environment(LessonOpener.self) private var opener: LessonOpener?
    @State private var editingEvent = false

    var body: some View {
        let button = Button {
            if lesson.isPrivateEvent {
                editingEvent = true
            } else {
                opener?.open(LessonRoute(lesson: lesson, dayISO: dayISO))
            }
        } label: {
            label()
        }
        Group {
            if asRow {
                button.buttonStyle(RowPress())
            } else {
                button.buttonStyle(PressableCard())
            }
        }
        .sheet(isPresented: $editingEvent) {
            NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                session.retryWeek(LectioDates.weekCode(iso: dayISO))
            }
            .environmentObject(session)
        }
    }
}
