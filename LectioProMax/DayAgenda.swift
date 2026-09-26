import SwiftUI

// MARK: - What a lesson is called

extension Lesson {
    /// "Maths" for "1j ma" — only when the app knows the subject, so an
    /// event like "Musicafe" (held for a list of whole year groups) keeps
    /// its own title.
    var subjectName: String? {
        guard !isPrivateEvent,
              let key = SubjectPalette.subjectKey(code),
              let name = SubjectNames.knownName(forKey: key) else { return nil }
        return name
    }

    /// The big line: the subject, or the event's own title.
    var headline: String { subjectName ?? displayTitle }

    /// The small line under it: the lesson's topic ("Start radicals"), or
    /// for an event, who it's for.
    var topic: String? {
        if subjectName != nil {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if !title.isEmpty, !code.isEmpty { return LessonText.abbreviated(code) }
        return nil
    }

    var startMinutes: Int? { Lesson.minutes(from: start) }
    var endMinutes: Int? { Lesson.minutes(from: end) }
}

// MARK: - The day

/// The day as an agenda: lessons as short cards in time order, the breaks
/// between them spelled out, and — today — where you are right now: a bar
/// through the current lesson, or a line saying what's next and when.
///
/// Equatable so a page rebuilds only when its own day changes; the clock
/// inside ticks on its own.
struct DayList: View, Equatable {
    let day: ScheduleDay?

    static func == (lhs: DayList, rhs: DayList) -> Bool { lhs.day == rhs.day }

    var body: some View {
        if let day, !day.lessons.isEmpty {
            let clusters = LessonCluster.build(day.lessons)
            if day.date == LectioDates.isoString(from: Date()) {
                TimelineView(.everyMinute) { context in
                    agenda(day, clusters, now: context.date)
                }
            } else {
                agenda(day, clusters, now: nil)
            }
        } else {
            EmptyNotice(icon: "sun.max", text: "Nothing scheduled")
        }
    }

    @ViewBuilder
    private func agenda(_ day: ScheduleDay, _ clusters: [LessonCluster], now: Date?) -> some View {
        let nowMinutes = now.map { minutes(of: $0) }
        let next = nowMinutes.flatMap { nextLesson(after: $0, in: clusters) }
        let schoolEnd = Self.schoolEnd(of: day.lessons)
        // The last card of the school day, where "School's out" goes.
        let lastSchool = schoolEnd.flatMap { end in
            clusters.lastIndex { cluster in
                cluster.lessons.contains { $0.subjectName != nil && !$0.cancelled && $0.endMinutes == end }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            DaySummary(lessons: day.lessons)

            ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                // Before the first lesson: what's first, and how soon.
                if index == 0, let nowMinutes, let first = clusterStart(cluster), nowMinutes < first,
                   let next {
                    NowLine(text: upNext(next, from: nowMinutes))
                }

                if index > 0 {
                    gap(before: cluster, after: clusters[index - 1],
                        schoolEnd: schoolEnd, nowMinutes: nowMinutes, next: next)
                }

                ClusterView(cluster: cluster, dayISO: day.date, now: now)

                if index == lastSchool, let nowMinutes, let schoolEnd, nowMinutes >= schoolEnd {
                    DoneLine()
                }
            }
        }
    }

    /// When the school day ends: the last lesson in an actual subject.
    /// Clubs and events in the evening come after it, and the time before
    /// them isn't a break.
    static func schoolEnd(of lessons: [Lesson]) -> Int? {
        lessons.filter { $0.subjectName != nil && !$0.cancelled }
            .compactMap(\.endMinutes)
            .max()
    }

    // MARK: Gaps

    /// Breaks only inside the school day: nothing after the last lesson.
    @ViewBuilder
    private func gap(before cluster: LessonCluster, after previous: LessonCluster,
                     schoolEnd: Int?, nowMinutes: Int?, next: Lesson?) -> some View {
        if let end = clusterEnd(previous), let start = clusterStart(cluster), start - end >= 5,
           let schoolEnd, end < schoolEnd {
            if let nowMinutes, nowMinutes >= end, nowMinutes < start, let next {
                // You're in this break: say what's next instead of its length.
                NowLine(text: upNext(next, from: nowMinutes))
            } else {
                GapLine(minutes: start - end)
            }
        }
    }

    private func upNext(_ lesson: Lesson, from nowMinutes: Int) -> String {
        guard let start = lesson.startMinutes else { return "Next: " + lesson.headline }
        let wait = start - nowMinutes
        let room = lesson.room.isEmpty ? "" : " · " + LessonText.abbreviated(lesson.room)
        return "Next: " + lesson.headline + " in " + Self.duration(wait) + room
    }

    private func nextLesson(after nowMinutes: Int, in clusters: [LessonCluster]) -> Lesson? {
        clusters.flatMap(\.lessons)
            .filter { !$0.cancelled && ($0.startMinutes ?? -1) > nowMinutes }
            .min { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }
    }

    private func clusterStart(_ cluster: LessonCluster) -> Int? {
        cluster.lessons.compactMap(\.startMinutes).min()
    }

    private func clusterEnd(_ cluster: LessonCluster) -> Int? {
        cluster.lessons.compactMap(\.endMinutes).max()
    }

    private func minutes(of date: Date) -> Int {
        let c = Lesson.sharedCalendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Lines between the cards

/// "5 lessons · 08:00–15:15 · 1 cancelled" — how long the day is, at a glance.
private struct DaySummary: View {
    let lessons: [Lesson]

    var body: some View {
        let held = lessons.filter { !$0.cancelled }
        // The school day's span comes from real lessons; an evening event
        // doesn't make the day end at 20:00.
        let school = held.filter { $0.subjectName != nil }
        let spanFrom = school.isEmpty ? held : school
        let starts = spanFrom.filter { $0.startMinutes != nil }.map(\.start).sorted()
        let ends = spanFrom.filter { $0.endMinutes != nil }.map(\.end).sorted()
        let cancelled = lessons.count - held.count
        let events = held.count - school.count

        var bits: [String] = []
        if !school.isEmpty {
            bits.append(school.count == 1 ? "1 lesson" : "\(school.count) lessons")
        }
        if let first = starts.first, let last = ends.last { bits.append(first + "–" + last) }
        if cancelled > 0 { bits.append("\(cancelled) cancelled") }
        if events > 0 { bits.append(events == 1 ? "1 event" : "\(events) events") }

        return Text(bits.joined(separator: " · "))
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, 4)
            .padding(.bottom, 2)
    }
}

/// A break or free period: its length, quietly.
private struct GapLine: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(minutes >= 60 ? "Free · " + DayList.duration(minutes)
                               : DayList.duration(minutes) + " break")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
            line
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }
}

/// Where you are right now, between lessons: in the accent colour, so it's
/// the first thing you find.
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
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
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
        .padding(.vertical, 8)
    }
}

// MARK: - Cards

/// One lesson, or lessons that share a slot — those stack inside one card
/// at full width rather than squeezing into halves.
private struct ClusterView: View {
    let cluster: LessonCluster
    let dayISO: String
    let now: Date?

    var body: some View {
        if cluster.lessons.count == 1, let lesson = cluster.lessons.first {
            LessonButton(lesson: lesson, dayISO: dayISO, style: .card) {
                LessonRow(lesson: lesson, dayISO: dayISO, now: now)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(cluster.lessons.enumerated()), id: \.element.id) { index, lesson in
                    if index > 0 { Divider().padding(.leading, 76) }
                    LessonButton(lesson: lesson, dayISO: dayISO, style: .row) {
                        LessonRow(lesson: lesson, dayISO: dayISO, now: now, inGroup: true)
                    }
                }
            }
            .contentCard(radius: Metrics.inner + 4)
        }
    }
}

/// Opens a lesson (pushed) or, for your own private event, its editor.
private struct LessonButton<Content: View>: View {
    enum Style { case card, row }

    let lesson: Lesson
    let dayISO: String
    let style: Style
    @ViewBuilder var label: () -> Content

    @EnvironmentObject private var session: LectioSession
    @Environment(LessonOpener.self) private var opener: LessonOpener?
    @State private var editingEvent = false

    var body: some View {
        Button {
            if lesson.isPrivateEvent {
                editingEvent = true
            } else {
                opener?.open(LessonRoute(lesson: lesson, dayISO: dayISO))
            }
        } label: {
            if style == .card {
                label()
                    .contentCard(radius: Metrics.inner + 4)
                    .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
            } else {
                label().contentShape(Rectangle())
            }
        }
        .buttonStyle(PressableCard())
        .sheet(isPresented: $editingEvent) {
            NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                session.retryWeek(LectioDates.weekCode(iso: dayISO))
            }
            .environmentObject(session)
        }
    }
}

/// A lesson's face in the day: time, subject colour, what it is and where.
private struct LessonRow: View {
    let lesson: Lesson
    let dayISO: String
    let now: Date?
    var inGroup = false

    @Environment(\.colorScheme) private var scheme

    private var state: LessonState { lesson.state(onDay: dayISO, now: now ?? Date()) }
    private var stripe: Color {
        lesson.isPrivateEvent ? Color(.systemGray) : Color.subjectStripe(lesson.code, in: scheme)
    }

    var body: some View {
        if lesson.cancelled { cancelledRow } else { fullRow }
    }

    // MARK: Held

    private var fullRow: some View {
        HStack(alignment: .top, spacing: 12) {
            times
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(stripe.opacity(state == .past ? 0.35 : 1))
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
                    if !lesson.room.isEmpty { roomBadge }
                }

                if let topic = lesson.topic {
                    Text(LectioDates.tidy(topic))
                        .font(.system(size: 14.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                infoLine

                if state == .current, let now { progress(now) }
            }
        }
        .padding(inGroup ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
                         : EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The lesson on now carries a faint wash of its colour.
            if state == .current {
                RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                    .fill(stripe.opacity(0.09))
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var times: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(lesson.start)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(state == .past ? Color(.secondaryLabel) : Color.primary)
            Text(lesson.end)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: 46, alignment: .trailing)
    }

    /// Where to go is the thing you look for most, so it gets a badge.
    private var roomBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "mappin")
                .font(.system(size: 10, weight: .bold))
            Text(LessonText.abbreviated(lesson.room))
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .fixedSize()
    }

    /// Code and teacher, and whether there's homework or a note — as marks,
    /// not paragraphs; the lesson's page has the words.
    private var infoLine: some View {
        HStack(spacing: 10) {
            let bits = [lesson.subjectName != nil ? LessonText.abbreviated(lesson.code).uppercased() : "",
                        LessonText.abbreviated(lesson.teacher)]
                .filter { !$0.isEmpty }
            if !bits.isEmpty {
                Text(bits.joined(separator: " · "))
                    .lineLimit(1)
            }
            if !lesson.homework.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(stripe)
                    Text("Homework")
                }
            }
            if !lesson.note.isEmpty {
                Image(systemName: "text.bubble")
                    .accessibilityLabel("Note")
            }
            if lesson.changed {
                Text("Changed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func progress(_ now: Date) -> some View {
        let start = lesson.startMinutes ?? 0
        let end = max(lesson.endMinutes ?? start + 1, start + 1)
        let c = Lesson.sharedCalendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let fraction = min(max(Double(nowMinutes - start) / Double(end - start), 0), 1)
        let left = max(end - nowMinutes, 0)

        return HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(stripe).frame(width: max(proxy.size.width * fraction, 4))
                }
            }
            .frame(height: 5)
            Text("\(DayList.duration(left)) left")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.top, 5)
    }

    // MARK: Cancelled

    /// A cancelled lesson is something to know, not something to read: one
    /// slim line.
    private var cancelledRow: some View {
        HStack(spacing: 12) {
            Text(lesson.start)
                .font(.system(size: 14.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(.tertiaryLabel))
                .frame(width: 4, height: 18)
            Text(lesson.headline)
                .font(.system(size: 15.5, weight: .medium))
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !lesson.note.isEmpty {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text("Cancelled")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var accessibilityText: String {
        var bits = [lesson.headline, lesson.start + " to " + lesson.end]
        if let topic = lesson.topic { bits.append(topic) }
        if !lesson.room.isEmpty { bits.append("room " + lesson.room) }
        if !lesson.homework.isEmpty { bits.append("has homework") }
        if lesson.changed { bits.append("changed") }
        return bits.joined(separator: ", ")
    }
}
