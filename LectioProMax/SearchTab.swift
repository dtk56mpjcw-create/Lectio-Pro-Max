import SwiftUI

/// The Search tab: one field across everything the app already holds —
/// homework and assignments, message threads, and every lesson in the weeks
/// that have been loaded. It searches what's cached, so it's instant and works
/// offline.
///
/// Search rather than more filters, on purpose: filters get slower to use as a
/// year fills up, and this answers questions a filter can't ("that thing about
/// the poster").
///
/// The field itself belongs to the tab bar. `.searchable` sits on the TabView
/// and this is its `.search`-role tab — where iOS 26 puts search: its own
/// button at the end of the bar, which turns into the field.
struct SearchTab: View {
    let query: String
    @EnvironmentObject private var session: LectioSession
    @Namespace private var zoom

    @State private var openWork: WorkItem?
    @State private var openThread: MessageThreadSummary?

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var work: [WorkItem] {
        guard trimmed.count >= 2 else { return [] }
        return session.snapshot.workItems.filter {
            [$0.title, $0.code, $0.text].joined(separator: " ").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var threads: [MessageThreadSummary] {
        guard trimmed.count >= 2 else { return [] }
        return session.threads.filter {
            [$0.subject, $0.latestSender, $0.recipients]
                .joined(separator: " ").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var lessons: [LessonRoute] {
        guard trimmed.count >= 2 else { return [] }
        var hits: [LessonRoute] = []
        for week in session.snapshot.weeks.values {
            for day in week.days {
                for lesson in day.lessons {
                    let haystack = [lesson.title, lesson.code, lesson.teacher,
                                    lesson.room, lesson.homework, lesson.note]
                        .joined(separator: " ")
                    if haystack.localizedCaseInsensitiveContains(trimmed) {
                        hits.append(LessonRoute(lesson: lesson, dayISO: day.date))
                    }
                }
            }
        }
        return hits.sorted { $0.dayISO < $1.dayISO }
    }

    var body: some View {
        // Worked out once per update, not once per use below.
        let work = self.work
        let threads = self.threads
        let lessons = self.lessons

        NavigationStack {
            results(work: work, threads: threads, lessons: lessons)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { AppBackground() }
                .navigationTitle("Search")
                .navigationDestination(for: LessonRoute.self) { route in
                    LessonDetailScreen(lesson: route.lesson, dayISO: route.dayISO)
                        .navigationTransition(.zoom(sourceID: route.zoomID, in: zoom))
                }
        }
        .task { await session.loadInbox() }
        .sheet(item: $openWork) { item in
            WorkDetailSheet(item: item,
                            done: session.snapshot.isCompleted(item),
                            toggle: { session.toggleCompleted(item) })
                .environmentObject(session)
        }
        .sheet(item: $openThread) { thread in
            MessageThreadSheet(summary: thread).environmentObject(session)
        }
    }

    @ViewBuilder
    private func results(work: [WorkItem],
                         threads: [MessageThreadSummary],
                         lessons: [LessonRoute]) -> some View {
        if trimmed.count < 2 {
            ContentUnavailableView("Search Lectio",
                                   systemImage: "magnifyingglass",
                                   description: Text("Homework, messages and lessons — everything the app has loaded."))
        } else if work.isEmpty && threads.isEmpty && lessons.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !work.isEmpty {
                        group("Homework") {
                            ForEach(work) { item in
                                Button {
                                    openWork = item
                                } label: {
                                    row(icon: item.isAssignment ? "tray.and.arrow.up" : "book",
                                        code: item.code,
                                        title: LectioDates.tidy(item.title),
                                        detail: item.due.map { "Due " + LectioDates.friendlyLabel(iso: $0) } ?? "")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !threads.isEmpty {
                        group("Messages") {
                            ForEach(threads) { thread in
                                Button {
                                    openThread = thread
                                } label: {
                                    row(icon: "envelope",
                                        code: "",
                                        title: thread.subject,
                                        detail: [thread.latestSender, thread.changed]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !lessons.isEmpty {
                        group("Lessons") {
                            ForEach(lessons, id: \.zoomID) { route in
                                NavigationLink(value: route) {
                                    row(icon: "calendar",
                                        code: route.lesson.code,
                                        title: route.lesson.displayTitle,
                                        detail: LectioDates.dayLabel(iso: route.dayISO)
                                            + (route.lesson.start.isEmpty ? "" : " · " + route.lesson.start))
                                }
                                .buttonStyle(.plain)
                                .matchedTransitionSource(id: route.zoomID, in: zoom)
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .heavy))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .contentCard(radius: Metrics.inner)
        }
    }

    private func row(icon: String, code: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(code.isEmpty ? Color(.tertiaryLabel) : Color.forSubject(code))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                let caption = [LessonText.abbreviated(code).uppercased(), detail]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 13)
        .contentShape(Rectangle())
    }
}
