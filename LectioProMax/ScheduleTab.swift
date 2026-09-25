import SwiftUI

struct ScheduleTab: View {
    @EnvironmentObject private var session: LectioSession

    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    @State private var dragX: CGFloat = 0
    @State private var slideFrom: Edge = .trailing
    @State private var weekMode = false
    @State private var addingEvent = false
    @State private var searching = false

    private let threshold: CGFloat = 62

    private var weekCode: String { LectioDates.weekCode(iso: selectedDate) }
    private var day: ScheduleDay? {
        session.snapshot.weeks[weekCode]?.days.first { $0.date == selectedDate }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                swipeArrows
                if weekMode {
                    WeekOverview(weekCode: weekCode, selected: $selectedDate) { date in
                        withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) {
                            selectedDate = date
                            weekMode = false
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    dayPager
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    // Ignore mostly-vertical drags so the list still scrolls.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = value.translation.width * 0.28
                }
                .onEnded { value in
                    let dx = value.translation.width
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { dragX = 0 }
                    guard abs(dx) > abs(value.translation.height) else { return }
                    if dx < -threshold { step(1) }
                    else if dx > threshold { step(-1) }
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onEnded { value in
                    if value.magnification < 0.88 {
                        withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) { weekMode = true }
                    } else if value.magnification > 1.12 {
                        withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) { weekMode = false }
                    }
                }
        )
        .task(id: weekCode) {
            // So a pull-to-refresh reloads the week you're looking at, not just
            // whichever one Lectio considers current.
            session.visibleWeekCode = weekCode
            // The neighbours are warmed only once THIS week has landed — three
            // simultaneous fetch-and-parse jobs were a large part of the lag.
            session.requestWeek(weekCode, alsoWarm: [
                LectioDates.weekCode(iso: LectioDates.shift(iso: selectedDate, byDays: 7)),
                LectioDates.weekCode(iso: LectioDates.shift(iso: selectedDate, byDays: -7))
            ])
        }
        .sensoryFeedback(.selection, trigger: selectedDate)
        .sheet(isPresented: $searching) {
            SearchSheet().environmentObject(session)
        }
        .sheet(isPresented: $addingEvent) {
            NewEventSheet(dayISO: selectedDate) {
                // Pull the week again so the new event turns up straight away.
                session.retryWeek(weekCode)
            }
            .environmentObject(session)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LectioDates.friendlyLabel(iso: selectedDate))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(LectioDates.longLabel(iso: selectedDate))
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
            }
            Spacer()
            // The one place glass belongs here: controls floating above content.
            // Both live in one container so they read as a single glass group,
            // which is what GlassEffectContainer is for.
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    GlassCircleButton(systemName: "magnifyingglass") { searching = true }
                    GlassCircleButton(systemName: "plus") { addingEvent = true }
                    GlassCircleButton(systemName: weekMode ? "rectangle.grid.1x2" : "calendar") {
                        withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) {
                            weekMode.toggle()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    // MARK: Day pager

    private var dayPager: some View {
        ZStack {
            ScrollView {
                RefreshHeader(space: "schedule") { await session.refresh() }
                VStack(alignment: .leading, spacing: 10) {
                    if session.snapshot.weeks[weekCode] == nil {
                        WeekPlaceholder(weekCode: weekCode)
                    } else {
                        DayList(day: day).equatable()
                    }
                    }
                .padding(.horizontal, Metrics.margin)
            }
            .coordinateSpace(.named("schedule"))
            .scrollIndicators(.hidden)
            .id(selectedDate)
            .transition(.asymmetric(
                insertion: .move(edge: slideFrom).combined(with: .opacity),
                removal: .opacity
            ))
            .offset(x: dragX)
        }
    }

    /// Chevrons that fade in as you pull, so the swipe reads as a deliberate step.
    private var swipeArrows: some View {
        let progress = min(abs(dragX) / (threshold * 0.28), 1)
        return HStack {
            arrow("chevron.left")
                .opacity(dragX > 4 ? progress : 0)
                .scaleEffect(0.85 + progress * 0.25)
            Spacer()
            arrow("chevron.right")
                .opacity(dragX < -4 ? progress : 0)
                .scaleEffect(0.85 + progress * 0.25)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: 38, height: 38)
            .contentCard(radius: 19)
    }

    private func step(_ delta: Int) {
        slideFrom = delta > 0 ? .trailing : .leading
        // Zoomed out to the week view, a swipe should move a week at a time.
        let days = weekMode ? delta * 7 : delta
        withAnimation(.spring(response: 0.40, dampingFraction: 0.84)) {
            selectedDate = LectioDates.shift(iso: selectedDate, byDays: days)
        }
    }
}

// MARK: - Week overview (pinch out / calendar button)

struct WeekOverview: View {
    @EnvironmentObject private var session: LectioSession
    let weekCode: String
    @Binding var selected: String
    var onPick: (String) -> Void

    private var week: ScheduleWeek? { session.snapshot.weeks[weekCode] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let week = week {
                    ForEach(week.days) { day in
                        dayRow(day)
                            .contentShape(Rectangle())
                            // Tap gesture rather than a Button, so a horizontal
                            // swipe across a row changes week instead of
                            // opening the day.
                            .onTapGesture { onPick(day.date) }
                    }
                } else {
                    WeekPlaceholder(weekCode: weekCode)
                }
            }
            .padding(.horizontal, Metrics.margin)
        }
        .scrollIndicators(.hidden)
    }

    private func dayRow(_ day: ScheduleDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(dayName(day).uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(isToday(day) ? Palette.accent : Color.primary.opacity(0.6))
                Text(dayNum(day))
                    .font(.system(size: 18.5, weight: .bold, design: .rounded))
                Spacer()
                Text("\(day.lessons.count)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.58))
            }
            if !day.lessons.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(day.lessons.prefix(4)) { lesson in
                        HStack(spacing: 7) {
                            SubjectDot(code: lesson.code, size: 6)
                            Text(lesson.start)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary.opacity(0.7))
                            Text(lesson.displayTitle)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .strikethrough(lesson.cancelled)
                            Spacer(minLength: 0)
                        }
                    }
                    if day.lessons.count > 4 {
                        Text("+\(day.lessons.count - 4) more")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.58))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 3)
    }

    private func parts(_ d: ScheduleDay) -> [String] { d.label.split(separator: " ").map(String.init) }
    private func dayName(_ d: ScheduleDay) -> String { parts(d).first ?? "" }
    private func dayNum(_ d: ScheduleDay) -> String { parts(d).count > 1 ? parts(d)[1] : "" }
    private func isToday(_ d: ScheduleDay) -> Bool { d.date == LectioDates.isoString(from: Date()) }
}

// MARK: - Lesson card

/// Which sheet a schedule card opens. One `item:` sheet rather than two
/// `isPresented:` ones, which fight each other on the same view.
enum CardSheet: Int, Identifiable {
    case lesson, event
    var id: Int { rawValue }
}

struct LessonCard: View {
    let lesson: Lesson
    let dayISO: String
    @EnvironmentObject private var session: LectioSession
    @State private var sheet: CardSheet?

    private var state: LessonState { lesson.state(onDay: dayISO) }
    private var tint: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.forSubject(lesson.code)
    }

    var body: some View {
        card
            .contentShape(Rectangle())
            // Deliberately a tap gesture, not a Button: a Button still counts
            // a horizontal swipe that stays inside the card as a press, which
            // made the day-swipe almost impossible to perform on a lesson.
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

    private var card: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(lesson.start)
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(lesson.end)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.58))
                    .monospacedDigit()
            }
            .frame(width: 58, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(lesson.cancelled ? Color.secondary.opacity(0.3) : tint)
                .frame(width: state == .current ? 3.5 : 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                    Text(lesson.displayTitle)
                        .font(.system(size: 18.5, weight: .semibold))
                        .strikethrough(lesson.cancelled)
                        .foregroundStyle(lesson.cancelled ? Color.primary.opacity(0.55) : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if state == .current {
                        Text("NOW")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }

                Text(metaLine)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))

                if !lesson.homework.isEmpty {
                    previewLine("book", lesson.homework)
                }
                if !lesson.note.isEmpty {
                    previewLine("text.bubble", lesson.note)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .opacity(state == .past ? 0.48 : 1)
    }

    private var metaLine: String {
        var bits: [String] = []
        if lesson.isPrivateEvent { bits.append("Private event") }
        // Skip the code when it's already standing in as the title.
        if !lesson.code.isEmpty && !lesson.title.isEmpty {
            bits.append(lesson.code.uppercased())
        }
        if !lesson.room.isEmpty { bits.append(lesson.room) }
        if !lesson.teacher.isEmpty { bits.append(lesson.teacher) }
        if lesson.cancelled { bits.append("Cancelled") }
        else if lesson.changed { bits.append("Changed") }
        return bits.joined(separator: " · ")
    }

    private func previewLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.58))
                .padding(.top, 1.5)
            Text(LectioDates.tidy(text))
                .font(.system(size: 14.5))
                .foregroundStyle(.primary.opacity(0.72))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Narrow card used when two lessons share a time slot.
struct CompactLessonCard: View {
    let lesson: Lesson
    let dayISO: String
    @EnvironmentObject private var session: LectioSession
    @State private var sheet: CardSheet?

    private var state: LessonState { lesson.state(onDay: dayISO) }
    private var tint: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.forSubject(lesson.code)
    }

    var body: some View {
        compactCard
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

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.5))
                    } else {
                        SubjectDot(code: lesson.code, size: 6)
                    }
                    Text(lesson.start)
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.72))
                    Spacer(minLength: 0)
                    if state == .current {
                        Text("NOW")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
                Text(lesson.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(lesson.cancelled)
                    .foregroundStyle(lesson.cancelled ? Color.primary.opacity(0.55) : Color.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 2)
            .opacity(state == .past ? 0.48 : 1)
    }

    private var meta: String {
        var bits: [String] = []
        if !lesson.room.isEmpty { bits.append(lesson.room) }
        if !lesson.teacher.isEmpty { bits.append(lesson.teacher) }
        return bits.joined(separator: " · ")
    }
}

/// Shown while a week is still being fetched — and, if the fetch failed, as a
/// retry instead of a spinner that would otherwise never stop.
struct WeekPlaceholder: View {
    @EnvironmentObject private var session: LectioSession
    let weekCode: String

    var body: some View {
        Group {
            if session.failedWeeks.contains(weekCode) {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.6))
                    Text("Couldn't load this week")
                        .font(.system(size: 16.5, weight: .semibold))
                    if let why = session.weekErrors[weekCode] {
                        Text(why)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    Button("Try again") { session.retryWeek(weekCode) }
                        .font(.system(size: 15.5, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
            }
        }
    }
}

/// The day's lessons as a list.
///
/// Equatable on purpose: a drag updates `dragX`, which re-evaluates the
/// schedule's body on every frame. Inline, that meant recomputing the overlap
/// clusters and rebuilding every card sixty times a second.
struct DayList: View, Equatable {
    let day: ScheduleDay?

    static func == (lhs: DayList, rhs: DayList) -> Bool { lhs.day == rhs.day }

    var body: some View {
        if let day = day, !day.lessons.isEmpty {
            ForEach(LessonCluster.build(day.lessons)) { cluster in
                if cluster.lessons.count == 1 {
                    LessonCard(lesson: cluster.lessons[0], dayISO: day.date)
                } else {
                    // Lessons sharing a slot sit side by side.
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(cluster.lessons) { lesson in
                            CompactLessonCard(lesson: lesson, dayISO: day.date)
                        }
                    }
                }
            }
        } else {
            EmptyNotice(icon: "sun.max", text: "Nothing scheduled")
        }
    }
}
