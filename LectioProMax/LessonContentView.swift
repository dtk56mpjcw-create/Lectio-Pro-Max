import SwiftUI

/// A lesson's page as Lectio serves it: the activity note, every content section
/// under its own heading (paragraphs, links and pictures as the teacher laid
/// them out), and any pinned files — downloaded with the session's cookies and
/// opened in-app.
///
/// Shown on the Content side of a lesson's page and in the homework sheet,
/// because both are looking at the same underlying Lectio page.
struct LessonContentView: View {
    let link: String
    /// Shown immediately while the page loads, so there's never a blank wait.
    var placeholder: String = ""
    /// Off on a lesson's page, whose Overview side has the note (Dan's
    /// choice); on in the homework sheet, which has no other place for it.
    var showsNote: Bool = true

    @Environment(LectioSession.self) private var session

    @State private var detail: LessonDetail?
    @State private var loading = false
    @State private var loadError: String?
    @State private var preview: PreviewDocument?
    @State private var downloading: String?

    init(link: String, placeholder: String = "", showsNote: Bool = true) {
        self.link = link
        self.placeholder = placeholder
        self.showsNote = showsNote
        // Whatever was fetched ahead of time is there from the first frame.
        _detail = State(initialValue: LessonCache.shared.detail(link))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Also when the page came back with nothing we could read: the
            // schedule's own copy of the homework is better than nothing.
            if (detail == nil || hasNothing) && !placeholder.isEmpty {
                textCard("Homework", placeholder)
            }

            if loading {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Loading from Lectio…")
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let detail = detail {
                if showsNote && !detail.note.isEmpty {
                    textCard("Note", detail.note)
                }
                ForEach(detail.sections) { section in
                    sectionCard(section)
                }
                if hasNothing && placeholder.isEmpty {
                    EmptyNotice(icon: "doc.text", text: "Nothing attached to this lesson")
                }
            }
        }
        .task { await load() }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
    }

    /// Nothing to show here: no content, and no note, or a note shown
    /// elsewhere.
    private var hasNothing: Bool {
        guard let detail else { return false }
        let noContent = detail.sections.allSatisfy { $0.entries.allSatisfy(\.isEmpty) }
        return noContent && (!showsNote || detail.note.isEmpty)
    }

    private func textCard(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(LectioDates.tidy(body))
                .scaledFont(size: 16.5)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func sectionCard(_ section: LessonSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LessonWording.section(section.title).uppercased())
                .scaledFont(size: 12, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)

            ForEach(section.entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    // Paragraphs, links and pictures as Lectio has them.
                    LessonBlocksView(blocks: entry.blocks)
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
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }
                Text(file.name)
                    .scaledFont(size: 15.5, weight: .semibold)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.circle")
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(.tertiary)
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

    /// The page through the shared cache: a copy fetched ahead is already on
    /// screen, and only an out-of-date one is asked for again — quietly,
    /// without a spinner over what's shown.
    private func load() async {
        guard !link.isEmpty, !loading else { return }
        let cache = LessonCache.shared
        guard !cache.isDetailFresh(link) else {
            detail = cache.detail(link)
            return
        }

        loading = detail == nil
        let cookies = await session.requestCookies()
        await cache.load(link, detail: true, feedback: false, cookies: cookies)
        loading = false

        if let fresh = cache.detail(link) {
            detail = fresh
        } else if detail == nil {
            loadError = "Couldn't load this lesson from Lectio."
        }
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

/// A lesson's Elevfeedback as a card: what's written (or that nothing is
/// yet), opening the editor on a tap. On the Overview side of the lesson's
/// page, which loads it (see LessonDetailContent).
struct LessonFeedbackCard: View {
    let feedback: LessonFeedback
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("ELEVFEEDBACK")
                        .scaledFont(size: 12, weight: .heavy)
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: feedback.isEmpty ? "square.and.pencil" : "chevron.right")
                        .scaledFont(size: 12.5, weight: .bold)
                        .foregroundStyle(Palette.accent)
                }
                if feedback.isEmpty {
                    Text("Nothing written yet")
                        .scaledFont(size: 16)
                        .foregroundStyle(.secondary)
                } else {
                    Text(feedback.plainText)
                        .scaledFont(size: 16)
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
}
