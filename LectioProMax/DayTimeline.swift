import SwiftUI

/// The day as a real timetable: hour markers down the side, blocks sized by how
/// long each lesson actually runs, gaps you can see, and a line for right now.
///
/// Equatable on purpose — a drag re-evaluates the parent's body every frame, and
/// laying out a day is not something to redo sixty times a second.
struct DayTimeline: View, Equatable {
    let day: ScheduleDay?
    let dayISO: String

    static func == (lhs: DayTimeline, rhs: DayTimeline) -> Bool {
        lhs.day == rhs.day && lhs.dayISO == rhs.dayISO
    }

    /// Points per minute. A 95-minute module comes out around 105pt, which is
    /// enough for a title, a room and a teacher without crowding.
    private let scale: CGFloat = 1.1
    private let gutter: CGFloat = 52
    private let columnGap: CGFloat = 6

    private var timed: [PlacedLesson] { PlacedLesson.place(day?.lessons ?? []) }
    private var untimed: [Lesson] {
        (day?.lessons ?? []).filter { Lesson.minutes(from: $0.start) == nil }
    }

    private var isToday: Bool { dayISO == LectioDates.isoString(from: Date()) }

    /// The window the day actually occupies, rounded out to whole hours and
    /// never smaller than a normal school day.
    private var bounds: (start: Int, end: Int) {
        let starts = timed.map { $0.start }
        let ends = timed.map { $0.end }
        let low = min(starts.min() ?? 480, 480)
        let high = max(ends.max() ?? 960, 960)
        return ((low / 60) * 60, Int(ceil(Double(high) / 60.0)) * 60)
    }

    private var height: CGFloat {
        CGFloat(bounds.end - bounds.start) * scale
    }

    var body: some View {
        if day == nil || (timed.isEmpty && untimed.isEmpty) {
            EmptyNotice(icon: "sun.max", text: "Nothing scheduled")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(untimed) { lesson in
                    AllDayChip(lesson: lesson, dayISO: dayISO)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        hourLines
                        blocks(in: geometry.size.width)
                        if isToday { nowLine }
                    }
                }
                .frame(height: height)
            }
        }
    }

    // MARK: Background

    private var hourLines: some View {
        ForEach(Array(stride(from: bounds.start, through: bounds.end, by: 60)), id: \.self) { minute in
            HStack(alignment: .top, spacing: 8) {
                Text(label(minute))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.42))
                    .frame(width: gutter - 8, alignment: .trailing)
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 1)
            }
            .offset(y: offset(for: minute) - 6)
        }
    }

    private var nowLine: some View {
        // Its own TimelineView so the minute tick redraws the line, not the day.
        TimelineView(.everyMinute) { context in
            let minutes = nowMinutes(context.date)
            if minutes >= bounds.start && minutes <= bounds.end {
                HStack(spacing: 0) {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 7, height: 7)
                        .offset(x: gutter - 11)
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(height: 1.6)
                }
                .offset(y: CGFloat(minutes - bounds.start) * scale)
            }
        }
    }

    // MARK: Lessons

    private func blocks(in width: CGFloat) -> some View {
        let available = max(width - gutter, 60)
        return ForEach(timed) { placed in
            let columnWidth = (available - columnGap * CGFloat(placed.columns - 1)) / CGFloat(placed.columns)
            TimelineLessonBlock(lesson: placed.lesson,
                                dayISO: dayISO,
                                compact: placed.columns > 1 || placed.duration < 45)
                .frame(width: max(columnWidth, 40),
                       height: max(CGFloat(placed.duration) * scale - 4, 34),
                       alignment: .topLeading)
                .offset(x: gutter + (columnWidth + columnGap) * CGFloat(placed.column),
                        y: CGFloat(placed.start - bounds.start) * scale)
        }
    }

    // MARK: Helpers

    private func offset(for minute: Int) -> CGFloat {
        CGFloat(minute - bounds.start) * scale
    }

    private func label(_ minute: Int) -> String {
        String(format: "%02d:00", (minute / 60) % 24)
    }

    private func nowMinutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: - Placement

/// Where a lesson sits: when it runs, and which column it takes when lessons
/// overlap. Standard calendar layout — overlapping lessons form a cluster, and
/// each cluster is divided into as many columns as it needs.
struct PlacedLesson: Identifiable {
    let id: String
    let lesson: Lesson
    let start: Int
    let end: Int
    let column: Int
    let columns: Int

    var duration: Int { max(end - start, 20) }

    static func place(_ lessons: [Lesson]) -> [PlacedLesson] {
        struct Span {
            let lesson: Lesson
            let start: Int
            let end: Int
            var column = 0
        }

        var spans: [Span] = []
        for lesson in lessons {
            guard let start = Lesson.minutes(from: lesson.start) else { continue }
            let end = Lesson.minutes(from: lesson.end) ?? (start + 45)
            spans.append(Span(lesson: lesson, start: start, end: max(end, start + 20)))
        }
        spans.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var placed: [PlacedLesson] = []
        var index = 0
        while index < spans.count {
            // Grow a cluster while anything still overlaps it.
            var clusterEnd = spans[index].end
            var cluster: [Span] = [spans[index]]
            var next = index + 1
            while next < spans.count && spans[next].start < clusterEnd {
                clusterEnd = max(clusterEnd, spans[next].end)
                cluster.append(spans[next])
                next += 1
            }

            // First column whose previous lesson has already finished.
            var columnEnds: [Int] = []
            for position in cluster.indices {
                var chosen = columnEnds.firstIndex { $0 <= cluster[position].start }
                if chosen == nil {
                    columnEnds.append(cluster[position].end)
                    chosen = columnEnds.count - 1
                } else {
                    columnEnds[chosen!] = cluster[position].end
                }
                cluster[position].column = chosen!
            }

            for span in cluster {
                placed.append(PlacedLesson(id: span.lesson.id + "|" + String(span.start),
                                           lesson: span.lesson,
                                           start: span.start,
                                           end: span.end,
                                           column: span.column,
                                           columns: max(columnEnds.count, 1)))
            }
            index = next
        }
        return placed
    }
}

// MARK: - Blocks

/// A lesson as it appears on the timetable. Kept deliberately light — the full
/// detail is one tap away, and a block has to survive being 34pt tall.
struct TimelineLessonBlock: View {
    let lesson: Lesson
    let dayISO: String
    let compact: Bool

    @EnvironmentObject private var session: LectioSession
    @State private var sheet: CardSheet?

    private var state: LessonState { lesson.state(onDay: dayISO) }
    private var tint: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.forSubject(lesson.code)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(lesson.cancelled ? Color.secondary.opacity(0.35) : tint)
                .frame(width: state == .current ? 4 : 2.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                    Text(lesson.displayTitle)
                        .font(.system(size: compact ? 13.5 : 15.5, weight: .semibold))
                        .strikethrough(lesson.cancelled)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if state == .current {
                        Text("NOW")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(Palette.accent)
                    }
                }
                if !compact {
                    Text(lesson.timeRange)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.58))
                }
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.62))
                        .lineLimit(1)
                }
                if !compact && (!lesson.homework.isEmpty || !lesson.note.isEmpty) {
                    HStack(spacing: 4) {
                        Image(systemName: "book")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(lesson.homework.isEmpty ? "Note" : "Homework")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(radius: 11)
        .opacity(state == .past ? 0.46 : 1)
        .contentShape(Rectangle())
        .onTapGesture { sheet = lesson.isPrivateEvent ? .event : .lesson }
        .sheet(item: $sheet) { which in
            switch which {
            case .lesson:
                LessonDetailSheet(lesson: lesson, dayISO: dayISO)
            case .event:
                NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                    session.retryWeek(LectioDates.weekCode(iso: dayISO))
                }
                .environmentObject(session)
            }
        }
    }

    private var meta: String {
        var bits: [String] = []
        if !lesson.code.isEmpty && !lesson.title.isEmpty { bits.append(lesson.code.uppercased()) }
        if !lesson.room.isEmpty { bits.append(lesson.room) }
        if !lesson.teacher.isEmpty { bits.append(lesson.teacher) }
        if lesson.cancelled { bits.append("Cancelled") }
        else if lesson.changed { bits.append("Changed") }
        return bits.joined(separator: " · ")
    }
}

/// Something with no time of its own — Lectio's all-day entries.
struct AllDayChip: View {
    let lesson: Lesson
    let dayISO: String
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 8) {
            SubjectDot(code: lesson.code, size: 7)
            Text(lesson.displayTitle)
                .font(.system(size: 14.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            LessonDetailSheet(lesson: lesson, dayISO: dayISO)
        }
    }
}
