import SwiftUI

// MARK: - Find a schedule

/// Me › Find a schedule: the schedules you pinned and the ones you looked
/// at lately, and everything to browse by kind — students, teachers,
/// classes, teams, rooms. Built from the system's own pieces, as Contacts
/// and Settings are: a list, and the letter index down the side of a long
/// one. Their timetable then looks like yours (TargetScheduleScreen).
///
/// No search bar of its own: the search button in the tab bar searches the
/// tab you're on, and from Schedule it finds anyone's schedule
/// (SearchTab). The search bars on pushed screens flashed as they slid in
/// and could stick half-way.
struct FindScheduleScreen: View {
    @Environment(LectioSession.self) private var session
    private var memory: FindMemory { .shared }

    private var ownClass: String {
        session.snapshot.profile.className.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        List {
            PinnedAndRecent()

            Section("Browse") {
                NavigationLink(value: FindBrowse.kind(.student)) {
                    BrowseRow(title: "Students", icon: "person.fill", tint: .blue)
                }
                NavigationLink(value: FindBrowse.kind(.teacher)) {
                    BrowseRow(title: "Teachers", icon: "person.crop.rectangle.fill", tint: .orange)
                }
                NavigationLink(value: FindBrowse.kind(.klasse)) {
                    BrowseRow(title: "Classes", icon: "person.3.fill", tint: .green,
                              detail: ownClass.isEmpty ? nil : "Yours: " + ownClass)
                }
                NavigationLink(value: FindBrowse.teams) {
                    BrowseRow(title: "Teams", icon: "book.closed.fill", tint: .purple, detail: "Yours first")
                }
                NavigationLink(value: FindBrowse.kind(.room)) {
                    BrowseRow(title: "Rooms", icon: "door.left.hand.open", tint: .gray)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Find a schedule")
        .toolbarTitleDisplayMode(.large)
        .task { await session.loadScheduleTargets() }
        .onAppear { memory.prepare() }
        // Everything this screen leads to, however deep: someone's schedule,
        // and the lists to browse. It's in Me, but searching here is for a
        // schedule: the search button finds anyone's, from here (see
        // MeTab) and from the lists and schedules it opens.
        .navigationDestination(for: ScheduleTarget.self) { target in
            TargetScheduleScreen(target: target)
                .searchPage(.findSchedule)
        }
        .navigationDestination(for: FindBrowse.self) { browse in
            FindBrowseScreen(browse: browse)
                .searchPage(.findSchedule)
        }
    }
}

/// The pinned schedules, then the last few opened, on the Find page.
struct PinnedAndRecent: View {
    private var memory: FindMemory { .shared }

    var body: some View {
        let pinned = memory.pinned
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { target in
                    NavigationLink(value: target) { TargetRow(target: target) }
                        .swipeActions {
                            Button("Unpin") { memory.togglePin(target) }
                                .tint(.orange)
                        }
                }
            }
        }

        let recent = memory.recent.filter { !memory.isPinned($0) }
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { target in
                    NavigationLink(value: target) { TargetRow(target: target) }
                        .swipeActions {
                            Button("Remove", role: .destructive) { memory.forget(target) }
                        }
                }
            }
        }
    }
}

/// A list section of schedules to open.
struct TargetSection: Identifiable {
    let id: String
    let title: String
    let targets: [ScheduleTarget]

    /// At most this many per kind in a search: "an" matches half the school.
    static let perKind = 40

    /// A search: the matches grouped by kind in a fixed order, the ones
    /// where a word starts with what was typed first.
    static func search(_ needle: String, in pool: [ScheduleTarget]) -> [TargetSection] {
        guard !needle.isEmpty else { return [] }
        let order: [ScheduleTarget.Kind] = [.student, .teacher, .klasse, .subject, .room]
        return order.compactMap { kind -> TargetSection? in
            let hits = pool
                .filter { $0.kind == kind && $0.matches(needle) }
                .sorted { a, b in
                    let wordA = a.startsWord(needle), wordB = b.startsWord(needle)
                    if wordA != wordB { return wordA }
                    return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
                }
            return hits.isEmpty ? nil : TargetSection(id: kind.rawValue, title: kind.label, targets: hits)
        }
    }
}

// MARK: - Browsing

/// The lists behind Browse, and behind a class's Students button.
enum FindBrowse: Hashable {
    /// Every student, teacher, class or room.
    case kind(ScheduleTarget.Kind)
    /// Your own teams, then every subject's.
    case teams
    /// One subject's teams.
    case teamSubject(TeamSubject)
    /// The students of a class.
    case classmates(ScheduleTarget)
}

struct FindBrowseScreen: View {
    let browse: FindBrowse
    @Environment(LectioSession.self) private var session

    var body: some View {
        switch browse {
        case .kind(let kind):
            TargetListScreen(kind: kind, title: kind.label)
        case .teams:
            TeamsScreen()
        case .teamSubject(let subject):
            TeamSubjectScreen(subject: subject)
        case .classmates(let klasse):
            TargetListScreen(kind: .student, title: "Students in " + klasse.name, onlyClass: klasse.name)
        }
    }
}

/// A row of Browse: an icon on a coloured tile, as in Settings.
private struct BrowseRow: View {
    let title: String
    let icon: String
    let tint: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 14.5, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .scaledFont(size: 17)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .scaledFont(size: 17)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Every student, teacher, class or room — or one class's students — as a
/// plain list. People get the letter index down the side that Contacts has;
/// classes are grouped by year. (Searching is the tab bar's, from Schedule.)
struct TargetListScreen: View {
    let kind: ScheduleTarget.Kind
    let title: String
    /// Only this class's students.
    var onlyClass: String? = nil

    @Environment(LectioSession.self) private var session

    private var all: [ScheduleTarget] {
        session.scheduleTargets.filter { target in
            guard target.kind == kind else { return false }
            guard let onlyClass else { return true }
            return target.studentClass?.caseInsensitiveCompare(onlyClass) == .orderedSame
        }
    }

    private var shown: [ScheduleTarget] {
        all.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var showsIndex: Bool { kind == .student || kind == .teacher }

    private var sections: [TargetSection] {
        let list = shown
        guard !list.isEmpty else { return [] }
        switch kind {
        case .student, .teacher:
            return Self.grouped(list) { $0.indexLetter }
        case .klasse:
            return Self.grouped(list) { target in
                let year = String(target.name.prefix { $0.isNumber })
                return year.isEmpty ? "Other" : "Year " + year
            }
        case .room, .subject:
            return [TargetSection(id: "", title: "", targets: list)]
        }
    }

    /// In the order the list is sorted in, so Æ, Ø and Å come after Z on a
    /// Danish phone.
    static func grouped(_ list: [ScheduleTarget], by key: (ScheduleTarget) -> String) -> [TargetSection] {
        var order: [String] = []
        var buckets: [String: [ScheduleTarget]] = [:]
        for target in list {
            let k = key(target)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(target)
        }
        return order.map { TargetSection(id: $0, title: $0, targets: buckets[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.targets) { target in
                        NavigationLink(value: target) {
                            TargetRow(target: target, compact: true)
                        }
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                }
                .sectionIndexLabel(section.id)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionIndexVisibility(showsIndex ? .visible : .hidden)
        .overlay {
            if session.scheduleTargets.isEmpty {
                ProgressView()
            } else if shown.isEmpty {
                ContentUnavailableView("Nobody here", systemImage: kind.icon)
            }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .task { await session.loadScheduleTargets() }
    }
}

/// Teams: your own first, then every subject, each opening its teams — the
/// way Lectio lists them (FindSkema's Hold page lists subjects, and each
/// subject its teams).
struct TeamsScreen: View {
    @Environment(LectioSession.self) private var session
    private var directory: TeamDirectory { .shared }

    private var yours: [ScheduleTarget] {
        session.scheduleTargets
            .filter { $0.kind == .subject }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List {
            if !yours.isEmpty {
                Section("Yours") {
                    ForEach(yours) { team in
                        NavigationLink(value: team) { TargetRow(target: team) }
                    }
                }
            }
            if !directory.subjects.isEmpty {
                Section("By subject") {
                    ForEach(directory.subjects) { subject in
                        NavigationLink(value: FindBrowse.teamSubject(subject)) {
                            HStack(spacing: 12) {
                                SubjectTile(code: subject.code, size: 30)
                                Text(subject.displayName)
                                    .scaledFont(size: 17)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(subject.code)
                                    .scaledFont(size: 15)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if directory.subjectsFailed {
                Section {
                    Button("Couldn't load the subjects — try again") { load() }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Teams")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await session.loadScheduleTargets()
            let cookies = await session.requestCookies()
            await directory.loadSubjects(cookies: cookies)
        }
    }

    private func load() {
        Task {
            let cookies = await session.requestCookies()
            await directory.loadSubjects(cookies: cookies)
        }
    }
}

/// One subject's teams: "1a Ma", "1b Ma", …
struct TeamSubjectScreen: View {
    let subject: TeamSubject
    @Environment(LectioSession.self) private var session
    private var directory: TeamDirectory { .shared }

    private var teams: [ScheduleTarget]? {
        directory.teams(of: subject)?
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List {
            if let teams {
                ForEach(TargetListScreen.grouped(teams) { team in
                    let year = String(team.displayName.prefix { $0.isNumber })
                    return year.isEmpty ? "Other" : "Year " + year
                }) { section in
                    Section(section.title) {
                        ForEach(section.targets) { team in
                            NavigationLink(value: team) { TargetRow(target: team, compact: true) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if let teams {
                if teams.isEmpty {
                    ContentUnavailableView("No teams", systemImage: "book.closed",
                                           description: Text("Lectio lists no current teams in \(subject.displayName)."))
                }
            } else if directory.failedSubjects.contains(subject.id) {
                ContentUnavailableView {
                    Label("Couldn't load the teams", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Lectio didn't answer.")
                } actions: {
                    Button("Try again") { load() }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(subject.displayName)
        .toolbarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        Task {
            let cookies = await session.requestCookies()
            await directory.loadTeams(of: subject, cookies: cookies)
        }
    }
}

// MARK: - A row

/// Someone or something to open: a face (or initials) for people, a tile
/// for the rest; the name, with what you searched for in bold; and what it
/// is ("Student · 2y") — or, in a list of one kind (`compact`), just the
/// class or initials at the side.
struct TargetRow: View {
    let target: ScheduleTarget
    var highlight: String = ""
    var compact = false

    @Environment(LectioSession.self) private var session

    /// One of your own teams.
    private var isYours: Bool {
        target.kind == .subject
            && session.scheduleTargets.contains { $0.kind == .subject && $0.id == target.id }
    }

    private var name: AttributedString {
        var text = AttributedString(target.displayName)
        guard !highlight.isEmpty,
              let range = text.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive])
        else { return text }
        text[range].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    var body: some View {
        HStack(spacing: 12) {
            TargetIcon(target: target, size: compact ? 32 : 36)
            if compact {
                Text(name)
                    .scaledFont(size: 17)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let aside = isYours ? "Yours" : target.listAside {
                    Text(aside)
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .scaledFont(size: 17)
                        .lineLimit(1)
                    Text(isYours ? target.kindLine + " · yours" : target.kindLine)
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compact ? 0 : 2)
    }
}

/// A person's photo (or initials); for anything else a tile with its
/// symbol — a team's in its subject's colour.
struct TargetIcon: View {
    let target: ScheduleTarget
    var size: CGFloat = 36

    var body: some View {
        if target.contextCardID != nil {
            PersonAvatar(target: target, size: size)
        } else if target.kind == .subject {
            SubjectTile(code: target.name, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: target.kind.icon)
                        .scaledFont(size: size * 0.44, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}

/// A subject's colour on a tile, with a book on it.
struct SubjectTile: View {
    /// A subject code or a team ("MA", "1j ma").
    let code: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color.forSubject(code).opacity(0.2))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .scaledFont(size: size * 0.44, weight: .semibold)
                    .foregroundStyle(Color.forSubject(code))
            }
            .accessibilityHidden(true)
    }
}

// MARK: - What a target is called

extension ScheduleTarget {
    /// The name as it's shown: without Lectio's "(1u 01)" after a student
    /// or "(KL)" after a teacher.
    var displayName: String {
        guard kind == .student || kind == .teacher, name.hasSuffix(")"),
              let cut = name.range(of: " (", options: .backwards) else { return name }
        return String(name[..<cut.lowerBound])
    }

    /// A teacher's initials, from the brackets after the name.
    var teacherCode: String? {
        guard kind == .teacher, let g = Rx.match("\\(([^()]+)\\)\\s*$", name) else { return nil }
        let inside = g[1].trimmingCharacters(in: .whitespaces)
        return inside.isEmpty ? nil : inside
    }

    /// Under the name: "Student · 2y", "Teacher · KL", "Maths".
    var kindLine: String {
        switch kind {
        case .student: return ["Student", studentClass].compactMap { $0 }.joined(separator: " · ")
        case .teacher: return ["Teacher", teacherCode].compactMap { $0 }.joined(separator: " · ")
        case .klasse: return "Class"
        case .subject: return SubjectPalette.subjectKey(name).flatMap(SubjectNames.knownName(forKey:)) ?? "Team"
        case .room: return "Room"
        }
    }

    /// At the side of a list of one kind: a student's class, a teacher's
    /// initials.
    var listAside: String? {
        switch kind {
        case .student: return studentClass
        case .teacher: return teacherCode
        default: return nil
        }
    }

    /// The class whose rules the timetable is read by (DayPlan: what's
    /// theirs, which notes are for them): a student's class, the class
    /// itself, a team's class ("1j ma" is 1j's). Nothing for a teacher or
    /// a room, who have every class.
    var scheduleClass: String {
        switch kind {
        case .student: return studentClass ?? ""
        case .klasse: return name
        case .subject:
            let first = name.split(separator: " ").first.map(String.init) ?? ""
            return first.first?.isNumber == true ? first : ""
        case .teacher, .room: return ""
        }
    }

    /// The name has it, or a teacher's initials are it.
    func matches(_ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if displayName.range(of: needle, options: options) != nil { return true }
        if let code = teacherCode, code.range(of: needle, options: options) != nil { return true }
        return false
    }

    /// A word of the name starts with it — those come first in a search.
    func startsWord(_ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        return displayName.split(separator: " ").contains { $0.range(of: needle, options: options) != nil }
    }
}

// MARK: - Pinned and recent

/// The schedules you pinned and the ones you opened lately, on this phone,
/// per school. Pinning is the pin on someone's schedule.
@MainActor
@Observable
final class FindMemory {
    static let shared = FindMemory()

    /// Read in straight away, so Find a schedule's list is complete from its
    /// first frame: the list growing while the screen slid in made the
    /// search field show through for a moment.
    init() { prepare() }

    private(set) var pinned: [ScheduleTarget] = []
    private(set) var recent: [ScheduleTarget] = []
    @ObservationIgnored private var school: String?

    /// The last few only: more was a list to scroll past.
    private static let recentLimit = 3

    private var pinnedKey: String { "find.pinned." + LectioConfig.schoolID }
    private var recentKey: String { "find.recent." + LectioConfig.schoolID }

    /// Reads them in for the school you're signed in to.
    func prepare() {
        guard school != LectioConfig.schoolID else { return }
        school = LectioConfig.schoolID
        pinned = Self.read(pinnedKey)
        recent = Array(Self.read(recentKey).prefix(Self.recentLimit))
    }

    func isPinned(_ target: ScheduleTarget) -> Bool {
        pinned.contains { $0.id == target.id }
    }

    func togglePin(_ target: ScheduleTarget) {
        prepare()
        if isPinned(target) {
            pinned.removeAll { $0.id == target.id }
        } else {
            pinned.append(target)
        }
        Self.write(pinned, pinnedKey)
    }

    func noteOpened(_ target: ScheduleTarget) {
        prepare()
        recent.removeAll { $0.id == target.id }
        recent.insert(target, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        Self.write(recent, recentKey)
    }

    func forget(_ target: ScheduleTarget) {
        recent.removeAll { $0.id == target.id }
        Self.write(recent, recentKey)
    }

    /// Signing out: who you looked up is nobody else's business.
    func forgetAll() {
        pinned = []
        recent = []
        UserDefaults.standard.removeObject(forKey: pinnedKey)
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    private static func read(_ key: String) -> [ScheduleTarget] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ScheduleTarget].self, from: data)) ?? []
    }

    private static func write(_ list: [ScheduleTarget], _ key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Every team at school

/// A subject on Lectio's list of teams: its id there, its code ("MA") and
/// Lectio's name for it ("Matematik").
struct TeamSubject: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var code: String
    var name: String

    /// The app's English name when it knows the subject, else Lectio's.
    var displayName: String {
        SubjectNames.knownName(forKey: code.lowercased()) ?? name
    }
}

/// Every team at school, the way Lectio's Find schedule has them: a list of
/// subjects, and a page of teams per subject. A subject's page is fetched
/// when you open it; a search fetches them all, a few at a time, and keeps
/// them for a week (teams change at the start of a term, not daily).
@MainActor
@Observable
final class TeamDirectory {
    static let shared = TeamDirectory()

    private(set) var subjects: [TeamSubject] = []
    private(set) var teamsBySubject: [String: [ScheduleTarget]] = [:]
    private(set) var subjectsFailed = false
    private(set) var failedSubjects: Set<String> = []

    @ObservationIgnored private var school: String?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var loadingAll = false

    private static let keepFor: TimeInterval = 7 * 24 * 3600

    var allTeams: [ScheduleTarget] { teamsBySubject.values.flatMap { $0 } }

    func teams(of subject: TeamSubject) -> [ScheduleTarget]? {
        teamsBySubject[subject.id]
    }

    func loadSubjects(cookies: [HTTPCookie]) async {
        switchSchoolIfNeeded()
        guard subjects.isEmpty, !cookies.isEmpty else { return }
        subjectsFailed = false
        do {
            let found = try await LectioStudyService.loadTeamSubjects(cookies: cookies)
            subjects = found
            subjectsFailed = found.isEmpty
        } catch {
            subjectsFailed = true
        }
    }

    func loadTeams(of subject: TeamSubject, cookies: [HTTPCookie]) async {
        switchSchoolIfNeeded()
        guard teamsBySubject[subject.id] == nil, !cookies.isEmpty else { return }
        failedSubjects.remove(subject.id)
        do {
            teamsBySubject[subject.id] = try await LectioStudyService.loadTeams(subjectID: subject.id,
                                                                                cookies: cookies)
        } catch {
            failedSubjects.insert(subject.id)
        }
    }

    /// Every subject's teams, for a search.
    func loadAll(cookies: [HTTPCookie]) async {
        switchSchoolIfNeeded()
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.keepFor, !teamsBySubject.isEmpty { return }
        guard !loadingAll, !cookies.isEmpty else { return }
        loadingAll = true
        defer { loadingAll = false }

        await loadSubjects(cookies: cookies)
        let missing = subjects.filter { teamsBySubject[$0.id] == nil }
        // Four at a time: it's the school's server.
        var start = 0
        while start < missing.count {
            let batch = Array(missing[start..<min(start + 4, missing.count)])
            start += 4
            await withTaskGroup(of: (String, [ScheduleTarget]?).self) { group in
                for subject in batch {
                    let id = subject.id
                    group.addTask {
                        (id, try? await LectioStudyService.loadTeams(subjectID: id, cookies: cookies))
                    }
                }
                for await (id, teams) in group {
                    if let teams { teamsBySubject[id] = teams }
                }
            }
        }
        if !subjects.isEmpty, subjects.allSatisfy({ teamsBySubject[$0.id] != nil }) {
            fetchedAt = Date()
            save()
        }
    }

    // MARK: Kept on the phone

    private struct Saved: Codable {
        var at: Date
        var subjects: [TeamSubject]
        var teams: [String: [ScheduleTarget]]
    }

    private var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("teams-" + LectioConfig.schoolID + ".json")
    }

    /// Another school's teams aren't this one's.
    private func switchSchoolIfNeeded() {
        guard school != LectioConfig.schoolID else { return }
        school = LectioConfig.schoolID
        subjects = []
        teamsBySubject = [:]
        failedSubjects = []
        fetchedAt = nil
        restore()
    }

    private func save() {
        guard let fileURL, let fetchedAt else { return }
        let saved = Saved(at: fetchedAt, subjects: subjects, teams: teamsBySubject)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func restore() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              Date().timeIntervalSince(saved.at) < Self.keepFor else { return }
        subjects = saved.subjects
        teamsBySubject = saved.teams
        fetchedAt = saved.at
    }
}

extension LectioStudyService {
    /// The subjects on Lectio's list of teams (FindSkema's Hold page).
    @concurrent static func loadTeamSubjects(cookies: [HTTPCookie]) async throws -> [TeamSubject] {
        let html = try await LectioService.fetchHTML(LectioConfig.base + "/FindSkema.aspx?type=hold",
                                                     cookies: cookies)
        return LectioParser.parseTeamSubjects(html)
    }

    /// One subject's teams, each with its schedule
    /// (`SkemaNy.aspx?type=holdelement&holdelementid=…`).
    @concurrent static func loadTeams(subjectID: String, cookies: [HTTPCookie]) async throws -> [ScheduleTarget] {
        let html = try await LectioService.fetchHTML(LectioConfig.base + "/FindSkema.aspx?type=hold&fag=" + subjectID,
                                                     cookies: cookies)
        return LectioParser.parseScheduleTargets(html, kind: .subject)
    }
}

extension LectioParser {
    /// FindSkema's Hold page: each subject a link to its teams,
    /// `<a href="…FindSkema.aspx?type=hold&fag=524…"><span
    /// class="findskema-symbol">MA</span>Matematik</a>`.
    static func parseTeamSubjects(_ html: String) -> [TeamSubject] {
        let root = HTMLDocument.parse(html)
        var subjects: [TeamSubject] = []
        var seen: Set<String> = []
        for anchor in root.all("a") {
            let href = anchor.attr("href") ?? ""
            guard href.contains("type=hold"), let g = Rx.match("fag=(\\d+)", href) else { continue }
            let id = g[1]
            guard !seen.contains(id) else { continue }
            let code = anchor.firstWhere { $0.hasClass("findskema-symbol") }?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var name = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty, name.hasPrefix(code) {
                name = String(name.dropFirst(code.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { continue }
            seen.insert(id)
            subjects.append(TeamSubject(id: id, code: code, name: name))
        }
        return subjects
    }
}
