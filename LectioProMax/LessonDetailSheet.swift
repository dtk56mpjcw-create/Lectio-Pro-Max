import SwiftUI

struct LessonDetailSheet: View {
    let lesson: Lesson
    let dayISO: String
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss


    private var tint: Color { Color.forSubject(lesson.code) }
    private var state: LessonState { lesson.state(onDay: dayISO) }

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        SubjectDot(code: lesson.code, size: 9)
                        Text(lesson.code.uppercased())
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        if state == .current {
                            Text("NOW")
                                .font(.system(size: 12.5, weight: .heavy))
                                .foregroundStyle(Palette.accent)
                        }
                        if lesson.cancelled {
                            Text("CANCELLED")
                                .font(.system(size: 12.5, weight: .heavy))
                                .foregroundStyle(.red)
                        }
                        Spacer()
                    }
                    Text(lesson.displayTitle)
                        .font(.system(size: 31, weight: .bold))
                        .strikethrough(lesson.cancelled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LectioDates.longLabel(iso: dayISO) + " · " + lesson.timeRange)
                        .font(.system(size: 15.5, weight: .medium))
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
                            Image(systemName: "safari").font(.system(size: 15, weight: .semibold))
                            Text("Open in Lectio")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 12.5, weight: .bold))
                        }
                        .foregroundStyle(Palette.accent)
                        .padding(15)
                        .frame(maxWidth: .infinity)
                        .contentCard(radius: Metrics.inner + 2)
                    }
                }
            }
        }
    }

    private func factTile(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.5)
            }
            .foregroundStyle(.secondary)
            Text(value).font(.system(size: 18.5, weight: .semibold))
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner)
    }

    private func textSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(LectioDates.tidy(body))
                .font(.system(size: 16.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }
}

/// Shared chrome for detail sheets: dusk background, close button, scroll.
struct DetailSheetScaffold<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: Content

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
                    .padding(.top, SheetCloseButton.contentInset)
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
