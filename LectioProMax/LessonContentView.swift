import SwiftUI

/// A lesson's page as Lectio serves it: the activity note, every content section
/// under its own heading, and any pinned files — downloaded with the session's
/// cookies and opened in-app.
///
/// Shared by the schedule's lesson sheet and the homework sheet, because both
/// are looking at the same underlying Lectio page.
struct LessonContentView: View {
    let link: String
    /// Shown immediately while the page loads, so there's never a blank wait.
    var placeholder: String = ""
    /// Set these to offer Elevfeedback for this lesson. Left empty (the homework
    /// sheet) the card isn't shown and the extra request isn't made.
    var feedbackTitle: String = ""
    var feedbackCode: String = ""

    @EnvironmentObject private var session: LectioSession

    @State private var detail: LessonDetail?
    @State private var loading = false
    @State private var loadError: String?
    @State private var preview: PreviewDocument?
    @State private var downloading: String?
    @State private var feedback: LessonFeedback?
    @State private var showFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if detail == nil && !placeholder.isEmpty {
                textCard("Homework", placeholder)
            }

            if loading {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Loading from Lectio…")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary.opacity(0.7))
                }
                .padding(.vertical, 4)
            }

            if let detail = detail {
                if !detail.note.isEmpty {
                    textCard("Note", detail.note)
                }
                ForEach(detail.sections) { section in
                    sectionCard(section)
                }
                if detail.isEmpty && placeholder.isEmpty {
                    EmptyNotice(icon: "doc.text", text: "Nothing attached to this lesson")
                }
            }

            if let feedback = feedback, feedback.available {
                feedbackCard(feedback)
            }
        }
        .task { await load() }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
        .sheet(isPresented: $showFeedback, onDismiss: { Task { await loadFeedback(force: true) } }) {
            FeedbackSheet(lessonLink: link, title: feedbackTitle, code: feedbackCode)
                .environmentObject(session)
        }
    }

    /// Elevfeedback is a tab on the same Lectio page, so it costs one more
    /// request — made only when a lesson sheet is actually open, never while
    /// drawing a week of the schedule.
    private func feedbackCard(_ feedback: LessonFeedback) -> some View {
        Button { showFeedback = true } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("ELEVFEEDBACK")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.primary.opacity(0.58))
                    Spacer()
                    Image(systemName: feedback.isEmpty ? "square.and.pencil" : "chevron.right")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
                if feedback.isEmpty {
                    Text("Nothing written yet")
                        .font(.system(size: 16))
                        .foregroundStyle(.primary.opacity(0.6))
                } else {
                    Text(feedback.plainText)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func textCard(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.58))
            Text(LectioDates.tidy(body))
                .font(.system(size: 16.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func sectionCard(_ section: LessonSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LessonWording.section(section.title).uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.58))

            ForEach(section.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    if !entry.text.isEmpty {
                        Text(LectioDates.tidy(entry.text))
                            .font(.system(size: 16))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(entry.files) { file in
                        fileRow(file)
                    }
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func fileRow(_ file: LessonFile) -> some View {
        Button {
            Task { await open(file) }
        } label: {
            HStack(spacing: 9) {
                if downloading == file.link {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                Text(file.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
    }

    private func load() async {
        guard detail == nil, !loading, !link.isEmpty else { return }
        loading = true
        let cookies = await session.requestCookies()
        do {
            detail = try await LectioStudyService.loadLessonDetail(link: link, cookies: cookies)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
        await loadFeedback(force: false)
    }

    private func loadFeedback(force: Bool) async {
        guard !feedbackTitle.isEmpty, !link.isEmpty else { return }
        guard force || feedback == nil else { return }
        let cookies = await session.requestCookies()
        // A lesson without the tab is normal, not an error worth a banner.
        feedback = try? await LectioFeedbackService.load(lessonLink: link, cookies: cookies)
    }

    private func open(_ file: LessonFile) async {
        downloading = file.link
        defer { downloading = nil }
        let cookies = await session.requestCookies()
        do {
            let saved = try await LectioHandInService.downloadDocument(
                link: file.link, suggestedName: file.name, cookies: cookies)
            preview = PreviewDocument(url: saved)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
