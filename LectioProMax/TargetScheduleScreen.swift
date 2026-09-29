import SwiftUI

/// Somebody else's timetable — a student's, a teacher's, a class's, a
/// team's or a room's — the way your own looks: a page per day with the
/// same lesson cards, colours and "min left" bar, swiped sideways with the
/// system's own paging, and the week a tap away (the calendar button).
///
/// Their name and what they are sit small in the bar; the star pins them
/// to the top of Find a schedule. A class also has its students there.
///
/// The weeks are fetched as you go (the one on screen, then either side)
/// and kept while the screen is open; nothing of theirs is saved.
struct TargetScheduleScreen: View {
    let target: ScheduleTarget

    @Environment(LectioSession.self) private var session

    @State private var loadedWeeks: [String: ScheduleWeek] = [:]
    @State private var failedWeeks: Set<String> = []
    @State private var selectedDate: String = LectioDates.isoString(from: Date())
    /// Where each pager rests: a swipe writes it, and writing it jumps.
    @State private var dayPage: String? = LectioDates.isoString(from: Date())
    @State private var weekPage: String? = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
    @State private var weekMode = false
    @State private var opener = LessonOpener()
    @State private var openLesson: LessonRoute?

    private var memory: FindMemory { .shared }

    /// Four months either side of today; the pages are lazy.
    private static let pageDays: [String] = {
        let today = LectioDates.isoString(from: Date())
        return (-120...120).map { LectioDates.shift(iso: today, byDays: $0) }
    }()

    private static let pageMondays: [String] = {
        let monday = ScheduleTab.monday(of: LectioDates.isoString(from: Date()))
        return (-17...17).map { LectioDates.shift(iso: monday, byDays: $0 * 7) }
    }()

    private var today: String { LectioDates.isoString(from: Date()) }

    /// What the cards leave out or add for whose schedule it is.
    private var owner: ScheduleOwner {
        switch target.kind {
        case .teacher: return .teacher
        case .room: return .room
        default: return .others
        }
    }

    private var classmates: [ScheduleTarget] {
        guard target.kind == .klasse else { return [] }
        return session.scheduleTargets.filter {
            $0.studentClass?.caseInsensitiveCompare(target.name) == .orderedSame
        }
    }

    var body: some View {
        ZStack {
            if weekMode {
                ScrollViewReader { proxy in weekPager(proxy) }
                    .transition(.opacity)
            } else {
                ScrollViewReader { proxy in dayPager(proxy) }
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: weekMode)
        .background { AppBackground() }
        .navigationTitle(target.displayName)
        .navigationSubtitle(target.kindLine)
        .toolbarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sensoryFeedback(.selection, trigger: weekMode)
        // The cards open a lesson through a LessonOpener, as in your own
        // schedule; here it's pushed onto the stack this screen is in.
        .environment(opener)
        .environment(\.scheduleOwner, owner)
        .onChange(of: opener.path) { _, path in
            guard let route = path.last else { return }
            openLesson = route
            opener.path = []
        }
        .navigationDestination(item: $openLesson) { route in
            LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
        }
        .onChange(of: dayPage) { _, page in
            // A swipe landed on another day.
            guard let page, page != selectedDate else { return }
            selectedDate = page
            weekPage = ScheduleTab.monday(of: page)
        }
        .onChange(of: weekPage) { _, monday in
            // A swipe landed on another week: same weekday, new week.
            guard let monday, monday != ScheduleTab.monday(of: selectedDate) else { return }
            let moved = LectioDates.shift(iso: monday, byDays: ScheduleTab.weekdayIndex(selectedDate))
            selectedDate = moved
            dayPage = moved
        }
        .task(id: LectioDates.weekCode(iso: selectedDate)) {
            await loadAround(selectedDate)
        }
        .onAppear { memory.noteOpened(target) }
        // Their class was the one the cards were read by (see DayPlan);
        // everything else in the app goes by yours.
        .onDisappear { ClassNames.use(session.snapshot.profile) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // As in your own schedule: only when it would take you somewhere.
            if weekMode ? (weekPage != ScheduleTab.monday(of: today)) : (selectedDate != today) {
                Button("Today") { jumpToToday() }
                    .fontWeight(.semibold)
            }
            Button {
                weekMode.toggle()
            } label: {
                Label(weekMode ? "Day view" : "Week view",
                      systemImage: weekMode ? "rectangle.grid.1x2" : "calendar")
            }
            if !classmates.isEmpty {
                NavigationLink(value: FindBrowse.classmates(target)) {
                    Label("Students", systemImage: "person.3")
                }
            }
            Button {
                memory.togglePin(target)
            } label: {
                Label(memory.isPinned(target) ? "Unpin" : "Pin",
                      systemImage: memory.isPinned(target) ? "star.fill" : "star")
            }
        }
    }

    // MARK: Pagers

    private func dayPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.pageDays, id: \.self) { date in
                    let code = LectioDates.weekCode(iso: date)
                    TargetDayPage(date: date,
                                  week: loadedWeeks[code],
                                  failed: failedWeeks.contains(code),
                                  className: target.scheduleClass,
                                  retry: { retry(code) },
                                  reload: { await load(code) })
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
                ForEach(Self.pageMondays, id: \.self) { monday in
                    let code = LectioDates.weekCode(iso: monday)
                    TargetWeekPage(monday: monday,
                                   week: loadedWeeks[code],
                                   failed: failedWeeks.contains(code),
                                   className: target.scheduleClass,
                                   retry: { retry(code) },
                                   reload: { await load(code) }) { date in
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
        .onAppear { align(proxy, on: ScheduleTab.monday(of: selectedDate)) }
        .onScrollPhaseChange { _, phase, _ in
            if phase == .idle {
                align(proxy, on: weekPage ?? ScheduleTab.monday(of: selectedDate), animated: true)
            }
        }
    }

    /// Makes sure a pager rests squarely on a page (see ScheduleTab.align).
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

    /// A day tapped in the week view: that day, in the day view.
    private func pick(_ date: String) {
        selectedDate = date
        dayPage = date
        weekPage = ScheduleTab.monday(of: date)
        weekMode = false
    }

    private func jumpToToday() {
        let day = today
        withAnimation(.smooth) {
            selectedDate = day
            dayPage = day
            weekPage = ScheduleTab.monday(of: day)
        }
    }

    // MARK: Loading

    /// The week on screen first, then the weeks either side, ready for a
    /// swipe.
    private func loadAround(_ date: String) async {
        let codes = [0, 7, -7].map { LectioDates.weekCode(iso: LectioDates.shift(iso: date, byDays: $0)) }
        for code in codes where loadedWeeks[code] == nil {
            guard !Task.isCancelled else { return }
            await load(code)
        }
    }

    private func load(_ code: String) async {
        let cookies = await session.requestCookies()
        guard !cookies.isEmpty else {
            failedWeeks.insert(code)
            return
        }
        do {
            let week = try await LectioStudyService.loadWeek(for: target, weekCode: code, cookies: cookies)
            loadedWeeks[code] = week
            failedWeeks.remove(code)
        } catch {
            // Swiping on cancels a fetch; that isn't a failure.
            if !Task.isCancelled { failedWeeks.insert(code) }
        }
    }

    private func retry(_ code: String) {
        failedWeeks.remove(code)
        Task { await load(code) }
    }
}

/// Whose schedule the lesson cards are on (see TargetScheduleScreen). A
/// teacher's cards name the class instead of the teacher, who is the same
/// on every one; a room's name the class and the teacher, and leave the
/// room out.
enum ScheduleOwner {
    case me, others, teacher, room
}

extension EnvironmentValues {
    @Entry var scheduleOwner: ScheduleOwner = .me
}

extension Lesson {
    /// The classes a lesson is for, from its team: "1j", or "1i, 1j" for a
    /// shared one.
    var classesLabel: String {
        var classes: [String] = []
        for part in (team ?? "").split(separator: ",") {
            let first = part.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            guard first.first?.isNumber == true, !classes.contains(first) else { continue }
            classes.append(first)
        }
        return LessonText.abbreviated(classes.joined(separator: ", "))
    }
}

// MARK: - A day

/// One day of their pager: its own scroll view, as in your schedule, with
/// the heading, the day's cards (DayList) and pull to refresh.
private struct TargetDayPage: View {
    let date: String
    let week: ScheduleWeek?
    let failed: Bool
    let className: String
    var retry: @MainActor () -> Void
    var reload: @MainActor () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(title: ScheduleTab.dayTitle(date),
                            subtitle: ScheduleTab.daySubtitle(date))
                if let week {
                    DayList(day: week.days.first { $0.date == date },
                            // Their week's modules, without making their
                            // school day yours (see schoolDayModules).
                            modules: week.schoolDayModules(remembering: false),
                            className: className,
                            rolling: week.rollingNotes(className: className))
                        .equatable()
                } else {
                    TargetWeekPlaceholder(failed: failed, retry: retry)
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 32)
            // No row may make the page wider than the screen: the pager
            // would take the drag (see pageWide, SCROLL_BUG.md).
            .pageWide()
        }
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
    }
}

// MARK: - A week

private struct TargetWeekPage: View {
    let monday: String
    let week: ScheduleWeek?
    let failed: Bool
    let className: String
    var retry: @MainActor () -> Void
    var reload: @MainActor () async -> Void
    var onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(title: ScheduleTab.weekTitle(monday),
                            subtitle: WeekAgenda.subtitle(week: week, monday: monday,
                                                          className: className, remembering: false)
                                ?? ScheduleTab.weekSubtitle(monday))
                if let week {
                    WeekAgenda(week: week,
                               monday: monday,
                               className: className,
                               remembersDayEnd: false,
                               onPick: onPick)
                        .equatable()
                } else {
                    TargetWeekPlaceholder(failed: failed, retry: retry)
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .pageWide()
        }
        .scrollIndicators(.hidden)
        .refreshable { await reload() }
    }
}

/// While their week is on its way, or a retry if it didn't come.
private struct TargetWeekPlaceholder: View {
    let failed: Bool
    var retry: @MainActor () -> Void

    var body: some View {
        if failed {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .scaledFont(size: 26, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text("Couldn't load this week")
                    .scaledFont(size: 16.5, weight: .semibold)
                Button("Try again", action: retry)
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
