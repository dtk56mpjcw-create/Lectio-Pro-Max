import SwiftUI

/// One box across everything the app already holds: homework and assignments,
/// message threads, and every lesson in the weeks that have been loaded.
///
/// Search rather than more filters, on purpose — filters get slower to use as a
/// year fills up, and this answers questions a filter can't ("that thing about
/// the poster"). It searches what's cached, so it works offline and instantly.
struct SearchSheet: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var openWork: WorkItem?
    @State private var openThread: MessageThreadSummary?
    @State private var openLesson: LessonHit?

    struct LessonHit: Identifiable {
        var id: String { dayISO + "|" + lesson.id }
        let lesson: Lesson
        let dayISO: String
    }

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

    private var lessons: [LessonHit] {
        guard trimmed.count >= 2 else { return [] }
        var hits: [LessonHit] = []
        for week in session.snapshot.weeks.values {
            for day in week.days {
                for lesson in day.lessons {
                    let haystack = [lesson.title, lesson.code, lesson.teacher,
                                    lesson.room, lesson.homework, lesson.note]
                        .joined(separator: " ")
                    if haystack.localizedCaseInsensitiveContains(trimmed) {
                        hits.append(LessonHit(lesson: lesson, dayISO: day.date))
                    }
                }
            }
        }
        return hits.sorted { $0.dayISO < $1.dayISO }
    }

    private var total: Int { work.count + threads.count + lessons.count }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()

            VStack(alignment: .leading, spacing: 13) {
                Text("Search")
                    .font(.system(size: 26, weight: .bold))
                    .padding(.top, 34)
                    .padding(.trailing, 44)

                TextField("Homework, messages, lessons", text: $query)
                    .font(.system(size: 16))
                    .autocorrectionDisabled()
                    .padding(13)
                    .contentCard(radius: Metrics.inner)

                if trimmed.count < 2 {
                    Spacer()
                    EmptyNotice(icon: "magnifyingglass", text: "Type to search everything")
                    Spacer()
                } else if total == 0 {
                    Spacer()
                    EmptyNotice(icon: "magnifyingglass", text: "Nothing matches “\(trimmed)”")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if !work.isEmpty {
                                group("Homework") {
                                    ForEach(work) { item in
                                        row(icon: item.isAssignment ? "tray.and.arrow.up" : "book",
                                            code: item.code,
                                            title: LectioDates.tidy(item.title),
                                            detail: item.due.map { "Due " + LectioDates.friendlyLabel(iso: $0) } ?? "") {
                                            openWork = item
                                        }
                                    }
                                }
                            }
                            if !threads.isEmpty {
                                group("Messages") {
                                    ForEach(threads) { thread in
                                        row(icon: "envelope",
                                            code: "",
                                            title: thread.subject,
                                            detail: [thread.latestSender, thread.changed]
                                                .filter { !$0.isEmpty }.joined(separator: " · ")) {
                                            openThread = thread
                                        }
                                    }
                                }
                            }
                            if !lessons.isEmpty {
                                group("Lessons") {
                                    ForEach(lessons) { hit in
                                        row(icon: "calendar",
                                            code: hit.lesson.code,
                                            title: hit.lesson.displayTitle,
                                            detail: LectioDates.dayLabel(iso: hit.dayISO)
                                                + (hit.lesson.start.isEmpty ? "" : " · " + hit.lesson.start)) {
                                            openLesson = hit
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 24)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
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
        .sheet(item: $openLesson) { hit in
            LessonDetailSheet(lesson: hit.lesson, dayISO: hit.dayISO)
                .environmentObject(session)
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

    private func row(icon: String,
                     code: String,
                     title: String,
                     detail: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
                    if !detail.isEmpty || !code.isEmpty {
                        Text([code.uppercased(), detail].filter { !$0.isEmpty }.joined(separator: " · "))
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
        .buttonStyle(.plain)
    }
}
