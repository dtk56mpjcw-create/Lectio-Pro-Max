import SwiftUI

/// The search button at the end of the tab bar, searching the tab you came
/// from:
///
/// - Schedule: everything schedule — anyone's schedule (students,
///   teachers, classes, teams, rooms) and your own lessons, their topics,
///   homework and notes, in the weeks the app has loaded;
/// - Homework: your homework and assignments;
/// - Messages: your messages;
/// - Me: your absence, grades and study plan, and the Me pages.
///
/// One search field, in the tab bar where iOS 26 puts it, and no other
/// search bars in the app: the ones in Messages and Find a schedule flashed
/// as a screen slid in and could stick half-way. (It used to search
/// everything at once; searching the tab you're on is what you expect.)
///
/// The field belongs to this tab: `.searchable` is attached to it in
/// RootView (on the TabView it reached every tab's navigation bar). It
/// searches what the app already holds, so it's instant and works offline;
/// only the list of every team at school is fetched, the first time you
/// search schedules (TeamDirectory).
struct SearchTab: View {
    let query: String
    /// The tab the search is for.
    let context: AppTab

    @Environment(LectioSession.self) private var session
    @State private var path = NavigationPath()
    @State private var openWork: WorkItem?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            results
                .background { AppBackground() }
                .navigationTitle(context.searchTitle)
                .navigationDestination(for: ScheduleTarget.self) { target in
                    TargetScheduleScreen(target: target)
                }
                .navigationDestination(for: FindBrowse.self) { browse in
                    FindBrowseScreen(browse: browse)
                }
                .navigationDestination(for: LessonRoute.self) { route in
                    LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
                }
                .navigationDestination(for: MessageThreadSummary.self) { thread in
                    MessageThreadSheet(summary: thread).asPushedScreen()
                }
                .navigationDestination(for: MeRoute.self) { route in
                    MeSearchDestination(route: route)
                }
        }
        // Another tab's search starts from the top.
        .onChange(of: context) { path = NavigationPath() }
        .sheet(item: $openWork) { item in
            // As the Homework tab opens it: an assignment on its hand-in
            // page, homework on its own.
            if item.isAssignment, let link = item.link {
                AssignmentHandInSheet(item: item, link: link,
                                      done: session.snapshot.isCompleted(item),
                                      toggle: { session.toggleCompleted(item) })
                    .environment(session)
            } else {
                WorkDetailSheet(item: item,
                                done: session.snapshot.isCompleted(item),
                                toggle: { session.toggleCompleted(item) })
                    .environment(session)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch context {
        case .schedule, .search:
            ScheduleSearch(query: trimmed)
        case .homework:
            HomeworkSearch(query: trimmed) { openWork = $0 }
        case .messages:
            MessageSearch(query: trimmed)
        case .me:
            MeSearch(query: trimmed)
        }
    }
}

extension AppTab {
    /// What the search field says, from this tab.
    var searchPrompt: String {
        switch self {
        case .schedule, .search: return "People, classes, rooms, lessons"
        case .homework: return "Homework and assignments"
        case .messages: return "Messages"
        case .me: return "Absence, grades, study plan"
        }
    }

    /// The search screen's title, from this tab.
    var searchTitle: String {
        switch self {
        case .schedule, .search: return "Search Schedule"
        case .homework: return "Search Homework"
        case .messages: return "Search Messages"
        case .me: return "Search Me"
        }
    }
}

extension View {
    /// The tabs' own gray (AppBackground, behind SearchTab) shows through
    /// a search's list, instead of whatever the list draws. Search Me was
    /// plain white before you typed. Most likely because its list then has
    /// no section at all: Homework's and Messages' always have one, even
    /// empty, and were gray; Schedule's has none only with nothing pinned
    /// or recent.
    fileprivate func searchListBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}

// MARK: - Which search

/// Which search the search button opens from a tab: the tab's own, unless
/// the screen on show belongs to another. Me › Find a schedule, its lists
/// and someone's schedule are in the Me tab but are Schedule's; to Dan
/// they *are* the schedule, and searching there said "Search Me".
///
/// A screen says whose it is with `.searchedAs(_:)`. One that doesn't
/// say is part of the one it was opened from (a lesson in someone's
/// schedule, a page under Me), so it keeps that one's.
///
/// Kept from the screens' own appearing and disappearing, which can come
/// in either order as one screen replaces another, and half-way for a swipe
/// back that's let go. So it's the last screen to appear that's still on
/// show. Leaving the tab takes all of them off; then it's the one that was
/// on show last, which is where you were.
@MainActor
final class SearchContexts {
    static let shared = SearchContexts()

    private struct Shown {
        let id: UUID
        let context: AppTab
    }

    /// Per tab, its screens on show that said whose they are, in the order
    /// they appeared.
    private var shown: [AppTab: [Shown]] = [:]
    /// Per tab, the search of the last of them.
    private var latest: [AppTab: AppTab] = [:]

    /// What the search button searches from `tab`.
    func context(for tab: AppTab) -> AppTab {
        latest[tab] ?? tab
    }

    func appeared(_ id: UUID, context: AppTab, in tab: AppTab) {
        shown[tab, default: []].removeAll { $0.id == id }
        shown[tab, default: []].append(Shown(id: id, context: context))
        latest[tab] = context
    }

    func disappeared(_ id: UUID, in tab: AppTab) {
        shown[tab, default: []].removeAll { $0.id == id }
        if let top = shown[tab]?.last { latest[tab] = top.context }
    }
}

extension EnvironmentValues {
    /// The tab a screen is in; nil in the search tab and outside the tabs.
    @Entry var hostTab: AppTab? = nil
}

private struct SearchContextMark: ViewModifier {
    let context: AppTab
    @Environment(\.hostTab) private var hostTab
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let hostTab else { return }
                SearchContexts.shared.appeared(id, context: context, in: hostTab)
            }
            .onDisappear {
                guard let hostTab else { return }
                SearchContexts.shared.disappeared(id, in: hostTab)
            }
    }
}

extension View {
    /// The search button searches `context` from this screen, whichever
    /// tab it's in (see SearchContexts). Goes on a screen's content, inside
    /// its navigation stack, so it hears the screen come back into view.
    func searchedAs(_ context: AppTab) -> some View {
        modifier(SearchContextMark(context: context))
    }
}

/// Whether `text` has `needle` in it, whatever the case or accents ("e"
/// finds "é"; ø, æ and å stay letters of their own, as in Danish).
private func textHas(_ text: String, _ needle: String) -> Bool {
    text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

// MARK: - Schedule

/// Anyone's schedule, then your own lessons. Before you type: the ones you
/// pinned and the last few you opened.
private struct ScheduleSearch: View {
    let query: String
    @Environment(LectioSession.self) private var session
    private var memory: FindMemory { .shared }
    private var directory: TeamDirectory { .shared }

    /// Everyone and everything with a schedule — every team at school once
    /// fetched (your own are among the targets already).
    private var pool: [ScheduleTarget] {
        let targets = session.scheduleTargets
        let known = Set(targets.map(\.id))
        return targets + directory.allTeams.filter { !known.contains($0.id) }
    }

    /// Your lessons that have it in their name, topic, teacher, room,
    /// homework or note: from today on first, then the ones before.
    private var lessons: [LessonRoute] {
        var hits: [LessonRoute] = []
        for week in session.snapshot.weeks.values {
            for day in week.days {
                for lesson in day.lessons {
                    let haystack = [lesson.title, lesson.code, lesson.topic ?? "", lesson.teacher,
                                    lesson.room, lesson.homework, lesson.note]
                        .joined(separator: " ")
                    if textHas(haystack, query) {
                        hits.append(LessonRoute(lesson: lesson, dayISO: day.date))
                    }
                }
            }
        }
        let today = LectioDates.isoString(from: Date())
        let ahead = hits.filter { $0.dayISO >= today }.sorted { $0.dayISO < $1.dayISO }
        let before = hits.filter { $0.dayISO < today }.sorted { $0.dayISO > $1.dayISO }
        return ahead + before
    }

    var body: some View {
        let sections = query.isEmpty ? [] : TargetSection.search(query, in: pool)
        let lessons = query.count >= 2 ? self.lessons : []

        List {
            if query.isEmpty {
                PinnedAndRecent()
            } else {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.targets.prefix(TargetSection.perKind)) { target in
                            NavigationLink(value: target) { TargetRow(target: target, highlight: query) }
                        }
                        if section.targets.count > TargetSection.perKind {
                            Text("\(section.targets.count - TargetSection.perKind) more — type more of the name")
                                .scaledFont(size: 14)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !lessons.isEmpty {
                    Section("Your lessons") {
                        ForEach(lessons.prefix(40), id: \.key) { route in
                            NavigationLink(value: route) { LessonResultRow(route: route) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchListBackground()
        .overlay {
            if query.isEmpty {
                if memory.pinned.isEmpty && memory.recent.isEmpty {
                    ContentUnavailableView("Search Schedule", systemImage: "calendar",
                                           description: Text("Anyone's schedule — students, teachers, classes, teams, rooms — and your own lessons."))
                }
            } else if sections.isEmpty && lessons.isEmpty {
                if session.scheduleTargets.isEmpty {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .task { await session.loadScheduleTargets() }
        .onAppear { memory.prepare() }
        .onChange(of: query.isEmpty, initial: true) { _, empty in
            // Every team at school, fetched the first time you type (and
            // kept for a week; see TeamDirectory).
            guard !empty else { return }
            Task {
                let cookies = await session.requestCookies()
                await directory.loadAll(cookies: cookies)
            }
        }
    }
}

/// A lesson found: its subject's colour, its name and topic, and when.
private struct LessonResultRow: View {
    let route: LessonRoute

    var body: some View {
        let lesson = route.lesson
        HStack(spacing: 12) {
            Circle()
                .fill(lesson.isClassLesson ? Color.forSubject(lesson.subjectCode) : Color(.systemGray3))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(lesson.topic.map { lesson.headline + " · " + LectioDates.tidy($0) } ?? lesson.headline)
                    .scaledFont(size: 16)
                    .lineLimit(2)
                Text(LectioDates.dayLabel(iso: route.dayISO)
                     + (lesson.start.isEmpty ? "" : " · " + lesson.start)
                     + (lesson.room.isEmpty ? "" : " · " + LessonText.abbreviated(lesson.room)))
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Homework

private struct HomeworkSearch: View {
    let query: String
    var open: (WorkItem) -> Void
    @Environment(LectioSession.self) private var session

    private var hits: [WorkItem] {
        session.snapshot.workItems.filter { item in
            let subject = SubjectPalette.subjectKey(item.code).flatMap(SubjectNames.knownName(forKey:)) ?? ""
            return textHas([item.title, item.code, item.text, subject].joined(separator: " "), query)
        }
    }

    var body: some View {
        let hits = query.isEmpty ? [] : self.hits
        List {
            ForEach(hits) { item in
                Button { open(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.isAssignment ? "tray.and.arrow.up" : "book.closed")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(Color.forSubject(item.code))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayTitle)
                                .scaledFont(size: 16)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text([LessonText.abbreviated(item.code).uppercased(),
                                  item.due.map { "Due " + LectioDates.friendlyLabel(iso: $0) } ?? "",
                                  session.snapshot.isCompleted(item) ? "Done" : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .scaledFont(size: 13)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchListBackground()
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Homework", systemImage: "checklist",
                                       description: Text("Homework and assignments, by what to do, title or subject."))
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - Messages

private struct MessageSearch: View {
    let query: String
    @Environment(LectioSession.self) private var session

    private var hits: [MessageThreadSummary] {
        session.threads.filter { thread in
            [thread.subject, thread.latestSender, thread.firstSender, thread.recipients]
                .contains { textHas($0, query) }
        }
    }

    var body: some View {
        let hits = query.isEmpty ? [] : self.hits
        List {
            ForEach(hits) { thread in
                NavigationLink(value: thread) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(thread.latestSender)
                                .scaledFont(size: 16, weight: thread.unread ? .semibold : .regular)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(thread.changed)
                                .scaledFont(size: 13)
                                .foregroundStyle(.secondary)
                        }
                        Text(thread.subject)
                            .scaledFont(size: 14.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchListBackground()
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Messages", systemImage: "envelope",
                                       description: Text("By subject, sender or who it was sent to."))
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task { await session.loadInbox() }
    }
}

// MARK: - Me

/// Your absence (subjects and each absence), grades, study plan, and the
/// Me pages by name. A result opens its page.
private struct MeSearch: View {
    let query: String
    @Environment(LectioSession.self) private var session

    private struct Hit: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let route: MeRoute
    }

    /// "Maths" for "1j ma", so a search in English finds Lectio's teams.
    private func subjectName(_ code: String) -> String {
        SubjectPalette.subjectKey(code).flatMap(SubjectNames.knownName(forKey:)) ?? ""
    }

    private var pages: [Hit] {
        let all: [(String, String, MeRoute)] = [
            ("Absence", "chart.pie", .absence),
            ("Grades", "graduationcap", .grades),
            ("Study plan", "clock", .studyPlan),
            ("Find a schedule", "person.crop.rectangle.stack", .findSchedule),
            ("Settings", "gearshape", .settings),
            ("Subject colours", "paintpalette", .subjectColors),
            ("Message signature", "signature", .signature),
        ]
        return all.filter { textHas($0.0, query) }
            .map { Hit(id: "page|" + $0.0, title: $0.0, detail: "", icon: $0.1, route: $0.2) }
    }

    private var absence: [Hit] {
        let data = session.absence
        let subjects = data.subjects.filter {
            !$0.isTotal && (textHas($0.code, query) || textHas(subjectName($0.code), query))
        }.map {
            Hit(id: "as|" + $0.code, title: AbsenceWording.subject($0.code),
                detail: [$0.percent, $0.modules.isEmpty ? "" : $0.modules + " modules"]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                icon: "chart.pie", route: .absence)
        }
        let records = data.records.filter {
            textHas([$0.code, subjectName($0.code), $0.teacher, AbsenceWording.reason($0.reason),
                     $0.comment, LectioDates.dayLabel(iso: $0.date)].joined(separator: " "), query)
        }.prefix(20).map {
            Hit(id: "ar|" + $0.id, title: $0.whenLine,
                detail: [$0.code.uppercased(), $0.needsReason ? "Needs a reason" : AbsenceWording.reason($0.reason)]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                icon: $0.needsReason ? "exclamationmark.circle" : "calendar.badge.minus", route: .absence)
        }
        return subjects + records
    }

    private var grades: [Hit] {
        (session.grades?.rows ?? []).filter {
            textHas($0.team, query) || textHas($0.subject, query) || textHas(subjectName($0.team), query)
        }.map {
            Hit(id: "g|" + $0.id, title: $0.subject.isEmpty ? $0.team : $0.subject,
                detail: [$0.team, $0.latest.map { "Latest " + $0.grade } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                icon: "graduationcap", route: .grades)
        }
    }

    private var studyPlan: [Hit] {
        var out: [Hit] = []
        for subject in session.studyPlan ?? [] {
            if textHas(subject.name, query) || textHas(subjectName(subject.name), query) {
                out.append(Hit(id: "s|" + subject.id, title: subject.name,
                               detail: "\(subject.phases.count) units", icon: "clock", route: .studyPlan))
            }
            for phase in subject.phases where textHas(phase.title, query) {
                out.append(Hit(id: "p|" + subject.id + "|" + phase.id, title: phase.title,
                               detail: [subject.name, phase.period].filter { !$0.isEmpty }.joined(separator: " · "),
                               icon: "clock", route: .studyPlan))
            }
        }
        return out
    }

    var body: some View {
        let groups: [(String, [Hit])] = query.isEmpty ? [] : [
            ("Pages", pages), ("Absence", absence), ("Grades", grades), ("Study plan", studyPlan),
        ].filter { !$0.1.isEmpty }

        List {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { hit in
                        NavigationLink(value: hit.route) {
                            HStack(spacing: 12) {
                                Image(systemName: hit.icon)
                                    .scaledFont(size: 15, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.title)
                                        .scaledFont(size: 16)
                                        .lineLimit(2)
                                    if !hit.detail.isEmpty {
                                        Text(hit.detail)
                                            .scaledFont(size: 13)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchListBackground()
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Me", systemImage: "person.crop.circle",
                                       description: Text("Your absence, grades and study plan."))
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task {
            async let absence: () = session.loadAbsence()
            async let grades: () = session.loadGrades()
            async let plan: () = session.loadStudyPlan()
            _ = await (absence, grades, plan)
        }
    }
}

/// Where a Me result opens: the page it's on, as Me opens it.
private struct MeSearchDestination: View {
    let route: MeRoute

    var body: some View {
        switch route {
        case .absence: AbsenceSheet().asPushedScreen()
        case .grades: GradesScreen().toolbarTitleDisplayMode(.inline)
        case .studyPlan: StudyPlanSheet().asPushedScreen()
        case .findSchedule: FindScheduleScreen()
        case .settings: SettingsScreen().toolbarTitleDisplayMode(.inline)
        case .subjectColors: SubjectColorsScreen().toolbarTitleDisplayMode(.inline)
        case .signature: SignatureScreen().toolbarTitleDisplayMode(.inline)
        }
    }
}
