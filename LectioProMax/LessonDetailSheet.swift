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

    @Environment(LectioSession.self) private var session
    @State private var detail: LessonDetail?
    @State private var feedback: LessonFeedback?
    @State private var showFeedback = false

    init(lesson: Lesson, dayISO: String) {
        self.lesson = lesson
        self.dayISO = dayISO
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
                FindableText(bigTitle)
                    .scaledFont(size: 31, weight: .bold)
                    .strikethrough(lesson.cancelled, color: Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LectioDates.longLabel(iso: dayISO) + " · " + when)
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }

            if !lesson.room.isEmpty || !lesson.teacher.isEmpty {
                HStack(spacing: 10) {
                    if !lesson.room.isEmpty { factTile("mappin", "Room", lesson.room) }
                    if !lesson.teacher.isEmpty { factTile("person", "Teacher", lesson.teacher) }
                }
            }

            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NOTE")
                        .scaledFont(size: 12, weight: .heavy)
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    FindableText(LectioDates.tidy(note))
                        .scaledFont(size: 16.5)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func factTile(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).scaledFont(size: 11, weight: .semibold)
                Text(label.uppercased())
                    .scaledFont(size: 11, weight: .heavy)
                    .tracking(0.5)
            }
            .foregroundStyle(.secondary)
            FindableText(value).scaledFont(size: 18.5, weight: .semibold)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner)
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
    /// Find on page, in the copy of the tab behind the search (PageFind).
    @Environment(PageFind.self) private var find: PageFind?

    var body: some View {
        Group {
            if let link = lesson.link {
                TabView(selection: $page) {
                    scrolling(area: 0) {
                        LessonDetailContent(lesson: lesson, dayISO: dayISO)
                    }
                    .tag(LessonPage.overview)
                    scrolling(area: 1) {
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
                scrolling(area: 0) {
                    LessonDetailContent(lesson: lesson, dayISO: dayISO)
                }
            }
        }
        .background { AppBackground() }
        // Finding on the page: to the side the current match is on.
        .onChange(of: find?.currentHit?.area) { _, area in
            guard let area else { return }
            let side: LessonPage = area == 0 ? .overview : .content
            if side != page { withAnimation(.snappy) { page = side } }
        }
        .findsOnPage()
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
    private func scrolling<Content: View>(area: Int, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .findScroller(area: area)
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
                    .findScroller()
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
