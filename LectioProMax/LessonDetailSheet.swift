import SwiftUI

/// The Overview side of a lesson's page: the header, room and teacher, the
/// teacher's note, and Elevfeedback. Its homework and other content are on
/// the Content side, not here (Dan's choice): the overview stays short.
///
/// It loads the lesson's Lectio page and its Elevfeedback tab together,
/// through the shared cache: the note comes from the page, and Content is
/// ready by the time you swipe to it.
struct LessonDetailContent: View {
    let lesson: Lesson
    let dayISO: String
    /// Opens a teacher's or a room's schedule, pushed by the page around
    /// this one; without it the room and the teacher are only shown.
    var openSchedule: ((ScheduleTarget) -> Void)? = nil

    @Environment(LectioSession.self) private var session
    @State private var detail: LessonDetail?
    @State private var feedback: LessonFeedback?
    @State private var showFeedback = false

    init(lesson: Lesson, dayISO: String, openSchedule: ((ScheduleTarget) -> Void)? = nil) {
        self.lesson = lesson
        self.dayISO = dayISO
        self.openSchedule = openSchedule
        // Whatever was fetched ahead of time is there from the first frame.
        _detail = State(initialValue: lesson.link.flatMap { LessonCache.shared.detail($0) })
        _feedback = State(initialValue: lesson.link.flatMap { LessonCache.shared.feedback($0) })
    }

    /// The page's note, as the teacher wrote it; the schedule's copy until
    /// the page is here (or if it has none we could read).
    private var note: String {
        if let page = detail?.note, !page.isEmpty { return page }
        return lesson.note
    }

    private var tint: Color { Color.forSubject(lesson.subjectCode) }
    private var state: LessonState { lesson.state(onDay: dayISO) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SubjectDot(code: lesson.isClassLesson ? lesson.subjectCode : "", size: 9)
                    Text(kicker.uppercased())
                        .scaledFont(size: 14, weight: .heavy)
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if state == .current && !lesson.isAllDay {
                        Text("NOW")
                            .scaledFont(size: 12.5, weight: .heavy)
                            .foregroundStyle(Palette.accent)
                    }
                    if lesson.cancelled {
                        Text("CANCELLED")
                            .scaledFont(size: 12.5, weight: .heavy)
                            .foregroundStyle(Palette.negative)
                    } else if lesson.changed && lesson.isClassLesson {
                        Text("CHANGED")
                            .scaledFont(size: 12.5, weight: .heavy)
                            .foregroundStyle(Palette.warning)
                    }
                    Spacer()
                }
                Text(bigTitle)
                    .scaledFont(size: 31, weight: .bold)
                    .strikethrough(lesson.cancelled, color: Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LectioDates.longLabel(iso: dayISO) + " · " + when)
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }

            if !lesson.room.isEmpty || !lesson.teacher.isEmpty {
                // Side by side and as tall as each other, however long the
                // teacher's name.
                HStack(alignment: .top, spacing: 10) {
                    if !lesson.room.isEmpty { roomTile }
                    if !lesson.teacher.isEmpty { teacherTile }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NOTE")
                        .scaledFont(size: 12, weight: .heavy)
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Text(LectioDates.tidy(note))
                        .scaledFont(size: 16.5)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(radius: Metrics.inner + 2)
            }

            // A lesson without the tab is normal: no card, and no message.
            if let feedback, feedback.available {
                LessonFeedbackCard(feedback: feedback) { showFeedback = true }
            }

            if let link = lesson.link, let url = URL(string: link) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").scaledFont(size: 15, weight: .semibold)
                        Text("Open in Lectio")
                            .scaledFont(size: 16, weight: .semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right").scaledFont(size: 12.5, weight: .bold)
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(15)
                    .frame(maxWidth: .infinity)
                    .contentCard(radius: Metrics.inner + 2)
                }
            }
        }
        .task { await load() }
        // Who's who: the teachers' names and the rooms' schedules. Usually
        // here already, fetched by the Schedule tab.
        .task { await session.loadScheduleTargets() }
        .sheet(isPresented: $showFeedback, onDismiss: { Task { await reloadFeedback() } }) {
            if let link = lesson.link {
                FeedbackSheet(lessonLink: link, title: lesson.displayTitle, code: lesson.code)
                    .environment(session)
            }
        }
    }

    /// The page and its Elevfeedback, through the shared cache: only what's
    /// out of date is asked for, quietly, over what's already shown.
    private func load() async {
        guard let link = lesson.link else { return }
        let cache = LessonCache.shared
        if !cache.isDetailFresh(link) || !cache.isFeedbackFresh(link) {
            let cookies = await session.requestCookies()
            await cache.load(link, detail: true, feedback: true, cookies: cookies)
        }
        if let fresh = cache.detail(link) { detail = fresh }
        if let fresh = cache.feedback(link) { feedback = fresh }
    }

    /// After the Elevfeedback sheet closes: what was just written, fresh.
    private func reloadFeedback() async {
        guard let link = lesson.link else { return }
        let cookies = await session.requestCookies()
        if let fresh = try? await LectioFeedbackService.load(lessonLink: link, cookies: cookies) {
            feedback = fresh
            LessonCache.shared.store(feedback: fresh, for: link)
        }
    }

    /// Above the title: the subject for a lesson ("Maths · MA"), otherwise
    /// what kind of thing this is.
    private var kicker: String {
        if lesson.isClassLesson {
            let code = lesson.shortLabel
            if let name = lesson.subjectName { return name + " · " + code }
            return code
        }
        if lesson.isPrivateEvent { return "Your event" }
        return lesson.isAllDay ? "All day" : "Event"
    }

    /// The lesson's topic when it has one ("Start radicals"); otherwise what
    /// it's called.
    private var bigTitle: String {
        lesson.topic ?? lesson.headline
    }

    private var when: String {
        if let span = lesson.allDay { return span.isEmpty ? "All day" : span.prefix(1).uppercased() + span.dropFirst() }
        return lesson.timeRange
    }

    // MARK: Room and teacher

    /// The room, its schedule a tap away once Find a schedule's list has it.
    private var roomTile: some View {
        let targets = Self.names(lesson.room).compactMap(schedule(ofRoom:))
        return opening(targets, named: \.name) {
            factTile("mappin", "Room", opens: !targets.isEmpty) {
                Text(lesson.room)
                    .scaledFont(size: 18.5, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The teacher's photo and full name ("Lise Sørensen", not "LS"), their
    /// schedule a tap away. Several teachers, one under the other.
    private var teacherTile: some View {
        let people = teachers
        let targets = people.compactMap(schedule(of:))
        return opening(targets, named: \.displayName) {
            factTile("person", people.count > 1 ? "Teachers" : "Teacher", opens: !targets.isEmpty) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(people, id: \.self) { teacher in
                        let entry = directoryEntry(teacher)
                        HStack(spacing: 8) {
                            SenderAvatar(name: entry?.name ?? teacher.initials,
                                         personID: teacher.id.isEmpty ? nil : teacher.id,
                                         size: people.count > 1 ? 24 : 30)
                            Text(entry?.displayName ?? teacher.initials)
                                .scaledFont(size: people.count > 1 ? 15 : 16.5, weight: .semibold)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Who teaches it: from the lesson's page when it's here, which tags
    /// each teacher with their id; until then, or on a page that tags no
    /// one, the schedule's initials, looked up in the school's directory.
    private var teachers: [LessonTeacher] {
        if let tagged = detail?.teachers, !tagged.isEmpty { return tagged }
        return Self.names(lesson.teacher).map { initials in
            let found = session.scheduleTargets.filter { $0.kind == .teacher && $0.teacherCode == initials }
            // Two teachers with the same initials: no photo rather than the
            // wrong one.
            return LessonTeacher(id: found.count == 1 ? (found[0].contextCardID ?? "") : "",
                                 initials: initials)
        }
    }

    /// "062, 064" -> ["062", "064"]: a lesson for two classes has two of each.
    private static func names(_ text: String) -> [String] {
        text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The teacher in the school's directory, with their full name.
    private func directoryEntry(_ teacher: LessonTeacher) -> ScheduleTarget? {
        guard !teacher.id.isEmpty else { return nil }
        return session.scheduleTargets.first { $0.kind == .teacher && $0.contextCardID == teacher.id }
    }

    /// A teacher's schedule: the directory's entry, or until that's here,
    /// Lectio's address for it, made from their id.
    private func schedule(of teacher: LessonTeacher) -> ScheduleTarget? {
        if let entry = directoryEntry(teacher) { return entry }
        let number = teacher.id.dropFirst()
        guard teacher.id.hasPrefix("T"), !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return ScheduleTarget(name: teacher.initials,
                              url: LectioConfig.skemaURL + "?laererid=" + number,
                              kind: .teacher)
    }

    /// A room's schedule, found by its code ("006") in Find a schedule's list.
    private func schedule(ofRoom room: String) -> ScheduleTarget? {
        session.scheduleTargets.first { $0.kind == .room && ($0.code ?? $0.name) == room }
    }

    /// A tile that opens a schedule: straight away for one, from a menu for
    /// a lesson with several teachers or rooms. Only the tile when there's
    /// nothing to open.
    @ViewBuilder
    private func opening<Tile: View>(_ targets: [ScheduleTarget],
                                     named name: @escaping (ScheduleTarget) -> String,
                                     @ViewBuilder tile: () -> Tile) -> some View {
        if let openSchedule, targets.count == 1 {
            Button { openSchedule(targets[0]) } label: { tile() }
                .buttonStyle(PressableCard())
                .accessibilityHint("Shows the schedule")
        } else if let openSchedule, targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button(name(target)) { openSchedule(target) }
                }
            } label: { tile() }
            .menuStyle(.button)
            .buttonStyle(PressableCard())
            .accessibilityHint("Shows a schedule")
        } else {
            tile()
        }
    }

    private func factTile<Value: View>(_ icon: String, _ label: String, opens: Bool,
                                       @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).scaledFont(size: 11, weight: .semibold)
                Text(label.uppercased())
                    .scaledFont(size: 11, weight: .heavy)
                    .tracking(0.5)
                Spacer(minLength: 0)
                // As a row in Settings says it opens something.
                if opens {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            value()
        }
        // Not the accent a menu or a button would give it.
        .foregroundStyle(.primary)
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(radius: Metrics.inner)
        .contentShape(Rectangle())
    }
}

/// The two sides of a lesson's page.
enum LessonPage: Hashable {
    case overview, content
}

/// A lesson pushed onto the Schedule or Search stack (the standard push)
/// from the card that was tapped. The system back button replaces the sheet's close button —
/// nothing floats over the schedule's own controls any more.
///
/// Two sides, as in Dan's reference: Overview (the lesson, the teacher's
/// note and Elevfeedback) and Content (its homework and everything else on
/// its Lectio page). Chosen with the system's segmented control, which is Liquid
/// Glass on iOS 26, on a glass capsule over the page, or by swiping between
/// them (native paging). Something with no Lectio page of its own, such as
/// your own event, has only the overview, and no chooser.
struct LessonDetailScreen: View {
    let lesson: Lesson
    let dayISO: String

    @State private var page: LessonPage = .overview
    /// The teacher's or room's schedule, pushed from the Overview side.
    @State private var openTarget: ScheduleTarget?

    var body: some View {
        Group {
            if let link = lesson.link {
                TabView(selection: $page) {
                    scrolling {
                        LessonDetailContent(lesson: lesson, dayISO: dayISO) { openTarget = $0 }
                    }
                    .tag(LessonPage.overview)
                    scrolling {
                        // The note is on the Overview side.
                        LessonContentView(link: link, placeholder: lesson.homework, showsNote: false)
                    }
                    .tag(LessonPage.content)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // An inset, not iOS 26's safeAreaBar: that one misplaces
                // controls pinned like this on iOS 27's first betas, and the
                // classmate's iPhone 15 runs iOS 27.
                .safeAreaInset(edge: .top, spacing: 0) { chooser }
            } else {
                scrolling {
                    LessonDetailContent(lesson: lesson, dayISO: dayISO) { openTarget = $0 }
                }
            }
        }
        .background { AppBackground() }
        // Here, outside the paging, so it's never in a lazy container.
        .navigationDestination(item: $openTarget) { target in
            TargetScheduleScreen(target: target)
        }
        // A small title in the bar, as Calendar's "Event Details" has, so the
        // back button isn't floating on its own; the lesson's own name stays
        // large in the page. The editor role keeps the back button to its
        // chevron.
        .navigationTitle(lesson.isClassLesson || lesson.isPrivateEvent ? "Lesson" : "Event")
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }

    /// Overview or Content: a tap here, or a swipe on the page.
    private var chooser: some View {
        Picker("Show", selection: $page.animation(.snappy)) {
            Text("Overview").tag(LessonPage.overview)
            Text("Content").tag(LessonPage.content)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// One side of the page, scrolling on its own. Never wider than the page
    /// (see pageWide): a side that could move sideways would let the paging
    /// take a drag from it, the Schedule's old long-day jerk.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 36)
                .pageWide()
        }
        .scrollIndicators(.hidden)
    }
}

/// Shared chrome for detail sheets: dusk background, close button, scroll.
struct DetailSheetScaffold<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.pushedScreen) private var pushed

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                content
                    .padding(.horizontal, Metrics.margin)
                    // Starts below the close button rather than beside it: the
                    // button had to move down to get off the tab header's own
                    // controls, and a long lesson title would otherwise run
                    // straight underneath it.
                    .padding(.top, pushed ? 8 : SheetCloseButton.contentInset)
                    .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)

            SheetCloseButton(action: onClose)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }
}
