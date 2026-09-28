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
    @Environment(LectioSession.self) private var session

    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    /// Where each pager rests: a swipe writes it, and writing it jumps.
    @State private var dayPage: String? = LectioDates.isoString(from: Date())
    @State private var weekPage: String? = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
    @State private var weekMode = false
    @State private var addingEvent = false

    @State private var opener = LessonOpener()
    @State private var switcher = ScreenZoom()
    /// A day the week view should scroll to (Today, in week view).
    @State private var weekFocus: WeekFocus?

    /// The pages run under the tab bar, so the last lesson needs room to
    /// scroll clear of it. The floor is the floating tab bar's own height, in
    /// case the measurement comes back empty — as it once did, leaving the
    /// last lessons stuck under the bar.
    @State private var safeBottom: CGFloat = 0
    private var bottomInset: CGFloat { max(safeBottom, 84) }
    /// Where the tab bar starts, in points from the top of the screen. Each
    /// page measures itself against it (see `barClearance`).
    @State private var barLine: CGFloat = 0
    /// The width `barLine` was measured at: a new width (the phone turned)
    /// measures afresh.
    @State private var measuredWidth: CGFloat = 0

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
        #if DEBUG
        let _ = ScrollDebug.log("ScheduleTab redrawn")
        let _ = Self._printChanges()
        #endif
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
        // From a widget or a notification: that day, and that lesson.
        .onChange(of: AppRouter.shared.request, initial: true) { _, request in
            guard let request else { return }
            switch request.route {
            case .day(let date):
                AppRouter.shared.request = nil
                show(date)
            case .lesson(let date, let start, let key):
                AppRouter.shared.request = nil
                show(date)
                Task { await openLesson(on: date, start: start, key: key) }
            default:
                break
            }
        }
        .sheet(isPresented: $addingEvent) {
            NewEventSheet(dayISO: selectedDate) {
                // Pull the week again so the new event turns up straight away.
                session.retryWeek(weekCode)
            }
            .environment(session)
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
            // As in Calendar: only when it would take you somewhere — in the
            // day view, another day; in the week view, another week.
            if weekMode ? (weekPage != Self.monday(of: today)) : (selectedDate != today) {
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
        // Both held at the tab bar's tallest. The bar shrinks as you scroll
        // down and grows back as you scroll up; following it moved the end of
        // every page with it, mid-scroll — the page's height changed under
        // your finger, which is what made a held scroll jerk (and could tip
        // the bar back and forth). The tallest bar's line holds for both.
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.safeAreaInsets.bottom
        } action: { inset in
            // Only a real change is written: each write redraws the pages.
            #if DEBUG
            ScrollDebug.log("safe area bottom \(inset) (kept \(max(inset, safeBottom)))")
            #endif
            if inset > safeBottom { safeBottom = inset }
        }
        // The bottom of the area the tab bar leaves free: this frame is the
        // one inside the safe area (the pagers only draw past it), so its
        // bottom edge is the top of the bar. Taking the reported inset off
        // as well counted the bar twice — 84 pt of empty space under the
        // last lesson.
        .onGeometryChange(for: CGPoint.self) { geometry in
            CGPoint(x: geometry.size.width.rounded(), y: geometry.frame(in: .global).maxY.rounded())
        } action: { measured in
            #if DEBUG
            ScrollDebug.log("bar line \(measured.y) width \(measured.x) (was \(barLine))")
            #endif
            if measured.x != measuredWidth || barLine <= 0 {
                measuredWidth = measured.x
                barLine = measured.y
            } else if measured.y < barLine, barLine - measured.y < 150 {
                // Up to a whole bar higher: the bar grown back, or the first
                // reading taken before there was one. Anything more (a
                // keyboard) is passing, and would leave a screen of space.
                barLine = measured.y
            }
        }
    }

    private func dayPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.days, id: \.self) { date in
                    DayPage(date: date, bottomInset: bottomInset, barLine: barLine)
                        // Only the width is the pager's: the height is simply
                        // the height the pager gives it. Sizing it to the
                        // pager vertically too made each page as tall as the
                        // whole pager and then set it below the navigation
                        // bar — and SwiftUI worked that height out again while
                        // a finger was dragging the day, so on a day long
                        // enough to scroll, a pull past its end was yanked
                        // back mid-drag.
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $dayPage, anchor: .center)
        .scrollIndicators(.hidden)
        .onAppear { align(proxy, on: selectedDate) }
        .onScrollPhaseChange { _, phase, context in
            if phase == .idle, Self.isBetweenPages(context.geometry) {
                align(proxy, on: dayPage ?? selectedDate, animated: true)
            }
        }
    }

    private func weekPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.weeks, id: \.self) { monday in
                    WeekPage(monday: monday, bottomInset: bottomInset, barLine: barLine,
                             focus: weekFocus.flatMap { Self.monday(of: $0.date) == monday ? $0 : nil }) { date in
                        pick(date)
                    }
                    .containerRelativeFrame(.horizontal)       // see dayPager
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $weekPage, anchor: .center)
        .scrollIndicators(.hidden)
        .onAppear { align(proxy, on: Self.monday(of: selectedDate)) }
        .onScrollPhaseChange { _, phase, context in
            if phase == .idle, Self.isBetweenPages(context.geometry) {
                align(proxy, on: weekPage ?? Self.monday(of: selectedDate), animated: true)
            }
        }
    }

    /// Makes sure a pager rests squarely on a page. Normally a no-op; it's
    /// there for the times something interrupts a swipe halfway — switching
    /// between day and week mid-gesture left two half days on screen.
    /// Whether a pager came to rest part-way between two pages. Normally it
    /// doesn't — paging sees to that — and then it's left alone: scrolling
    /// it to where it already is, after every swipe, could still be under
    /// way when your finger came down to scroll the day, and caught it.
    static func isBetweenPages(_ geometry: ScrollGeometry) -> Bool {
        let width = geometry.containerSize.width
        guard width > 0 else { return false }
        let off = geometry.contentOffset.x.truncatingRemainder(dividingBy: width)
        return abs(off) > 1 && abs(width - off) > 1
    }

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

    /// Straight to a day, in the day view, with nothing open on top.
    private func show(_ date: String) {
        opener.path = []
        if weekMode { weekMode = false }
        selectedDate = date
        dayPage = date
        weekPage = Self.monday(of: date)
    }

    /// Opens a lesson once its week is here — on a cold start that can take
    /// a moment, so it waits a few seconds for it.
    private func openLesson(on date: String, start: String, key: String?) async {
        let minutes = Lesson.minutes(from: start)
        for _ in 0..<40 {
            let all = lessons(on: date)
            let hit = all.first { key != nil && ScheduleWatch.lessonKey($0) == key }
                ?? all.first { !$0.isAllDay && minutes != nil && Lesson.minutes(from: $0.start) == minutes }
            if let hit {
                opener.open(LessonRoute(lesson: hit, dayISO: date))
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
        // In the week view, land on today's card, not the top of the week.
        if weekMode { weekFocus = WeekFocus(date: target) }
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
    @Environment(LectioSession.self) private var session
    let date: String
    let bottomInset: CGFloat
    let barLine: CGFloat
    /// Where this page's scroll view ends, from the top of the screen.
    @State private var pageBottom: CGFloat = 0

    var body: some View {
        let code = LectioDates.weekCode(iso: date)
        #if DEBUG
        let _ = ScrollDebug.log("DayPage \(date) redrawn")
        let _ = Self._printChanges()
        #endif
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    PageHeading(title: ScheduleTab.dayTitle(date),
                                subtitle: ScheduleTab.daySubtitle(date))
                    if let week = session.snapshot.weeks[code] {
                        DayOfWeek(week: week, date: date,
                                  className: session.snapshot.profile.className,
                                  dayEnd: ScheduleWeek.rememberedDayEnd)
                            .equatable()
                    } else {
                        WeekPlaceholder(weekCode: code)
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, barClearance(pageBottom: pageBottom, barLine: barLine,
                                               atLeast: bottomInset) + 24)
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .global).maxY.rounded()
        } action: { bottom in
            #if DEBUG
            ScrollDebug.log("DayPage \(date) bottom \(bottom) (was \(pageBottom))")
            #endif
            pageBottom = bottom
        }
        #if DEBUG
        // In Xcode's console: the day's visible height and content height
        // whenever either changes (neither should while you drag), and each
        // change of what the scroll view is doing, with where it is.
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.containerSize.height.rounded(), height: geometry.contentSize.height.rounded())
        } action: { old, new in
            ScrollDebug.log("DayPage \(date) visible \(old.width)→\(new.width), content \(old.height)→\(new.height)")
        }
        .onScrollPhaseChange { old, new, context in
            let g = context.geometry
            let end = g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height
            ScrollDebug.log("DayPage \(date) \(old) → \(new)  y \(Int(g.contentOffset.y + g.contentInsets.top)) of \(Int(end))")
        }
        #endif
        .scrollIndicators(.hidden)
        // The system's own pull to refresh, the work in a task of its own so
        // an update mid-refresh can't cancel it.
        .refreshable { await Task { await session.refresh() }.value }
    }
}

/// How far the end of a page's content has to stay above the page's bottom
/// edge to scroll clear of the tab bar: however much of the page the bar
/// covers. Measured rather than assumed: the pages run on under the bar,
/// and a fixed allowance that didn't match left the last lesson or event
/// half under it on long days.
fileprivate func barClearance(pageBottom: CGFloat, barLine: CGFloat, atLeast floor: CGFloat) -> CGFloat {
    guard pageBottom > 0, barLine > 0 else { return floor }
    // A frame caught mid-transition can read oddly; never less than the
    // bar itself, never absurdly more.
    return min(max(pageBottom - barLine, floor), 400)
}

/// A page's title, where the other tabs have their large titles: 34 pt
/// bold, 16 pt in, the date under it.
private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: -3) {
            Text(title)
                .scaledFont(size: 34, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            // The system's large-title subtitle is this small: measured
            // against "9 things to do" on Homework.
            Text(subtitle)
                .scaledFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The system's large titles sit 16 pt in; the page's margin is 18.
        .padding(.leading, 16 - Metrics.margin)
        // Measured against Homework, Messages and Me: 28 pt lower than the
        // first try put the title's top and the date exactly where theirs
        // are — and clear of the bar's fade, which had greyed it.
        .padding(.top, 35.5)
        .padding(.bottom, 4)
    }
}

/// A day of the pager, worked out from its week. Equatable: the day's plan,
/// the school day's modules and the week's rolling notes are worked out
/// again only when the week, the class or the remembered end of the day
/// change — not on every update anywhere in the app.
private struct DayOfWeek: View, Equatable {
    let week: ScheduleWeek
    let date: String
    let className: String
    let dayEnd: Int?

    var body: some View {
        DayList(day: week.days.first { $0.date == date },
                modules: week.dayModules,
                className: className,
                rolling: week.rollingNotes(className: className))
            .equatable()
    }
}

/// The week's title and its summary ("21 – 25 Sep · 19 lessons · 6 with
/// homework"), worked out only when the week changes.
private struct WeekHeading: View, Equatable {
    let week: ScheduleWeek?
    let monday: String
    let className: String
    let dayEnd: Int?

    var body: some View {
        PageHeading(title: ScheduleTab.weekTitle(monday),
                    subtitle: WeekAgenda.subtitle(week: week, monday: monday, className: className)
                        ?? ScheduleTab.weekSubtitle(monday))
    }
}

/// One week of the week pager.
/// A day for the week view to scroll to; a fresh id each time, so asking
/// twice scrolls twice.
struct WeekFocus: Equatable {
    let date: String
    let id = UUID()
}

private struct WeekPage: View {
    @Environment(LectioSession.self) private var session
    let monday: String
    let bottomInset: CGFloat
    let barLine: CGFloat
    var focus: WeekFocus? = nil
    var onPick: (String) -> Void
    @State private var pageBottom: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onChange(of: focus, initial: true) { _, focus in
                    guard let focus else { return }
                    // After the page has settled from the swipe to it.
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        withAnimation(.snappy) { proxy.scrollTo(WeekAgenda.cardID(focus.date), anchor: .top) }
                    }
                }
        }
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 10) {
                WeekHeading(week: session.snapshot.weeks[LectioDates.weekCode(iso: monday)],
                            monday: monday,
                            className: session.snapshot.profile.className,
                            dayEnd: ScheduleWeek.rememberedDayEnd)
                    .equatable()
                    .padding(.horizontal, Metrics.margin)
                WeekOverview(weekCode: LectioDates.weekCode(iso: monday), monday: monday, onPick: onPick)
            }
            .padding(.top, 8)
            .padding(.bottom, barClearance(pageBottom: pageBottom, barLine: barLine,
                                           atLeast: bottomInset) + 24)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .global).maxY.rounded()
        } action: { bottom in
            pageBottom = bottom
        }
        .scrollIndicators(.hidden)
        .refreshable { await Task { await session.refresh() }.value }
    }
}

// MARK: - Week overview (calendar button)

/// The week behind the calendar button: a card per day (see WeekAgenda),
/// or the loading state while it's fetched.
struct WeekOverview: View {
    @Environment(LectioSession.self) private var session
    let weekCode: String
    let monday: String
    var onPick: (String) -> Void

    var body: some View {
        Group {
            if let week = session.snapshot.weeks[weekCode] {
                WeekAgenda(week: week,
                           monday: monday,
                           className: session.snapshot.profile.className,
                           onPick: onPick)
                    .equatable()
            } else {
                WeekPlaceholder(weekCode: weekCode)
            }
        }
        .padding(.horizontal, Metrics.margin)
    }
}


// MARK: - Loading

/// Shown while a week is still being fetched — and, if the fetch failed, as a
/// retry instead of a spinner that would otherwise never stop.
struct WeekPlaceholder: View {
    @Environment(LectioSession.self) private var session
    let weekCode: String

    var body: some View {
        Group {
            if session.failedWeeks.contains(weekCode) {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .scaledFont(size: 26, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load this week")
                        .scaledFont(size: 16.5, weight: .semibold)
                    if let why = session.weekErrors[weekCode] {
                        Text(why)
                            .scaledFont(size: 13.5)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    Button("Try again") { session.retryWeek(weekCode) }
                        .scaledFont(size: 15.5, weight: .semibold)
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
