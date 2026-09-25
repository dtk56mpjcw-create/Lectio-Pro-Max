import SwiftUI

// MARK: - Routing

/// A lesson on a particular day — what the Schedule and Search stacks push.
///
/// The day is part of it because the same lesson recurs every week and the
/// neighbouring day pages are alive side by side: the zoom transition needs an
/// id that's unique on screen.
struct LessonRoute: Hashable {
    let lesson: Lesson
    let dayISO: String
    var zoomID: String { dayISO + "|" + lesson.id }
}

extension EnvironmentValues {
    /// Where lesson cards register as zoom sources, when the stack around them
    /// can zoom into a lesson. Nil anywhere else, and the cards don't bother.
    @Entry var lessonZoom: Namespace.ID? = nil
}

struct LessonZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    func lessonZoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        modifier(LessonZoomSource(id: id, namespace: namespace))
    }
}

/// Lectio lists every class, teacher and room on a school-wide event, which
/// ran to several lines on a card. The first one and a count reads fine.
enum LessonText {
    static func abbreviated(_ raw: String) -> String {
        let items = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if items.count > 2 { return items[0] + " +\(items.count - 1)" }
        let words = raw.split(separator: " ")
        if items.count <= 1 && words.count > 3 { return String(words[0]) + " +\(words.count - 1)" }
        return raw
    }
}

// MARK: - Schedule

/// Pushes lessons onto the schedule's stack. The cards open lessons with a tap
/// gesture rather than a NavigationLink (a link counts a sideways swipe that
/// stays on the card as a tap), so they need a way to push.
@Observable
final class LessonOpener {
    var path: [LessonRoute] = []
    func open(_ route: LessonRoute) { path.append(route) }
}

/// The day, with the week a pinch or a tap away.
///
/// One vertical scroll view in a navigation stack, so the title bar, pull to
/// refresh, the scroll edge and the tab bar all behave as in any system app.
///
/// Sideways, three pages sit side by side — yesterday, today, tomorrow (or
/// three weeks) — and follow the finger one to one. On release they spring on
/// to the neighbour and quietly re-centre. A horizontal ScrollView pager was
/// tried here first: nested inside the vertical one it kept the height of
/// whatever it first measured and cut the day off.
struct ScheduleTab: View {
    @EnvironmentObject private var session: LectioSession
    @Namespace private var zoom

    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    @State private var weekMode = false
    @State private var addingEvent = false
    @State private var opener = LessonOpener()

    // Swipe state.
    @State private var dragX: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var settling = false
    @State private var pageWidth: CGFloat = 0

    /// Bumped to send the page back to its top.
    @State private var topRequest = 0
    private static let top = "schedule-top"

    private var today: String { LectioDates.isoString(from: Date()) }
    private var weekCode: String { LectioDates.weekCode(iso: selectedDate) }

    var body: some View {
        NavigationStack(path: $opener.path) {
            ScrollViewReader { proxy in
                scrollingContent(proxy)
            }
        }
        .environment(opener)
        .task(id: weekCode) {
            // So a pull-to-refresh reloads the week you're looking at, not just
            // whichever one Lectio considers current.
            session.visibleWeekCode = weekCode
            // The neighbours are warmed only once THIS week has landed.
            session.requestWeek(weekCode, alsoWarm: [
                LectioDates.weekCode(iso: LectioDates.shift(iso: selectedDate, byDays: 7)),
                LectioDates.weekCode(iso: LectioDates.shift(iso: selectedDate, byDays: -7))
            ])
        }
        .sensoryFeedback(.selection, trigger: selectedDate)
        .sensoryFeedback(.selection, trigger: weekMode)
        .sheet(isPresented: $addingEvent) {
            NewEventSheet(dayISO: selectedDate) {
                // Pull the week again so the new event turns up straight away.
                session.retryWeek(weekCode)
            }
            .environmentObject(session)
        }
    }

    /// The scrolling page under the title bar.
    private func scrollingContent(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 0).id(Self.top)
                Group {
                    if weekMode {
                        pager(unit: 7)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        pager(unit: 1)
                            .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            pageWidth = width
        }
        .onChange(of: topRequest) { _, _ in
            withAnimation(.smooth) { proxy.scrollTo(Self.top, anchor: .top) }
        }
        // The system control, now that this is one plain scroll view in a
        // navigation stack. The work runs in a task of its own so a redraw
        // halfway through can't cancel it.
        .refreshable {
            await Task { await session.refresh() }.value
        }
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        .simultaneousGesture(
            MagnifyGesture()
                .onEnded { value in
                    if value.magnification < 0.88 && !weekMode {
                        setWeekMode(true)
                    } else if value.magnification > 1.12 && weekMode {
                        setWeekMode(false)
                    }
                }
        )
        .environment(\.lessonZoom, zoom)
        .background { AppBackground() }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // Large, not inline-large: iOS only shows the subtitle under a title
        // drawn below the bar.
        .toolbarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .navigationDestination(for: LessonRoute.self) { route in
            LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
                .navigationTransition(.zoom(sourceID: route.zoomID, in: zoom))
        }
    }

    // MARK: Title bar

    /// "Today", "Tomorrow" and "Yesterday" as they are; any other day by its
    /// weekday, with the date underneath. "Week 39" zoomed out.
    private var title: String {
        if weekMode { return LectioDates.weekLabel(code: weekCode) }
        let friendly = LectioDates.friendlyLabel(iso: selectedDate)
        if friendly != LectioDates.dayLabel(iso: selectedDate) { return friendly }
        return Self.firstWord(LectioDates.longLabel(iso: selectedDate))
    }

    private var subtitle: String {
        if weekMode {
            let monday = Self.monday(of: selectedDate)
            let sunday = LectioDates.shift(iso: monday, byDays: 6)
            return Self.dropFirstWord(LectioDates.dayLabel(iso: monday))
                + " – " + Self.dropFirstWord(LectioDates.dayLabel(iso: sunday))
        }
        let long = LectioDates.longLabel(iso: selectedDate)
        return title == Self.firstWord(long) ? Self.dropFirstWord(long) : long
    }

    /// Today on its own, then the view switch and New Event as one group —
    /// the way Calendar spaces its bar.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selectedDate != today {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { jumpToToday() }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                setWeekMode(!weekMode)
            } label: {
                Label(weekMode ? "Day" : "Week",
                      systemImage: weekMode ? "rectangle.grid.1x2" : "calendar")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addingEvent = true
            } label: {
                Label("New event", systemImage: "plus")
            }
        }
    }

    // MARK: Pager

    /// Before, current and after, a page-width apart. Keyed by date, so when a
    /// swipe lands and the three shift along, the page you're looking at keeps
    /// its identity — and its place on screen — through the swap.
    private func pager(unit: Int) -> some View {
        let anchor = unit == 7 ? Self.monday(of: selectedDate) : selectedDate
        // Until the width is known (the very first layout) just the one page,
        // at whatever width it's given.
        let measured = pageWidth > 0
        let dates = measured
            ? [-1, 0, 1].map { LectioDates.shift(iso: anchor, byDays: $0 * unit) }
            : [anchor]
        let width: CGFloat? = measured ? pageWidth : nil
        return HStack(alignment: .top, spacing: 0) {
            ForEach(dates, id: \.self) { date in
                Group {
                    if unit == 7 {
                        WeekOverview(weekCode: LectioDates.weekCode(iso: date)) { day in
                            pick(day)
                        }
                    } else {
                        DayPage(date: date)
                    }
                }
                .frame(width: width, alignment: .top)
                // The neighbours wait off screen; VoiceOver shouldn't read them.
                .accessibilityHidden(date != anchor)
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: -(width ?? 0) + dragX)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !settling else { return }
                // Decide once per drag whether it's sideways; a mostly
                // vertical drag belongs to the scroll view.
                if dragAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    dragAxis = dx > dy ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let wasHorizontal = dragAxis == .horizontal
                dragAxis = nil
                guard wasHorizontal, !settling else { return }
                let width = max(pageWidth, 1)
                let moved = value.translation.width
                let flung = value.predictedEndTranslation.width
                if moved < -width * 0.3 || flung < -width * 0.6 {
                    land(on: 1)
                } else if moved > width * 0.3 || flung > width * 0.6 {
                    land(on: -1)
                } else {
                    withAnimation(.snappy) { dragX = 0 }
                }
            }
    }

    /// Carries the swipe through to the neighbour, then re-centres the three
    /// pages on it without animating — invisible, since the page stays put.
    private func land(on direction: Int) {
        let width = max(pageWidth, 1)
        let unit = weekMode ? 7 : 1
        settling = true
        withAnimation(.snappy(duration: 0.3)) {
            dragX = direction > 0 ? -width : width
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                selectedDate = LectioDates.shift(iso: selectedDate, byDays: direction * unit)
                dragX = 0
            }
            settling = false
            topRequest += 1
        }
    }

    // MARK: Moving around

    private func setWeekMode(_ on: Bool) {
        withAnimation(.smooth(duration: 0.4)) { weekMode = on }
        topRequest += 1
    }

    /// A day tapped in the week view: zoom back in on it.
    private func pick(_ date: String) {
        selectedDate = date
        setWeekMode(false)
    }

    private func jumpToToday() {
        withAnimation(.smooth) { selectedDate = today }
        topRequest += 1
    }

    // MARK: Dates

    /// Monday of the week holding `iso`.
    static func monday(of iso: String) -> String {
        LectioDates.shift(iso: iso, byDays: -weekdayIndex(iso))
    }

    /// 0 for Monday through 6 for Sunday.
    static func weekdayIndex(_ iso: String) -> Int {
        guard let weekday = LectioDates.weekday(iso: iso) else { return 0 }
        return (weekday + 5) % 7
    }

    private static func firstWord(_ text: String) -> String {
        text.split(separator: " ").first.map(String.init) ?? text
    }

    private static func dropFirstWord(_ text: String) -> String {
        text.split(separator: " ").dropFirst().joined(separator: " ")
    }
}

/// One day of the pager.
private struct DayPage: View {
    @EnvironmentObject private var session: LectioSession
    let date: String

    var body: some View {
        let code = LectioDates.weekCode(iso: date)
        VStack(alignment: .leading, spacing: 10) {
            if let week = session.snapshot.weeks[code] {
                DayList(day: week.days.first { $0.date == date }).equatable()
            } else {
                WeekPlaceholder(weekCode: code)
            }
        }
        .padding(.horizontal, Metrics.margin)
    }
}

// MARK: - Week overview (pinch out / calendar button)

struct WeekOverview: View {
    @EnvironmentObject private var session: LectioSession
    let weekCode: String
    var onPick: (String) -> Void

    private var week: ScheduleWeek? { session.snapshot.weeks[weekCode] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let week {
                ForEach(week.days) { day in
                    dayRow(day)
                        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 3, style: .continuous))
                        // A tap gesture, not a Button: a Button would also
                        // fire at the end of a sideways swipe across the row.
                        .onTapGesture { onPick(day.date) }
                }
            } else {
                WeekPlaceholder(weekCode: weekCode)
            }
        }
        .padding(.horizontal, Metrics.margin)
    }

    private func dayRow(_ day: ScheduleDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(dayName(day).uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(isToday(day) ? Palette.accent : Color(.secondaryLabel))
                Text(dayNum(day))
                    .font(.system(size: 18.5, weight: .bold))
                Spacer()
                Text("\(day.lessons.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !day.lessons.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(day.lessons.prefix(4)) { lesson in
                        HStack(spacing: 7) {
                            SubjectDot(code: lesson.code, size: 6)
                            Text(lesson.start)
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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

/// Which sheet a card in the older timeline layout (DayTimeline) opens. One
/// `item:` sheet rather than two `isPresented:` ones, which fight each other.
enum CardSheet: Int, Identifiable {
    case lesson, event
    var id: Int { rawValue }
}

struct LessonCard: View {
    let lesson: Lesson
    let dayISO: String
    @EnvironmentObject private var session: LectioSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lessonZoom) private var zoom
    @Environment(LessonOpener.self) private var opener: LessonOpener?
    @State private var editingEvent = false

    private var route: LessonRoute { LessonRoute(lesson: lesson, dayISO: dayISO) }
    private var state: LessonState { lesson.state(onDay: dayISO) }
    private var tint: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.forSubject(lesson.code)
    }
    private var stripe: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.subjectStripe(lesson.code, in: scheme)
    }
    /// Only a subject with a colour of its own gets the wash. Grey on the
    /// grey page measured 1.01:1 — the card simply vanished into the background.
    private var washed: Bool {
        !lesson.isPrivateEvent && !lesson.cancelled && state != .past
            && SubjectPalette.isAssigned(lesson.code)
    }

    var body: some View {
        // Tap gestures, not a Button or NavigationLink: those also fire at the
        // end of a sideways swipe that stays on the card.
        if lesson.isPrivateEvent {
            // Your own event is something to edit, so it stays a sheet.
            card
                .onTapGesture { editingEvent = true }
                .sheet(isPresented: $editingEvent) {
                    NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                        session.retryWeek(LectioDates.weekCode(iso: dayISO))
                    }
                    .environmentObject(session)
                }
        } else {
            card
                .onTapGesture { opener?.open(route) }
                .lessonZoomSource(route.zoomID, in: zoom)
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(lesson.start)
                    .font(.system(size: 16.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(lesson.end)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 58, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)

            // Calendar's event stripe: a solid bar in the subject colour. The
            // colour lives here and in the faint wash behind the card — never in
            // the text, which stays in the system's own label colours.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(lesson.cancelled ? Color(.tertiaryLabel) : stripe.opacity(state == .past ? 0.4 : 1))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(lesson.displayTitle)
                        .font(.system(size: 18.5, weight: .semibold))
                        .strikethrough(lesson.cancelled)
                        .foregroundStyle(lesson.cancelled ? Color(.secondaryLabel) : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if state == .current {
                        Text("NOW")
                            .font(.system(size: 11.5, weight: .heavy))
                            .foregroundStyle(.primary)
                    }
                }

                Text(metaLine)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)

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
        // A lesson that's over loses its colour — a paler stripe and no wash —
        // but never its legibility. Fading the whole card to half opacity took
        // the text with it, well below readable contrast; Calendar doesn't fade
        // past events at all.
        .background {
            RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous)
                .fill(tint.opacity(washed ? 0.08 : 0))
        }
        .contentCard(radius: Metrics.inner + 4)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .foregroundStyle(.primary)
    }

    private var metaLine: String {
        var bits: [String] = []
        if lesson.isPrivateEvent { bits.append("Private event") }
        // Skip the code when it's already standing in as the title.
        if !lesson.code.isEmpty && !lesson.title.isEmpty {
            bits.append(LessonText.abbreviated(lesson.code).uppercased())
        }
        if !lesson.room.isEmpty { bits.append(LessonText.abbreviated(lesson.room)) }
        if !lesson.teacher.isEmpty { bits.append(LessonText.abbreviated(lesson.teacher)) }
        if lesson.cancelled { bits.append("Cancelled") }
        else if lesson.changed { bits.append("Changed") }
        return bits.joined(separator: " · ")
    }

    private func previewLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1.5)
            Text(LectioDates.tidy(text))
                .font(.system(size: 14.5))
                .foregroundStyle(.secondary)
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
    @Environment(\.lessonZoom) private var zoom
    @Environment(LessonOpener.self) private var opener: LessonOpener?
    @State private var editingEvent = false

    private var route: LessonRoute { LessonRoute(lesson: lesson, dayISO: dayISO) }
    private var state: LessonState { lesson.state(onDay: dayISO) }
    private var tint: Color {
        lesson.isPrivateEvent ? Color.secondary : Color.forSubject(lesson.code)
    }
    private var washed: Bool {
        !lesson.isPrivateEvent && !lesson.cancelled && state != .past
            && SubjectPalette.isAssigned(lesson.code)
    }

    var body: some View {
        if lesson.isPrivateEvent {
            compactCard
                .onTapGesture { editingEvent = true }
                .sheet(isPresented: $editingEvent) {
                    NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                        session.retryWeek(LectioDates.weekCode(iso: dayISO))
                    }
                    .environmentObject(session)
                }
        } else {
            compactCard
                .onTapGesture { opener?.open(route) }
                .lessonZoomSource(route.zoomID, in: zoom)
        }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if lesson.isPrivateEvent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        SubjectDot(code: lesson.code, size: 6)
                    }
                    Text(lesson.start)
                        .font(.system(size: 14.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if state == .current {
                        Text("NOW")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.primary)
                    }
                }
                Text(lesson.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(lesson.cancelled)
                    .foregroundStyle(lesson.cancelled ? Color(.secondaryLabel) : Color.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.inner + 2, style: .continuous)
                    .fill(tint.opacity(washed ? 0.08 : 0))
            }
            .contentCard(radius: Metrics.inner + 2)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 2, style: .continuous))
            .foregroundStyle(.primary)
    }

    private var meta: String {
        var bits: [String] = []
        if !lesson.room.isEmpty { bits.append(LessonText.abbreviated(lesson.room)) }
        if !lesson.teacher.isEmpty { bits.append(LessonText.abbreviated(lesson.teacher)) }
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
                        .foregroundStyle(.secondary)
                    Text("Couldn't load this week")
                        .font(.system(size: 16.5, weight: .semibold))
                    if let why = session.weekErrors[weekCode] {
                        Text(why)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
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
/// Equatable so a page rebuilds its cards only when its own day changes, not on
/// every update to the session around it.
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
