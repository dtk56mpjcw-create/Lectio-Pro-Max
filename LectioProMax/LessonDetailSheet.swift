import SwiftUI

/// Everything about a lesson: the header, room and teacher, the lesson's own
/// page and student feedback. Shown pushed (`LessonDetailScreen`) or, where
/// there's no stack to push onto, as a sheet (`LessonDetailSheet`).
struct LessonDetailContent: View {
    let lesson: Lesson
    let dayISO: String


    private var tint: Color { Color.forSubject(lesson.code) }
    private var state: LessonState { lesson.state(onDay: dayISO) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SubjectDot(code: lesson.isClassLesson ? lesson.code : "", size: 9)
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
                    .strikethrough(lesson.cancelled)
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

            if let link = lesson.link {
                LessonContentView(link: link,
                                  placeholder: [lesson.homework, lesson.note]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: "\n\n"),
                                  feedbackTitle: lesson.displayTitle,
                                  feedbackCode: lesson.code)
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
            Text(value).scaledFont(size: 18.5, weight: .semibold)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner)
    }

    private func textSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(LectioDates.tidy(body))
                .scaledFont(size: 16.5)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }
}

/// A lesson as a sheet, for places with no navigation stack to push onto.
struct LessonDetailSheet: View {
    let lesson: Lesson
    let dayISO: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            LessonDetailContent(lesson: lesson, dayISO: dayISO)
        }
    }
}

/// A lesson pushed onto the Schedule or Search stack (the standard push)
/// from the card that was tapped. The system back button replaces the sheet's close button —
/// nothing floats over the schedule's own controls any more.
struct LessonDetailScreen: View {
    let lesson: Lesson
    let dayISO: String

    var body: some View {
        ScrollView {
            LessonDetailContent(lesson: lesson, dayISO: dayISO)
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        // A small title in the bar, as Calendar's "Event Details" has, so the
        // back button isn't floating on its own; the lesson's own name stays
        // large in the page. The editor role keeps the back button to its
        // chevron.
        .navigationTitle(lesson.isClassLesson || lesson.isPrivateEvent ? "Lesson" : "Event")
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
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
