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
    #if DEBUG
    /// Parts of the day the scroll lab leaves out (see ScrollLab).
    var labLeavesOut: LabLeaveOut = []
    #endif

    static func == (lhs: DayList, rhs: DayList) -> Bool {
        #if DEBUG
        guard lhs.labLeavesOut == rhs.labLeavesOut else { return false }
        #endif
        return lhs.day == rhs.day && lhs.modules == rhs.modules && lhs.className == rhs.className
            && lhs.rolling == rhs.rolling
    }

    private func makePlan(_ day: ScheduleDay) -> DayPlan {
        var plan = DayPlan.build(day, modules: modules, className: className, rolling: rolling)
        #if DEBUG
        labLeavesOut.apply(to: &plan)
        #endif
        return plan
    }

    var body: some View {
        if let day, !day.lessons.isEmpty {
            let plan = makePlan(day)
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
            // What the day is, when it isn't an ordinary one — an exam, a
            // day off, a trip, a reading day — most important first, in
            // the same shape as a lesson.
            ForEach(plan.status) { item in
                StatusRow(lesson: item, dayISO: dayISO)
            }
            // The day's notes, awareness days last.
            let notes = plan.allDay + plan.observances
            if !notes.isEmpty {
                AllDayStrip(items: notes, dayISO: dayISO, showsLabel: plan.status.isEmpty)
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

    /// Its modules, and any time it runs on past them at the same rate:
    /// 8:00–16:00 is four modules and 45 minutes more.
    /// `scale`: TypeScale.factor — with bigger text a module is taller,
    /// never shorter than the default.
    static func height(of slot: DayPlan.Slot, scale: CGFloat = 1) -> CGFloat {
        let module = height * max(scale, 1)
        let count = CGFloat(max(1, slot.last.number - slot.module.number + 1))
        let length = CGFloat(max(slot.module.endMinutes - slot.module.startMinutes, 30))
        let extra = CGFloat(slot.overrunBefore + slot.overrunAfter) * module / length
        // Two lessons of yours in one module (History and KL at 9:50, say)
        // each need a lesson's room. Squeezed into one module's height,
        // each kept its own and the pair, twice too tall, spilled over the
        // modules above and below.
        let stacked = CGFloat(slot.main.count + slot.continuing.count)
        return max(count * module + (count - 1) * gap + extra, stacked * module)
    }
}

private struct ModuleRow: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var scale: CGFloat { TypeScale.factor(dynamicTypeSize) }

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
            .frame(height: ModuleGrid.height(of: slot, scale: scale))
        }
    }

    /// A single module: its number and times, the day's rhythm down the
    /// side. A block over several — one exam, one reading day, one double
    /// lesson — shows only when it starts, at its top, and when it ends,
    /// at its bottom: it's one thing, not four.
    ///
    /// Something over several days shows what this day has of it, as
    /// Calendar does: its first day only when it starts (it runs on past
    /// the day), its last only when it ends (it came from yesterday), a
    /// day in between or a day-long note "All day".
    @ViewBuilder
    private var label: some View {
        if slot.modules.count == 1 && slot.overrunBefore == 0 && slot.overrunAfter == 0 && slot.dayShape == nil {
            moduleLabel(slot.module)
        } else {
            let hours = slot.hours
            let shape = slot.dayShape
            VStack(spacing: 0) {
                if shape == "all" {
                    Text("All day")
                        .scaledFont(size: 13, weight: .bold, design: .rounded)
                        .foregroundStyle(isPast ? Color(.secondaryLabel) : Color.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                } else if shape != "ends" {
                    Text(hours.shortStart)
                        .scaledFont(size: 17, weight: .bold, design: .rounded)
                        .foregroundStyle(isCurrent ? Palette.accent : (isPast ? Color(.secondaryLabel) : Color.primary))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if shape == "ends" {
                    Text(hours.shortEnd)
                        .scaledFont(size: 17, weight: .bold, design: .rounded)
                        .foregroundStyle(isPast ? Color(.secondaryLabel) : Color.primary)
                        .lineLimit(1)
                } else if shape == nil {
                    Text(hours.shortEnd)
                        .scaledFont(size: 14, weight: .semibold, design: .rounded)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .frame(width: 38)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(height: ModuleGrid.height(of: slot, scale: scale))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sideDescription(hours, shape: shape))
        }
    }

    private func sideDescription(_ hours: ScheduleModule, shape: String?) -> String {
        switch shape {
        case "all": return "All day"
        case "starts": return "Starts at \(hours.start), goes on past today"
        case "ends": return "Ends at \(hours.end)"
        default: return "\(hours.start) to \(hours.end)"
        }
    }

    private func moduleLabel(_ module: ScheduleModule) -> some View {
        let current = nowMinutes.map { $0 >= module.startMinutes && $0 < module.endMinutes } ?? false
        let past = nowMinutes.map { $0 >= module.endMinutes } ?? (dayISO < LectioDates.isoString(from: Date()))
        return VStack(spacing: 1) {
            Text("\(module.number)")
                .scaledFont(size: 22, weight: .bold, design: .rounded)
                .foregroundStyle(current ? Palette.accent : (past ? Color(.secondaryLabel) : Color.primary))
            Text(module.shortStart)
                .scaledFont(size: 11.5, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(module.shortEnd)
                .scaledFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: 38)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Module \(module.number), \(module.start) to \(module.end)")
    }
}

/// A module with something of yours on: its block, in its colour, and —
/// inside it, underneath — anything else of yours at the same time (the
/// reading day under an exam). Optional things are in "Also on".
private struct SlotCard: View {
    let slot: DayPlan.Slot
    let dayISO: String
    let now: Date?
    let isCurrent: Bool
    let isPast: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lessons = slot.main + slot.continuing
        let tall = slot.through != nil
        VStack(spacing: 0) {
            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                if index > 0 { Divider() }
                OpenButton(lesson: lesson, dayISO: dayISO) {
                    LessonBlock(lesson: lesson,
                                module: slot.span,
                                continued: slot.main.isEmpty,
                                now: isCurrent ? now : nil,
                                faded: isPast,
                                tall: tall,
                                dayISO: dayISO,
                                roomBelow: slot.alongside.isEmpty ? 0
                                    : CGFloat(slot.alongside.count) * 44 * max(TypeScale.factor(dynamicTypeSize), 1))
                }
                .frame(maxHeight: .infinity)
            }
        }
        // Anything else of yours at the time sits at the foot of the block,
        // inside its colour — the block stays exactly its modules tall.
        .overlay(alignment: .bottom) {
            if !slot.alongside.isEmpty {
                VStack(spacing: 6) {
                    ForEach(slot.alongside) { item in
                        OpenButton(lesson: item, dayISO: dayISO) {
                            AlongsideLine(lesson: item, dayISO: dayISO)
                        }
                    }
                }
                .padding(.leading, 27)
                .padding([.trailing, .bottom], 10)
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

/// One thing in its block: a lesson in its subject's colour; an exam, a
/// day off, a trip or a reading day in its kind's colour with its kind as
/// a tag; anything else grey. A block over several modules has room for
/// the whole story — which day of how many, the note — and carries its
/// kind's symbol, faint, in the corner.
private struct LessonBlock: View {
    let lesson: Lesson
    let module: ScheduleModule
    let continued: Bool
    let now: Date?
    let faded: Bool
    var tall = false
    var dayISO = ""
    /// Kept clear at the foot for the things alongside it.
    var roomBelow: CGFloat = 0

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private var mark: Lesson.Kind? { lesson.markKind }
    private var isLesson: Bool { lesson.isClassLesson && mark == nil }

    private var colour: Color {
        if let mark { return mark.tint }
        return lesson.isClassLesson ? Color.forSubject(lesson.code) : Color(.systemGray)
    }
    private var stripe: Color {
        if let mark { return mark.tint }
        return lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray)
    }

    /// Only when it isn't simply the module: "13:45–15:15".
    private var ownTimes: String? {
        guard lesson.dayShape == nil,
              lesson.start != module.start || lesson.end != module.end,
              !lesson.start.isEmpty else { return nil }
        func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
        return short(lesson.start) + (lesson.end.isEmpty ? "" : "–" + short(lesson.end))
    }

    /// "Day 1 of 2 · until Wed 15:15".
    private var spanNote: String? { lesson.spanNote(on: dayISO) }

    /// The time column has the hours (or says "All day"); the block only
    /// gives them when they aren't the module's (a single module).
    private var when: String? {
        guard !tall, lesson.dayShape == nil, let ownTimes else { return nil }
        return ownTimes
    }

    /// For anything that isn't a lesson: when, who it's for (only when it
    /// isn't you), where, with whom — "All day", "8:00–11:35 · 062, 064 ·
    /// AM +4".
    private var details: String? {
        var parts: [String] = []
        if let when { parts.append(when) }
        if let audience = lesson.audienceNote { parts.append(audience) }
        if !lesson.room.isEmpty { parts.append(LessonText.abbreviated(lesson.room)) }
        let who = LessonText.abbreviated(lesson.teacher)
        if !who.isEmpty { parts.append(who) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    Text(isLesson ? lesson.headline : dayStatusTitle(lesson))
                        .scaledFont(size: 17, weight: .semibold)
                        .lineLimit(tall ? 2 : 1)
                    Spacer(minLength: 6)
                    if let mark {
                        KindTag(kind: mark)
                    } else if isLesson, !lesson.room.isEmpty {
                        Text(LessonText.abbreviated(lesson.room))
                            .scaledFont(size: 15, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                if isLesson {
                    if continued {
                        Text("Continues · until " + lesson.end)
                            .scaledFont(size: 14)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let topic = lesson.topic {
                        Text(LectioDates.tidy(topic))
                            .scaledFont(size: 14.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(tall ? 4 : 1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let details {
                    Text(details)
                        .scaledFont(size: 14.5)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if tall, let spanNote {
                    Text(spanNote)
                        .scaledFont(size: 14, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                marks

                // With room to spare, the note itself: what to bring, where
                // to meet.
                if tall, !lesson.note.isEmpty,
                   Lesson.squashed(lesson.note) != Lesson.squashed(lesson.title) {
                    Text(LectioDates.tidy(lesson.note))
                        .scaledFont(size: 13.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(roomBelow > 0 ? 2 : 4)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                        .padding(.trailing, mark == nil ? 0 : 40)
                }

                if let now { progress(now) }
            }
        }
        .padding(12)
        .padding(.bottom, roomBelow)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            if tall, roomBelow == 0, let mark {
                Image(systemName: mark.icon)
                    .scaledFont(size: 42, weight: .regular)
                    .foregroundStyle(mark.tint.opacity(scheme == .dark ? 0.3 : 0.2))
                    .padding(14)
                    .accessibilityHidden(true)
            }
        }
        .background(colour.opacity(backgroundStrength))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    /// Enough colour to tell subjects apart at a glance, not so much that
    /// the text stops reading as text.
    /// With Increase Contrast on, stronger — the blocks still tell apart
    /// when the system makes everything else crisper.
    private var backgroundStrength: Double {
        var base = scheme == .dark ? 0.24 : 0.13
        if contrast == .increased { base *= 1.8 }
        return faded ? base * 0.55 : base
    }

    @ViewBuilder
    private var marks: some View {
        let times = (!tall ? spanNote : nil) ?? (isLesson ? ownTimes : nil)
        let hasHomework = !lesson.homework.isEmpty
        let hasNoteIcon = !lesson.note.isEmpty && !tall
        let isChanged = lesson.changed && isLesson
        let teacher = isLesson ? LessonText.abbreviated(lesson.teacher) : ""
        if times != nil || hasHomework || hasNoteIcon || isChanged || !teacher.isEmpty {
            HStack(spacing: 9) {
                if !teacher.isEmpty { Text(teacher).lineLimit(1) }
                if let times { Text(times).monospacedDigit().lineLimit(1) }
                if hasHomework {
                    HStack(spacing: 3) {
                        Image(systemName: "book.closed.fill")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(stripe)
                        Text("Homework")
                    }
                }
                if hasNoteIcon {
                    Image(systemName: "text.bubble")
                        .accessibilityLabel("Note")
                }
                // Only on your own lessons: on an exam day everything is
                // "changed", and the word stopped meaning anything.
                if isChanged {
                    HStack(spacing: 3) {
                        Circle().fill(Palette.warning).frame(width: 6, height: 6)
                        Text("Changed").foregroundStyle(Palette.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            .scaledFont(size: 13.5, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.top, 4)
    }
}

/// Something of yours at the same time as a block, less important than it,
/// as a small inset row at the foot of the block: "📖 NV-læsedag · Day 2
/// of 2 · until 15:15".
private struct AlongsideLine: View {
    let lesson: Lesson
    let dayISO: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let kind = lesson.markKind
        HStack(spacing: 8) {
            Image(systemName: kind?.icon ?? "calendar")
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(kind?.tint ?? Color(.secondaryLabel))
            Text(dayStatusTitle(lesson))
                .scaledFont(size: 14.5, weight: .semibold)
                .lineLimit(1)
                .layoutPriority(1)
            Text(when)
                .scaledFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemBackground).opacity(scheme == .dark ? 0.35 : 0.6))
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    /// Short, to fit beside the name: "ends 15:15" on the last day of it,
    /// "from 12:00" on the first, "Day 3 of 5" in between.
    private var when: String {
        func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
        if let note = lesson.spanNote(on: dayISO) {
            let parts = note.components(separatedBy: " · ")
            if lesson.dayShape == "starts", !lesson.start.isEmpty { return "from " + short(lesson.start) }
            if parts.count == 2, Rx.test("^ends \\d", parts[1]) { return parts[1] }
            return parts.first ?? note
        }
        if lesson.dayShape == "all" || lesson.start.isEmpty { return "All day" }
        return short(lesson.start) + (lesson.end.isEmpty ? "" : "–" + short(lesson.end))
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
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(.secondary)
            if let cancelled = slot.cancelled.first {
                Text("·").foregroundStyle(.tertiary)
                Text(cancelled.headline)
                    .strikethrough(color: Palette.negative)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("cancelled")
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Palette.negative)
            }
            Spacer(minLength: 0)
        }
        .scaledFont(size: 15, weight: .medium)
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
        // Centred on the row: a small row is one line tall, and its two
        // times top-aligned with a gap sat about 6 pt low of the name.
        HStack(alignment: .center, spacing: 10) {
            SideTimes(start: lesson.start, end: lesson.end)
            OpenButton(lesson: lesson, dayISO: dayISO) {
                SmallItem(lesson: lesson, showsTime: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(radius: Metrics.inner + 2)
            }
        }
    }
}

/// The left column of anything that isn't a module: when it starts and
/// ends, or "All day" — so every row in the day lines up the same way.
private struct SideTimes: View {
    let start: String
    let end: String

    var body: some View {
        VStack(spacing: 1) {
            if start.isEmpty {
                Text("All\nday")
                    .scaledFont(size: 11.5, weight: .heavy)
                    .multilineTextAlignment(.center)
            } else {
                Text(short(start))
                    .scaledFont(size: 12.5, weight: .semibold)
                if !end.isEmpty {
                    Text(short(end))
                        .scaledFont(size: 11.5, weight: .medium)
                }
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(2)
        .minimumScaleFactor(0.5)
        .frame(width: 38)
    }

    private func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
}

/// One line for something small: colour mark, name, time, room.
private struct SmallItem: View {
    let lesson: Lesson
    /// Off where the row already shows the times on its left.
    var showsTime = true
    @Environment(\.colorScheme) private var scheme
    #if DEBUG
    /// The scroll lab can switch parts of the cancelled look off (see
    /// LabCancelledLook).
    @Environment(\.labCancelledLook) private var labLook
    private var struckThrough: Bool { lesson.cancelled && !labLook.contains(.noStrikethrough) }
    private var saysCancelled: Bool { !labLook.contains(.noLabel) }
    private var cancelledColor: Color {
        if labLook.contains(.greyLabel) { return .secondary }
        if labLook.contains(.systemRedLabel) { return .red }
        return Palette.negative
    }
    /// The label sized as it was before the fix, to bring the jerk back.
    private var labelFixed: Bool { labLook.contains(.labelFixed) }
    #else
    private var struckThrough: Bool { lesson.cancelled }
    private var saysCancelled: Bool { true }
    private var cancelledColor: Color { Palette.negative }
    #endif

    var body: some View {
        HStack(spacing: 10) {
            // The same mark as a lesson's, only shorter.
            Capsule()
                .fill(lesson.isClassLesson ? Color.subjectStripe(lesson.code, in: scheme) : Color(.systemGray3))
                .frame(width: 4, height: 18)
            // "Frivillig drama AFLYST": the word is Lectio's own "cancelled",
            // which the row already says.
            Text(lesson.headline.replacingOccurrences(of: "\\s*\\bAFLYST\\b", with: "",
                                                      options: [.regularExpression, .caseInsensitive]))
                .scaledFont(size: 15, weight: .medium)
                .strikethrough(struckThrough, color: Palette.negative)
                .foregroundStyle(lesson.cancelled ? Color(.secondaryLabel) : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            // A study hall after school says what it is: "Maths · Lektiecafé".
            if !lesson.cancelled, let topic = lesson.topic {
                Text(LectioDates.tidy(topic).components(separatedBy: "\n").first ?? "")
                    .scaledFont(size: 14)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if lesson.cancelled {
                if saysCancelled {
                    Text("Cancelled")
                        .scaledFont(size: 12.5, weight: .semibold)
                        .foregroundStyle(cancelledColor)
                        .lineLimit(1)
                        #if DEBUG
                        .fixedSize(horizontal: labelFixed, vertical: labelFixed)
                        #endif
                        // Never squeezed: it gets its room first, then the
                        // name. Not by `.fixedSize()`: in this row, that made
                        // a long day's scroll catch near the end and jump
                        // back without a bounce (SCROLL_BUG.md, the scroll lab).
                        // Last, so the stack sees it: under another modifier
                        // it was lost, and the label shrank to "C…".
                        .layoutPriority(2)
                }
            } else if lesson.isExam {
                // "1g: Matematikscreening" during your English lesson.
                ExamTag()
            }
            Spacer(minLength: 4)
            // Times and room never squeeze: the name gives way, with "…".
            if showsTime, !lesson.start.isEmpty {
                Text(short(lesson.start) + (lesson.end.isEmpty ? "" : "–" + short(lesson.end)))
                    .scaledFont(size: 12.5, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The room gives way before the name: "190 Fodbo…".
            if !lesson.room.isEmpty {
                Text(LessonText.abbreviated(lesson.room))
                    .scaledFont(size: 13, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            .scaledFont(size: 12.5, weight: .heavy)
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}

/// The day's notes, stacked the way Calendar stacks all-day events: each
/// on its own line, in full, nothing to scroll or wait for. With two or
/// more, only the first shows, with a "+1" / "+3" key beside it to open
/// the rest in place and fold them again — the lessons stay near the top.
private struct AllDayStrip: View {
    let items: [Lesson]
    let dayISO: String
    /// Off under rows that already say "All day".
    var showsLabel = true

    @State private var expanded = false

    private var shown: [Lesson] {
        items.count > 1 && !expanded ? Array(items.prefix(1)) : items
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("All\nday")
                .scaledFont(size: 11.5, weight: .heavy)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.5)
                // Centred on the first note (44 pt tall), however many are
                // open below it.
                .frame(width: 38, height: 44)
                .opacity(showsLabel ? 1 : 0)
                .accessibilityHidden(!showsLabel)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    // The "+1" sits beside the first note, the same height,
                    // so folding costs no extra line.
                    HStack(spacing: 6) {
                        note(item)
                        if index == 0 && items.count > 1 { toggle }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func note(_ item: Lesson) -> some View {
        OpenButton(lesson: item, dayISO: dayISO) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.headline)
                    .scaledFont(size: 14.5, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let span = item.allDay, !span.isEmpty {
                    Text(span)
                        .scaledFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill)))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
    }

    /// "+2" to open the rest, a chevron to fold them again: a small key
    /// the size of a touch.
    private var toggle: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            Group {
                if expanded {
                    Image(systemName: "chevron.up")
                        .scaledFont(size: 13, weight: .bold)
                } else {
                    Text("+\(items.count - 1)")
                        .scaledFont(size: 14.5, weight: .semibold)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Palette.accent)
            .frame(minWidth: 44, minHeight: 44, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCard())
        .accessibilityLabel(expanded ? "Show less" : "Show \(items.count - 1) more")
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

    /// Whether it carries its name as a tag: an exam, a day off, a trip, a
    /// reading day.
    var isTagged: Bool { self < .event }

    /// The colour of its block or row: the kind's own, grey for anything
    /// else.
    var blockTint: Color { isTagged ? tint : Color(.systemGray) }

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
            .scaledFont(size: 12, weight: .bold)
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

/// What the day is, when it isn't an ordinary one: an exam, a day off, a
/// trip, a reading day, another day-long thing of yours. The same shape as
/// a lesson — its times on the left, a stripe and tint in its colour — one
/// line tall, since there's nothing in the day to measure it against.
private struct StatusRow: View {
    let lesson: Lesson
    let dayISO: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let kind = lesson.kind
        let tint = kind.blockTint
        HStack(alignment: .top, spacing: 10) {
            SideTimes(start: lesson.start, end: lesson.end)
                .padding(.top, 12)
            OpenButton(lesson: lesson, dayISO: dayISO) {
                HStack(alignment: .top, spacing: 11) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(dayStatusTitle(lesson))
                                .scaledFont(size: 17, weight: .semibold)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            if kind.isTagged { KindTag(kind: kind) }
                        }
                        if let subtitle {
                            Text(subtitle)
                                .scaledFont(size: 13.5, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity((scheme == .dark ? 0.24 : 0.13) * (contrast == .increased ? 1.8 : 1)))
                .contentCard(radius: Metrics.inner + 4)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
        }
    }

    /// Which day of it and when it ends, who it's for (only when it isn't
    /// you), where, with whom: "Day 2 of 2 · ends 16:00 · KB +3".
    private var subtitle: String? {
        var parts: [String] = []
        if let note = lesson.spanNote(on: dayISO) { parts.append(note) }
        if let audience = lesson.audienceNote { parts.append(audience) }
        if !lesson.room.isEmpty { parts.append(LessonText.abbreviated(lesson.room)) }
        let who = LessonText.abbreviated(lesson.teacher)
        if !who.isEmpty { parts.append(who) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                // First pick of the room: otherwise the rule beside it takes
                // half the line and "in 27 min" became "in 27…".
                .layoutPriority(1)
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
                .scaledFont(size: 13.5, weight: .semibold)
            Text("School's out")
                .scaledFont(size: 14, weight: .semibold)
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

    @Environment(LectioSession.self) private var session
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
            .environment(session)
        }
    }
}
