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

/// Opens lessons for the schedule's cards — and keeps a pinch from counting as
/// a tap: the fingers lifting off a card at the end of a pinch used to open it.
@Observable
final class LessonOpener {
    var path: [LessonRoute] = []
    @ObservationIgnored var lastPinch = Date.distantPast
    /// Bumped a moment after a lesson closes, to rebuild the cards. A zoom
    /// transition hides the card it grew out of while it runs; interrupt the
    /// swipe back by touching the page too soon and the card could stay
    /// hidden — invisible, yet still tappable. A fresh card is always visible.
    var returnToken = 0

    var pinchedJustNow: Bool { Date().timeIntervalSince(lastPinch) < 0.5 }

    func open(_ route: LessonRoute) {
        guard !pinchedJustNow else { return }
        path.append(route)
    }
}

/// The day, with the week a pinch or a tap away.
///
/// Days page sideways in a real paging scroll view, and each day is a scroll
/// view of its own — the layout Calendar uses. That's what gives the swipe the
/// system's own feel: it follows the finger, locks to one direction so the day
/// doesn't wobble up and down, snaps with the flick's speed, and every day
/// keeps its own scroll position and length (no blank space, no jump to top).
///
/// An earlier version nested the pager inside one vertical scroll view; there
/// it measured its height once and cut the day off. Here each page is simply
/// as tall as the screen.
struct ScheduleTab: View {
    @EnvironmentObject private var session: LectioSession
    @Namespace private var zoom

    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    /// Where each pager rests: a swipe writes it, and writing it jumps.
    @State private var dayPage: String? = LectioDates.isoString(from: Date())
    @State private var weekPage: String? = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
    @State private var weekMode = false
    @State private var addingEvent = false

    @State private var opener = LessonOpener()

    /// The pages run under the tab bar, so the last lesson needs room to
    /// scroll clear of it. The floor is the floating tab bar's own height, in
    /// case the measurement comes back empty — as it once did, leaving the
    /// last lessons stuck under the bar.
    @State private var safeBottom: CGFloat = 0
    private var bottomInset: CGFloat { max(safeBottom, 84) }

    /// Eight months either side of today. The pages are lazy, so the length
    /// costs nothing.
    private static let days: [String] = {
        let today = LectioDates.isoString(from: Date())
        return (-240...240).map { LectioDates.shift(iso: today, byDays: $0) }
    }()

    private static let weeks: [String] = {
        let monday = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
        return (-34...34).map { LectioDates.shift(iso: monday, byDays: $0 * 7) }
    }()

    private var today: String { LectioDates.isoString(from: Date()) }
    private var weekCode: String { LectioDates.weekCode(iso: selectedDate) }

    var body: some View {
        NavigationStack(path: $opener.path) {
            VStack(spacing: 0) {
                header
                pagers
            }
            .background { AppBackground() }
            // The header above is the title bar here; the system bar only
            // appears on a lesson pushed from it.
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.lessonZoom, zoom)
            .environment(opener)
            .navigationDestination(for: LessonRoute.self) { route in
                LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
                    .navigationTransition(.zoom(sourceID: route.zoomID, in: zoom))
            }
        }
        .onChange(of: opener.path.count) { old, new in
            guard new < old else { return }
            Task { @MainActor in
                // After the zoom back has finished, and only if nothing new
                // has been opened meanwhile (that needs its card in place).
                try? await Task.sleep(for: .milliseconds(650))
                if opener.path.isEmpty { opener.returnToken += 1 }
            }
        }
        .onChange(of: dayPage) { _, page in
            // A swipe landed on another day.
            guard let page, page != selectedDate else { return }
            selectedDate = page
            weekPage = Self.monday(of: page)
        }
        .onChange(of: weekPage) { _, monday in
            // A swipe landed on another week: same weekday, new week.
            guard let monday, monday != Self.monday(of: selectedDate) else { return }
            let moved = LectioDates.shift(iso: monday, byDays: Self.weekdayIndex(selectedDate))
            selectedDate = moved
            dayPage = moved
        }
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
        .sensoryFeedback(.selection, trigger: weekMode)
        .sheet(isPresented: $addingEvent) {
            NewEventSheet(dayISO: selectedDate) {
                // Pull the week again so the new event turns up straight away.
                session.retryWeek(weekCode)
            }
            .environmentObject(session)
        }
    }

    // MARK: Header

    /// Title, date and the three controls on one row — compact, like the
    /// header this replaced, but in real glass.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 8) {
                    if selectedDate != today {
                        Button {
                            jumpToToday()
                        } label: {
                            Text("Today")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                // Never squeezed: it was being crushed to "T…"
                                // inside its capsule by a long day name.
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    GlassCircleButton(systemName: weekMode ? "rectangle.grid.1x2" : "calendar") {
                        setWeekMode(!weekMode)
                    }
                    .accessibilityLabel(weekMode ? "Day view" : "Week view")
                    GlassCircleButton(systemName: "plus") {
                        addingEvent = true
                    }
                    .accessibilityLabel("New event")
                }
            }
            .animation(.smooth(duration: 0.3), value: selectedDate == today)
            // The buttons keep their size; a long day name shrinks instead.
            .layoutPriority(1)
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

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

    // MARK: Pagers

    private var pagers: some View {
        ScheduleZoom(weekMode: weekMode,
                     onPinch: { opener.lastPinch = Date() },
                     onSwitch: { setWeekMode($0) }) {
            ScrollViewReader { proxy in
                dayPager(proxy)
            }
        } week: {
            ScrollViewReader { proxy in
                weekPager(proxy)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.safeAreaInsets.bottom
        } action: { inset in
            safeBottom = inset
        }
    }

    private func dayPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.days, id: \.self) { date in
                    DayPage(date: date, bottomInset: bottomInset)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $dayPage, anchor: .center)
        .scrollIndicators(.hidden)
        .onAppear { align(proxy, on: selectedDate) }
        .onScrollPhaseChange { _, phase, _ in
            if phase == .idle { align(proxy, on: dayPage ?? selectedDate, animated: true) }
        }
    }

    private func weekPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.weeks, id: \.self) { monday in
                    WeekPage(monday: monday, bottomInset: bottomInset) { date in
                        pick(date)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $weekPage, anchor: .center)
        .scrollIndicators(.hidden)
        .onAppear { align(proxy, on: Self.monday(of: selectedDate)) }
        .onScrollPhaseChange { _, phase, _ in
            if phase == .idle {
                align(proxy, on: weekPage ?? Self.monday(of: selectedDate), animated: true)
            }
        }
    }

    /// Makes sure a pager rests squarely on a page. Normally a no-op; it's
    /// there for the times something interrupts a swipe halfway — switching
    /// between day and week mid-gesture left two half days on screen.
    private func align(_ proxy: ScrollViewProxy, on id: String, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: Moving around

    private func setWeekMode(_ on: Bool) {
        withAnimation(.smooth(duration: 0.35)) { weekMode = on }
    }

    /// A day tapped in the week view: zoom back in on it.
    private func pick(_ date: String) {
        // Fingers lifting at the end of a pinch aren't a tap on a day.
        guard !opener.pinchedJustNow else { return }
        selectedDate = date
        dayPage = date
        setWeekMode(false)
    }

    /// Scrolls when today is close by; from further away it just goes there,
    /// rather than spinning through weeks of pages to get back.
    private func jumpToToday() {
        let target = today
        let here = Self.days.firstIndex(of: selectedDate) ?? 0
        let there = Self.days.firstIndex(of: target) ?? 0
        let apply = {
            selectedDate = target
            dayPage = target
            weekPage = Self.monday(of: target)
        }
        if abs(here - there) <= 7 {
            withAnimation(.smooth) { apply() }
        } else {
            apply()
        }
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

/// The pinch between the day and the week.
///
/// A view of its own so that each frame of a pinch re-evaluates only this —
/// a couple of modifiers — instead of the whole schedule. Both pagers stay
/// alive underneath (rebuilding the day pager on the way back from the week
/// sometimes left it resting between two days).
///
/// While you pinch, only the view you're on moves, and only in scale: cheap to
/// draw every frame. Cross the line and the switch happens there and then,
/// mid-pinch, the way Photos steps between grid sizes — the cross-fade runs
/// once, as an animation, instead of being redrawn under the fingers.
private struct ScheduleZoom<Day: View, Week: View>: View {
    let weekMode: Bool
    var onPinch: () -> Void
    var onSwitch: (Bool) -> Void
    @ViewBuilder var day: Day
    @ViewBuilder var week: Week

    @GestureState(resetTransaction: Transaction(animation: .smooth(duration: 0.25)))
    private var pinch: CGFloat = 1
    /// Set once a pinch has switched views, so the rest of it is ignored.
    @State private var committed = false

    var body: some View {
        ZStack {
            day
                .scaleEffect(weekMode ? 0.92 : 1 - 0.06 * progress)
                .opacity(weekMode ? 0 : 1)
                .allowsHitTesting(!weekMode)
                .accessibilityHidden(weekMode)
            week
                .scaleEffect(weekMode ? 1 + 0.06 * progress : 1.08)
                .opacity(weekMode ? 1 : 0)
                .allowsHitTesting(weekMode)
                .accessibilityHidden(!weekMode)
        }
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in
                    state = value.magnification
                }
                .onChanged { value in
                    onPinch()
                    guard !committed else { return }
                    let m = value.magnification
                    if (!weekMode && m <= 0.86) || (weekMode && m >= 1.14) {
                        commit()
                    }
                }
                .onEnded { value in
                    onPinch()
                    if !committed {
                        // A shorter pinch still counts if it's clearly meant.
                        let m = value.magnification
                        if (!weekMode && m < 0.94) || (weekMode && m > 1.06) {
                            commit()
                        }
                    }
                    committed = false
                }
        )
    }

    /// 0 at rest, 1 at the line — for the view you're on only.
    private var progress: CGFloat {
        guard !committed else { return 0 }
        return weekMode ? min(max(pinch - 1, 0) / 0.14, 1) : min(max(1 - pinch, 0) / 0.14, 1)
    }

    private func commit() {
        withAnimation(.smooth(duration: 0.35)) { committed = true }
        onSwitch(!weekMode)
    }
}

/// One day of the pager: its own scroll view, with its own pull to refresh.
private struct DayPage: View {
    @EnvironmentObject private var session: LectioSession
    let date: String
    let bottomInset: CGFloat

    var body: some View {
        let code = LectioDates.weekCode(iso: date)
        ScrollView {
            RefreshHeader(space: "schedule-page") { await session.refresh() }
            VStack(alignment: .leading, spacing: 10) {
                if let week = session.snapshot.weeks[code] {
                    DayList(day: week.days.first { $0.date == date }).equatable()
                } else {
                    WeekPlaceholder(weekCode: code)
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 4)
            .padding(.bottom, bottomInset + 24)
        }
        .coordinateSpace(.named("schedule-page"))
        .scrollIndicators(.hidden)
    }
}

/// One week of the week pager.
private struct WeekPage: View {
    @EnvironmentObject private var session: LectioSession
    let monday: String
    let bottomInset: CGFloat
    var onPick: (String) -> Void

    var body: some View {
        ScrollView {
            RefreshHeader(space: "schedule-week") { await session.refresh() }
            WeekOverview(weekCode: LectioDates.weekCode(iso: monday), onPick: onPick)
                .padding(.top, 4)
                .padding(.bottom, bottomInset + 24)
        }
        .coordinateSpace(.named("schedule-week"))
        .scrollIndicators(.hidden)
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
                    Button {
                        onPick(day.date)
                    } label: {
                        dayRow(day)
                            .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 3, style: .continuous))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(PressableCard())
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
        // Buttons: the day pages in a real scroll view, which cancels the
        // press the moment a swipe starts. Lessons push through the opener,
        // which ignores the lift at the end of a pinch.
        if lesson.isPrivateEvent {
            // Your own event is something to edit, so it stays a sheet.
            Button { editingEvent = true } label: { card }
                .buttonStyle(PressableCard())
                .sheet(isPresented: $editingEvent) {
                    NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                        session.retryWeek(LectioDates.weekCode(iso: dayISO))
                    }
                    .environmentObject(session)
                }
        } else {
            Button { opener?.open(route) } label: { card }
                .buttonStyle(PressableCard())
                .lessonZoomSource(route.zoomID, in: zoom)
                .id(opener?.returnToken ?? 0)
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
        // A button's label takes the accent colour otherwise, and every
        // `.secondary` inside would turn faintly blue with it.
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
            Button { editingEvent = true } label: { compactCard }
                .buttonStyle(PressableCard())
                .sheet(isPresented: $editingEvent) {
                    NewEventSheet(dayISO: dayISO, eventID: lesson.privateEventID) {
                        session.retryWeek(LectioDates.weekCode(iso: dayISO))
                    }
                    .environmentObject(session)
                }
        } else {
            Button { opener?.open(route) } label: { compactCard }
                .buttonStyle(PressableCard())
                .lessonZoomSource(route.zoomID, in: zoom)
                .id(opener?.returnToken ?? 0)
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
