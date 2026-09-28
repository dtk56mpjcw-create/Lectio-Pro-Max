import SwiftUI

/// A lesson's page as Lectio serves it: the activity note, every content section
/// under its own heading (paragraphs, links and pictures as the teacher laid
/// them out), and any pinned files — downloaded with the session's cookies and
/// opened in-app.
///
/// Shown on the lesson's Content page and in the homework sheet, because both
/// are looking at the same underlying Lectio page.
struct LessonContentView: View {
    let link: String
    /// Shown immediately while the page loads, so there's never a blank wait.
    var placeholder: String = ""

    @Environment(LectioSession.self) private var session

    @State private var detail: LessonDetail?
    @State private var loading = false
    @State private var loadError: String?
    @State private var preview: PreviewDocument?
    @State private var downloading: String?

    init(link: String, placeholder: String = "") {
        self.link = link
        self.placeholder = placeholder
        // Whatever was fetched ahead of time is there from the first frame.
        _detail = State(initialValue: LessonCache.shared.detail(link))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Also when the page came back with nothing we could read: the
            // schedule's own copy of the homework is better than nothing.
            if (detail == nil || detail?.isEmpty == true) && !placeholder.isEmpty {
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
        }
        .task { await load() }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
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

/// On the lesson page: its content as one card that opens a page of its own,
/// and its Elevfeedback.
///
/// The content used to be spread down the lesson page, and a long homework
/// with a picture pushed everything else a few screens away. Dan's idea: a
/// Content page. The card says how the homework starts and what else there
/// is ("Homework · 2 links · 1 picture"), so most days there's no need to
/// open it.
struct LessonOverview: View {
    let link: String
    /// The schedule's own copy of the homework and note, while the page loads.
    var placeholder: String = ""
    /// For Elevfeedback: the lesson's name and subject code. Only a real
    /// lesson has the tab.
    var feedbackTitle: String = ""
    var feedbackCode: String = ""

    @Environment(LectioSession.self) private var session

    @State private var detail: LessonDetail?
    @State private var loading = false
    @State private var feedback: LessonFeedback?
    @State private var showFeedback = false

    init(link: String, placeholder: String = "", feedbackTitle: String = "", feedbackCode: String = "") {
        self.link = link
        self.placeholder = placeholder
        self.feedbackTitle = feedbackTitle
        self.feedbackCode = feedbackCode
        _detail = State(initialValue: LessonCache.shared.detail(link))
        _feedback = State(initialValue: feedbackTitle.isEmpty ? nil : LessonCache.shared.feedback(link))
    }

    /// Left out only when there's nothing to open: Lectio's page came back
    /// empty, or couldn't be had, and the schedule had no homework either.
    private var showsContent: Bool {
        if let detail, !detail.isEmpty { return true }
        return loading || !placeholder.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsContent {
                contentCard
            }
            if let feedback = feedback, feedback.available {
                feedbackCard(feedback)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showFeedback, onDismiss: { Task { await loadFeedback(force: true) } }) {
            FeedbackSheet(lessonLink: link, title: feedbackTitle, code: feedbackCode)
                .environment(session)
        }
    }

    private var contentCard: some View {
        let fromPage = detail?.previewText ?? ""
        let preview = fromPage.isEmpty ? LectioDates.tidy(placeholder) : fromPage
        let summary = detail?.summary ?? ""
        return NavigationLink {
            LessonContentScreen(link: link, placeholder: placeholder)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("CONTENT")
                        .scaledFont(size: 12, weight: .heavy)
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12.5, weight: .bold)
                        .foregroundStyle(Palette.accent)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .scaledFont(size: 16)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loading {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Loading from Lectio…")
                            .scaledFont(size: 15)
                            .foregroundStyle(.secondary)
                    }
                }
                if !summary.isEmpty {
                    Text(summary)
                        .scaledFont(size: 13.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.primary)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCard())
        .accessibilityHint("Opens the homework and everything else for this lesson")
    }

    /// Elevfeedback is a tab on the same Lectio page, so it costs one more
    /// request — made only when a lesson page is actually open, never while
    /// drawing a week of the schedule.
    private func feedbackCard(_ feedback: LessonFeedback) -> some View {
        Button { showFeedback = true } label: {
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

    /// The page and its Elevfeedback together, through the shared cache (the
    /// Content page then opens with the page already here).
    private func load() async {
        guard !link.isEmpty, !loading else { return }
        let cache = LessonCache.shared
        let wantFeedback = !feedbackTitle.isEmpty
        guard !cache.isDetailFresh(link) || (wantFeedback && !cache.isFeedbackFresh(link)) else {
            detail = cache.detail(link)
            if wantFeedback { feedback = cache.feedback(link) }
            return
        }

        loading = detail == nil
        let cookies = await session.requestCookies()
        await cache.load(link, detail: true, feedback: wantFeedback, cookies: cookies)
        loading = false

        if let fresh = cache.detail(link) { detail = fresh }
        // A lesson without the tab is normal, not an error worth a banner.
        if wantFeedback, let fresh = cache.feedback(link) { feedback = fresh }
    }

    /// After the Elevfeedback sheet closes: what was just written, fresh.
    private func loadFeedback(force: Bool) async {
        guard !feedbackTitle.isEmpty, !link.isEmpty else { return }
        guard force || feedback == nil else { return }
        let cookies = await session.requestCookies()
        if let fresh = try? await LectioFeedbackService.load(lessonLink: link, cookies: cookies) {
            feedback = fresh
            LessonCache.shared.store(feedback: fresh, for: link)
        }
    }
}

/// A lesson's Content page, pushed from its Content card: the note, the
/// homework and everything else on the lesson's Lectio page, in full.
struct LessonContentScreen: View {
    let link: String
    var placeholder: String = ""

    var body: some View {
        ScrollView {
            LessonContentView(link: link, placeholder: placeholder)
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        // Small in the bar, as the lesson page's own title is.
        .navigationTitle("Content")
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}
