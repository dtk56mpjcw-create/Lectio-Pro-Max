import SwiftUI

// MARK: - Routing

/// A lesson on a particular day — what the Schedule and Search stacks push.
///
/// The day is part of it because the same lesson recurs every week, and
/// neighbouring day pages are alive side by side.
struct LessonRoute: Hashable {
    let lesson: Lesson
    let dayISO: String
    /// Unique on screen: the day plus the lesson.
    var key: String { dayISO + "|" + lesson.id }
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

/// Opens lessons for the schedule's cards.
///
/// Lessons open with the standard push — slide in from the right, swipe from
/// the left edge to go back — not a zoom out of the card. SwiftUI's zoom
/// transition has known, unfixed bugs on iOS 26 (Apple forum threads 807208,
/// 807715, 796805; FB19601591): after a swipe back the card can vanish while
/// staying tappable, and repeated or interrupted zooms flicker and misalign.
/// Every workaround here only moved the problem; the push is rock solid, and
/// it's what Calendar uses for an event.
@Observable
final class LessonOpener {
    var path: [LessonRoute] = []

    func open(_ route: LessonRoute) {
        path.append(route)
    }
}

/// The day, with the week a tap away.
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

    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    /// Where each pager rests: a swipe writes it, and writing it jumps.
    @State private var dayPage: String? = LectioDates.isoString(from: Date())
    @State private var weekPage: String? = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
    @State private var weekMode = false
    @State private var addingEvent = false

    @State private var opener = LessonOpener()
    @State private var switcher = ScreenZoom()

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
    private func lessons(on date: String) -> [Lesson] {
        session.snapshot.weeks[LectioDates.weekCode(iso: date)]?
            .days.first { $0.date == date }?.lessons ?? []
    }

    /// Changes when the day on screen changes, or its week arrives.
    private var prefetchKey: String {
        selectedDate + (session.snapshot.weeks[weekCode] == nil ? "" : "+") + (weekMode ? "w" : "")
    }

    var body: some View {
        NavigationStack(path: $opener.path) {
            pagers
                .background { AppBackground() }
                // The buttons sit in the system bar, where the other tabs have
                // theirs. The big title is drawn at the top of each page
                // instead of by the system: the pages are side-scrolling, and
                // a system large title can't tell which of them to make room
                // in, so it drew over the lessons. On the page it lands where
                // the other tabs' titles are and slides along with the day.
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .environment(opener)
            .navigationDestination(for: LessonRoute.self) { route in
                LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
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
        // The moment a day is on screen its lessons start loading in the
        // background, so opening one is instant — then the next day's, ready
        // for the swipe. A new day replaces the queue; nothing piles up.
        .task(id: prefetchKey) {
            guard !weekMode else { return }
            let next = LectioDates.shift(iso: selectedDate, byDays: 1)
            let today = lessons(on: selectedDate)
            let tomorrow = lessons(on: next)
            guard !today.isEmpty || !tomorrow.isEmpty else { return }
            let cookies = await session.requestCookies()
            guard !Task.isCancelled else { return }
            LessonCache.shared.prefetch([(selectedDate, today), (next, tomorrow)], cookies: cookies)
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

    // MARK: Toolbar

    /// Today (when you're elsewhere), day/week, and a new event — in the
    /// navigation bar, as Calendar has them.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // No small title in the bar: the page has the big one.
        ToolbarItem(placement: .principal) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectedDate != today {
                Button("Today") { jumpToToday() }
                    .fontWeight(.semibold)
            }
            Button {
                setWeekMode(!weekMode)
            } label: {
                Label(weekMode ? "Day view" : "Week view",
                      systemImage: weekMode ? "rectangle.grid.1x2" : "calendar")
            }
            Button {
                addingEvent = true
            } label: {
                Label("New event", systemImage: "plus")
            }
        }
    }

    /// For the back button and VoiceOver; the pages draw their own titles.
    private var title: String {
        weekMode ? Self.weekTitle(Self.monday(of: selectedDate)) : Self.dayTitle(selectedDate)
    }

    /// "Today", "Tomorrow" and "Yesterday" as they are; any other day by its
    /// weekday, with the date underneath.
    static func dayTitle(_ date: String) -> String {
        let friendly = LectioDates.friendlyLabel(iso: date)
        if friendly != LectioDates.dayLabel(iso: date) { return friendly }
        return firstWord(LectioDates.longLabel(iso: date))
    }

    static func daySubtitle(_ date: String) -> String {
        let long = LectioDates.longLabel(iso: date)
        return dayTitle(date) == firstWord(long) ? dropFirstWord(long) : long
    }

    /// "Week 40", "28 Sep – 4 Oct".
    static func weekTitle(_ monday: String) -> String {
        LectioDates.weekLabel(code: LectioDates.weekCode(iso: monday))
    }

    static func weekSubtitle(_ monday: String) -> String {
        let sunday = LectioDates.shift(iso: monday, byDays: 6)
        return dropFirstWord(LectioDates.dayLabel(iso: monday))
            + " – " + dropFirstWord(LectioDates.dayLabel(iso: sunday))
    }

    // MARK: Pagers

    private var pagers: some View {
        // Both pagers stay alive, the week over the day, and the switch is a
        // single step underneath a snapshot that animates away (ScreenZoom).
        ZStack {
            ScrollViewReader { proxy in
                dayPager(proxy)
            }
            .allowsHitTesting(!weekMode)
            .scrollDisabled(weekMode)
            .accessibilityHidden(weekMode)

            ScrollViewReader { proxy in
                weekPager(proxy)
            }
            .background(Color(.systemGroupedBackground))
            .opacity(weekMode ? 1 : 0)
            .allowsHitTesting(weekMode)
            .scrollDisabled(!weekMode)
            .accessibilityHidden(!weekMode)
        }
        .overlay {
            ScreenZoomHost(zoom: switcher)
                .allowsHitTesting(false)
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

    /// Snapshot what's showing, flip underneath it in one step, then let the
    /// snapshot zoom away (see ScreenZoom).
    private func setWeekMode(_ on: Bool) {
        guard on != weekMode else { return }
        switcher.cover(excludingBottom: bottomInset)
        weekMode = on
        switcher.play(outward: on)
    }

    /// A day tapped in the week view: zoom back in on it.
    private func pick(_ date: String) {
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

    fileprivate static func firstWord(_ text: String) -> String {
        text.split(separator: " ").first.map(String.init) ?? text
    }

    fileprivate static func dropFirstWord(_ text: String) -> String {
        text.split(separator: " ").dropFirst().joined(separator: " ")
    }
}

/// Plays the switch between day and week on a picture of the screen.
///
/// The pages are heavy to animate in SwiftUI — scaling or fading them means
/// updating every scroll view inside, every frame, and on a phone that shows
/// as stutter. So at the moment of the switch this takes a snapshot of what's
/// on screen, lays it over the pages, flips to the other view underneath in a
/// single step, and animates only the snapshot — shrinking away as you zoom
/// out to the week, growing away as you zoom into a day — while it fades to
/// reveal the view underneath. That's pure Core Animation on one layer,
/// smooth however much is on the page.
final class ScreenZoom {
    /// The view laid over the pages (see ScreenZoomHost).
    weak var host: UIView?
    private var picture: UIView?
    private var animator: UIViewPropertyAnimator?

    /// Covers the pages with a picture of them as they are now. Call it just
    /// before changing what's underneath, then `play` straight after.
    /// - Parameter bottom: how much of the bottom to leave out — the strip
    ///   under the tab bar, so the picture doesn't include the bar itself.
    func cover(excludingBottom bottom: CGFloat) {
        finishNow()
        guard let host, let window = host.window,
              host.bounds.width > 0, host.bounds.height > bottom else { return }
        let area = CGRect(x: 0, y: 0, width: host.bounds.width,
                          height: host.bounds.height - bottom)
        guard let shot = window.resizableSnapshotView(from: host.convert(area, to: window),
                                                      afterScreenUpdates: false,
                                                      withCapInsets: .zero) else { return }
        shot.frame = area
        shot.isUserInteractionEnabled = false
        host.addSubview(shot)
        picture = shot
    }

    /// Animates the cover away: smaller when zooming out to the week, larger
    /// when zooming into a day.
    func play(outward: Bool) {
        guard let shot = picture else { return }
        // Reduce Motion: a plain cross-fade, no zoom.
        let scale: CGFloat = UIAccessibility.isReduceMotionEnabled ? 1 : (outward ? 0.9 : 1.1)
        let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 1) {
            shot.transform = CGAffineTransform(scaleX: scale, y: scale)
            shot.alpha = 0
        }
        animator.addCompletion { [weak self] _ in
            shot.removeFromSuperview()
            if self?.picture === shot { self?.picture = nil }
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// Ends whatever is running at once — for a second tap mid-animation.
    func finishNow() {
        animator?.stopAnimation(true)
        animator = nil
        picture?.removeFromSuperview()
        picture = nil
    }
}

/// The empty, touch-transparent view over the pages that ScreenZoom draws on.
private struct ScreenZoomHost: UIViewRepresentable {
    let zoom: ScreenZoom

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // The growing picture mustn't spill over the header.
        view.clipsToBounds = true
        zoom.host = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        zoom.host = uiView
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
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    PageHeading(title: ScheduleTab.dayTitle(date),
                                subtitle: ScheduleTab.daySubtitle(date))
                    if let week = session.snapshot.weeks[code] {
                        DayList(day: week.days.first { $0.date == date },
                                modules: week.resolvedModules,
                                className: session.snapshot.profile.className)
                            .equatable()
                    } else {
                        WeekPlaceholder(weekCode: code)
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, bottomInset + 24)
            }
        }
        .scrollIndicators(.hidden)
        // The system's own pull to refresh, the work in a task of its own so
        // an update mid-refresh can't cancel it.
        .refreshable { await Task { await session.refresh() }.value }
    }
}

/// A page's title, where the other tabs have their large titles: 34 pt
/// bold, 16 pt in, the date under it.
private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The system's large titles sit 16 pt in; the page's margin is 18.
        .padding(.leading, 16 - Metrics.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
            VStack(spacing: 10) {
                PageHeading(title: ScheduleTab.weekTitle(monday),
                            subtitle: ScheduleTab.weekSubtitle(monday))
                    .padding(.horizontal, Metrics.margin)
                WeekOverview(weekCode: LectioDates.weekCode(iso: monday), monday: monday, onPick: onPick)
            }
            .padding(.top, 8)
            .padding(.bottom, bottomInset + 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await Task { await session.refresh() }.value }
    }
}

// MARK: - Week overview (calendar button)

/// The week as a timetable: the days across, the school's modules down,
/// each lesson a block in its subject's colour. Tap a day (or any block in
/// it) to open that day.
struct WeekOverview: View {
    @EnvironmentObject private var session: LectioSession
    let weekCode: String
    let monday: String
    var onPick: (String) -> Void

    private var week: ScheduleWeek? { session.snapshot.weeks[weekCode] }

    var body: some View {
        Group {
            if let week {
                WeekGrid(week: week,
                         monday: monday,
                         className: session.snapshot.profile.className,
                         onPick: onPick)
            } else {
                WeekPlaceholder(weekCode: weekCode)
            }
        }
        .padding(.horizontal, Metrics.margin)
    }
}

private struct WeekGrid: View {
    let week: ScheduleWeek
    let monday: String
    let className: String
    var onPick: (String) -> Void

    @Environment(\.colorScheme) private var scheme

    private static let labelWidth: CGFloat = 24
    private static let gap: CGFloat = 4

    /// Monday to Friday always; the weekend only when something's on.
    private var dates: [String] {
        var out = (0..<5).map { LectioDates.shift(iso: monday, byDays: $0) }
        for extra in [5, 6] {
            let date = LectioDates.shift(iso: monday, byDays: extra)
            if week.days.contains(where: { $0.date == date && $0.lessons.contains { !$0.isAllDay } }) {
                out.append(date)
            }
        }
        return out
    }

    var body: some View {
        let modules = week.resolvedModules
        let today = LectioDates.isoString(from: Date())
        var plans: [String: DayPlan] = [:]
        for date in dates {
            let day = week.days.first { $0.date == date }
                ?? ScheduleDay(date: date, label: LectioDates.dayLabel(iso: date), lessons: [])
            plans[date] = DayPlan.build(day, modules: modules, className: className)
        }
        let lastUsed = plans.values.compactMap { $0.slots.last?.module.number }.max() ?? 0
        let shown = modules.filter { $0.number <= max(lastUsed, min(4, modules.count)) }
        let hasAllDay = plans.values.contains { !$0.allDay.isEmpty }
        let hasAfter = plans.values.contains { !$0.after.isEmpty }

        return TimelineView(.everyMinute) { context in
            let nowMinutes = DayList.minutes(of: context.date)
            VStack(spacing: Self.gap + 2) {
                HStack(spacing: Self.gap) {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    ForEach(dates, id: \.self) { date in
                        Button { onPick(date) } label: { dayHeader(date, isToday: date == today) }
                            .buttonStyle(.plain)
                    }
                }

                if hasAllDay {
                    HStack(spacing: Self.gap) {
                        sideLabel("All\nday")
                        ForEach(dates, id: \.self) { date in
                            allDayCell(plans[date]?.allDay ?? [])
                        }
                    }
                }

                ForEach(shown) { module in
                    HStack(spacing: Self.gap) {
                        VStack(spacing: 0) {
                            Text("\(module.number)")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text(module.shortStart)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        .frame(width: Self.labelWidth)

                        ForEach(dates, id: \.self) { date in
                            let slot = plans[date]?.slots.first { $0.module.number == module.number }
                            let current = date == today
                                && nowMinutes >= module.startMinutes && nowMinutes < module.endMinutes
                            Button { onPick(date) } label: { cell(slot, current: current) }
                                .buttonStyle(PressableCard())
                        }
                    }
                }

                if hasAfter {
                    HStack(spacing: Self.gap) {
                        sideLabel("After")
                        ForEach(dates, id: \.self) { date in
                            afterCell(plans[date]?.after ?? [])
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Pieces

    private func dayHeader(_ date: String, isToday: Bool) -> some View {
        let parts = LectioDates.dayLabel(iso: date).split(separator: " ").map(String.init)
        return VStack(spacing: 3) {
            Text(parts.first ?? "")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isToday ? Palette.accent : Color(.secondaryLabel))
            Text(parts.count > 1 ? parts[1] : "")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background { if isToday { Circle().fill(Palette.accent) } }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func sideLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth)
    }

    /// One module on one day: a block in the lesson's colour, blank when free.
    private func cell(_ slot: DayPlan.Slot?, current: Bool) -> some View {
        let lesson = slot?.main.first ?? slot?.continuing.first
        let cancelled = lesson == nil ? slot?.cancelled.first : nil
        let extra = (slot?.main.count ?? 0) + (slot?.continuing.count ?? 0) - 1
        let colour = lesson.map { $0.isClassLesson ? Color.forSubject($0.code) : Color(.systemGray) }
        let stripe = lesson.map { $0.isClassLesson ? Color.subjectStripe($0.code, in: scheme) : Color(.systemGray) }

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
            if let colour {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colour.opacity(scheme == .dark ? 0.32 : 0.2))
            }
            if let stripe {
                Capsule().fill(stripe)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 3)
            }

            if let lesson {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lesson.shortLabel)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if !lesson.room.isEmpty {
                        Text(LessonText.abbreviated(lesson.room))
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 3)
                .padding(.top, 6)
            } else if let cancelled {
                Text(cancelled.shortLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(6)
            }
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                if extra > 0 {
                    Text("+\(extra)").font(.system(size: 9, weight: .bold))
                }
                if let lesson, !lesson.homework.isEmpty {
                    Image(systemName: "book.closed.fill").font(.system(size: 8.5))
                }
                if let lesson, lesson.changed && lesson.isClassLesson {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(.secondary)
            .padding(4)
        }
        .overlay {
            if current {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lesson.map { $0.headline + ($0.room.isEmpty ? "" : ", room " + $0.room) }
                            ?? (cancelled.map { $0.headline + " cancelled" } ?? "Free"))
    }

    private func allDayCell(_ items: [Lesson]) -> some View {
        Group {
            if let first = items.first {
                Text(first.headline + (items.count > 1 ? " +\(items.count - 1)" : ""))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 20)
            }
        }
    }

    private func afterCell(_ items: [Lesson]) -> some View {
        Group {
            if let first = items.first {
                Text(first.headline + (items.count > 1 ? " +\(items.count - 1)" : ""))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 20)
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 20)
            }
        }
    }
}


// MARK: - Loading

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
