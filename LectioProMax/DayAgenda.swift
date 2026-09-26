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
    /// See ScheduleWeek.rollingNotes.
    var rolling: Set<String> = []

    static func == (lhs: DayList, rhs: DayList) -> Bool {
        lhs.day == rhs.day && lhs.modules == rhs.modules && lhs.className == rhs.className
            && lhs.rolling == rhs.rolling
    }

    var body: some View {
        if let day, !day.lessons.isEmpty {
            let plan = DayPlan.build(day, modules: modules, className: className, rolling: rolling)
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
        VStack(alignment: .leading, spacing: ModuleGrid.gap) {
            // What kind of day it is, when it isn't an ordinary one: the
            // most important thing as a card, anything else as a line.
            if let first = plan.status.first {
                DayStatusCard(lesson: first, dayISO: dayISO)
                ForEach(plan.status.dropFirst()) { item in
                    DayStatusLine(lesson: item, dayISO: dayISO)
                }
            }
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
                ForEach(slot.breakAfter) { item in
                    OutsideRow(lesson: item, dayISO: dayISO)
                }
            }

            if let nowMinutes, let end = plan.schoolEnd, nowMinutes >= end {
                DoneLine()
            }

            if plan.slots.isEmpty && plan.status.isEmpty && plan.before.isEmpty {
                Text("No lessons")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            // Optional things in school hours: one list, with times.
            if !plan.also.isEmpty {
                SectionLabel(text: "ALSO ON")
                ForEach(plan.also) { item in
                    OutsideRow(lesson: item, dayISO: dayISO)
                }
            }

            if !plan.after.isEmpty {
                SectionLabel(text: "AFTER SCHOOL")
                ForEach(plan.after) { item in
                    OutsideRow(lesson: item, dayISO: dayISO)
                }
            }

            // Awareness days: worth knowing, not worth a chip.
            if !plan.observances.isEmpty {
                Text("Also today: " + plan.observances.map(\.headline).joined(separator: " · "))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
            }
        }
    }

    /// Today, before a module you're waiting for: what's next and when.
    private func nowLine(before index: Int) -> String? {
        guard let nowMinutes else { return nil }
        let slot = plan.slots[index]
        guard !slot.isFree, nowMinutes < slot.module.startMinutes else { return nil }
        // Only for the first module still to come.
        let earlierAhead = plan.slots[..<index].contains { !$0.isFree && nowMinutes < $0.endMinutes }
        guard !earlierAhead else { return nil }
        guard let lesson = (slot.main + slot.continuing).first else { return nil }
        let start = lesson.startMinutes ?? slot.module.startMinutes
        let room = lesson.room.isEmpty ? "" : " · " + LessonText.abbreviated(lesson.room)
        return "Next: " + lesson.headline + " in " + DayList.duration(start - nowMinutes) + room
    }
}

// MARK: - A module

/// Every module is the same height — a lesson, a free period, a cancelled
/// one — and a block over several is exactly as tall as those modules
/// together, so the day keeps its rhythm down the page and a four-module
/// exam fills the space of four lessons.
enum ModuleGrid {
    static let height: CGFloat = 100
    /// The space between rows in the day.
    static let gap: CGFloat = 10

    static func height(of slot: DayPlan.Slot) -> CGFloat {
        let count = CGFloat(max(1, slot.last.number - slot.module.number + 1))
        return count * height + (count - 1) * gap
    }
}

private struct ModuleRow: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?

    private var nowMinutes: Int? { now.map { DayList.minutes(of: $0) } }
    private var isCurrent: Bool {
        guard let nowMinutes else { return false }
        return nowMinutes >= slot.startMinutes && nowMinutes < slot.endMinutes
    }
    private var isPast: Bool {
        if let nowMinutes { return nowMinutes >= slot.endMinutes }
        return dayISO < LectioDates.isoString(from: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            label
            Group {
                if slot.isFree {
                    FreeCard(slot: slot, dayISO: dayISO)
                } else {
                    SlotCard(slot: slot, dayISO: dayISO, now: now, isCurrent: isCurrent, isPast: isPast)
                }
            }
            .frame(height: ModuleGrid.height(of: slot))
        }
    }

    private var numberColour: Color {
        isCurrent ? Palette.accent : (isPast ? Color(.secondaryLabel) : Color.primary)
    }

    @ViewBuilder
    private var label: some View {
        if slot.through == nil {
            // The module's number, big, and its times: the day's rhythm
            // down the side.
            VStack(spacing: 1) {
                Text("\(slot.module.number)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(numberColour)
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
        } else {
            // One thing over several modules — an exam, a reading day, a
            // double lesson: when it starts at its top and when it ends at
            // its bottom, the way a calendar draws an event. Module numbers
            // ("1–4") read like four things.
            let hours = slot.hours
            VStack(spacing: 0) {
                Text(hours.shortStart)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(numberColour)
                Spacer(minLength: 4)
                Text(hours.shortEnd)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.vertical, 10)
            .frame(width: 38, height: ModuleGrid.height(of: slot))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(hours.start) to \(hours.end)")
        }
    }
}

/// A module with something of yours on: each lesson as a block in its
/// colour. Anything else at the time is in the day's "Also on" list.
private struct SlotCard: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?
    let isCurrent: Bool
    let isPast: Bool

    var body: some View {
        let lessons = slot.main + slot.continuing
        VStack(spacing: 0) {
            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                if index > 0 { Divider() }
                OpenButton(lesson: lesson, dayISO: dayISO) {
                    LessonBlock(lesson: lesson,
                                module: slot.through == nil ? slot.span : slot.hours,
                                continued: slot.main.isEmpty,
                                now: isCurrent ? now : nil,
                                faded: isPast,
                                topicLines: slot.through == nil ? 1 : 4)
                }
                .frame(maxHeight: .infinity)
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

/// One lesson, in its subject's colour — or an exam's red, the same as the
/// exam banner — filling its module (or modules) top to bottom.
private struct LessonBlock: View {
    let lesson: Lesson
    let module: ScheduleModule
    let continued: Bool
    let now: Date?
    let faded: Bool
    /// One line in a single module; more when the block has the room.
    var topicLines: Int = 1

    @Environment(\.colorScheme) private var scheme

    private var colour: Color {
        if lesson.isExam { return Palette.negative }
        return lesson.isClassLesson ? Color.forSubject(lesson.code) : Color(.systemGray)
    }
    private var stripe: Color {
        if lesson.isExam { return Palette.negative }
        return lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray)
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
                        .lineLimit(1)
                } else if let topic = lesson.topic {
                    Text(LectioDates.tidy(topic))
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(topicLines)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                marks

                if let now { progress(now) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            if lesson.isExam { ExamTag() }
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
        .lineLimit(1)
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
        .padding(.top, 4)
    }
}

/// A free module: plainly free, with the lesson of yours that was
/// cancelled — the same height as a lesson.
private struct FreeCard: View {
    let slot: DayPlan.Slot
    let dayISO: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The cancelled lesson still opens: its note says why.
            if let cancelled = slot.cancelled.first {
                OpenButton(lesson: cancelled, dayISO: dayISO) { header }
            } else {
                header
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                SmallItem(lesson: lesson, showsTime: false)
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
    /// Off where the row already shows the times on its left.
    var showsTime = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray2))
                .frame(width: 7, height: 7)
            // "Frivillig drama AFLYST": the word is Lectio's own "cancelled",
            // which the row already says.
            Text(lesson.headline.replacingOccurrences(of: "\\s*\\bAFLYST\\b", with: "",
                                                      options: [.regularExpression, .caseInsensitive]))
                .font(.system(size: 15, weight: .medium))
                .strikethrough(lesson.cancelled)
                .foregroundStyle(lesson.cancelled ? Color(.secondaryLabel) : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            // A study hall after school says what it is: "Maths · Lektiecafé".
            if !lesson.cancelled, let topic = lesson.topic {
                Text(LectioDates.tidy(topic).components(separatedBy: "\n").first ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if lesson.cancelled {
                Text("Cancelled")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.negative)
            } else if lesson.isExam {
                // "1g: Matematikscreening" during your English lesson.
                ExamTag()
            }
            Spacer(minLength: 4)
            // Times and room never squeeze: the name gives way, with "…".
            if showsTime, !lesson.start.isEmpty {
                Text(short(lesson.start) + (lesson.end.isEmpty ? "" : "–" + short(lesson.end)))
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !lesson.room.isEmpty {
                Text(LessonText.abbreviated(lesson.room))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
    }

    private func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
}

/// A small heading over a list in the day: "ALSO ON", "AFTER SCHOOL".
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
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

// MARK: - What kind of day

extension Lesson.Kind {
    var icon: String {
        switch self {
        case .exam: return "pencil.and.list.clipboard"
        case .noSchool: return "sun.max.fill"
        case .trip: return "bus.fill"
        case .readingDay: return "book.fill"
        default: return "calendar"
        }
    }

    var label: String {
        switch self {
        case .exam: return "Exam"
        case .noSchool: return "No school"
        case .trip: return "Trip"
        case .readingDay: return "Reading day"
        default: return "Event"
        }
    }

    /// Red for an exam (the same as an exam block in the day), green for
    /// a day off, blue for a trip, indigo for a reading day.
    var tint: Color {
        switch self {
        case .exam: return Palette.negative
        case .noSchool: return Palette.positive
        case .trip: return Palette.accent
        case .readingDay: return .indigo
        default: return Color(.systemGray)
        }
    }
}

/// "Exam", "Reading day", …: small, in the kind's colour.
struct KindTag: View {
    let kind: Lesson.Kind

    var body: some View {
        Text(kind.label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(kind == .event ? Color(.secondaryLabel) : kind.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(kind.tint.opacity(0.14)))
            .lineLimit(1)
            .fixedSize()
    }
}

struct ExamTag: View {
    var body: some View { KindTag(kind: .exam) }
}

/// What the status card and line call a thing: a class lesson that's the
/// whole day ("KL") by what it is ("Pre-IB intro trip").
func dayStatusTitle(_ lesson: Lesson) -> String {
    if lesson.isClassLesson, let topic = lesson.topic {
        return LectioDates.tidy(topic).components(separatedBy: "\n").first ?? lesson.headline
    }
    return lesson.headline
}

func dayStatusTimes(_ lesson: Lesson) -> String {
    func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
    guard !lesson.start.isEmpty else { return "All day" }
    return short(lesson.start) + (lesson.end.isEmpty ? "" : "–" + short(lesson.end))
}

/// What kind of day it is: an exam, no school, a trip, a reading day, or
/// another day-long thing of yours — first on the page, in its colour.
private struct DayStatusCard: View {
    let lesson: Lesson
    let dayISO: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let kind = lesson.kind
        OpenButton(lesson: lesson, dayISO: dayISO) {
            HStack(spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayStatusTitle(lesson))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                KindTag(kind: kind)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                    .fill(kind.tint.opacity(scheme == .dark ? 0.24 : 0.13))
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
    }

    /// "8:00–16:00 · 062, 064 · MJ", or "All day · 1i, 1j".
    private var subtitle: String {
        var parts = [dayStatusTimes(lesson)]
        let t = lesson.title.trimmingCharacters(in: .whitespaces)
        if let colon = t.firstIndex(of: ":"), Lesson.audience(String(t[..<colon])) != nil {
            parts.append(t[..<colon].trimmingCharacters(in: .whitespaces))
        }
        if !lesson.room.isEmpty { parts.append(LessonText.abbreviated(lesson.room)) }
        let who = LessonText.abbreviated(lesson.teacher)
        if !who.isEmpty { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}

/// The day's other status under the card: "NV-læsedag 8:00–15:15" under
/// the NV exam.
private struct DayStatusLine: View {
    let lesson: Lesson
    let dayISO: String

    var body: some View {
        let kind = lesson.kind
        OpenButton(lesson: lesson, dayISO: dayISO) {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 22)
                Text(dayStatusTitle(lesson))
                    .font(.system(size: 15.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(dayStatusTimes(lesson))
                    .font(.system(size: 13.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 2)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
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
