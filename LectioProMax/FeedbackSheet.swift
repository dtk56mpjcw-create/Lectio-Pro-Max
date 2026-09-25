import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Elevfeedback, natively.
///
/// Writing here is a real write to a real school account, so the rules are:
/// nothing is ever saved without a tap on Save, the text is read from Lectio
/// first so you're editing what's there rather than replacing it blind, the
/// service verifies the save instead of trusting a 200, and whatever you type is
/// kept on the phone until Lectio confirms it has it.
struct FeedbackSheet: View {
    let lessonLink: String
    let title: String
    let code: String

    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = FeedbackEditor()

    @State private var feedback: LessonFeedback?
    @State private var initial = NSAttributedString()
    @State private var ready = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var busy: String?
    @State private var saved = false
    @State private var restoredDraft = false
    @State private var preview: PreviewDocument?
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var draftTask: Task<Void, Never>?
    @State private var confirmingDelete = false
    /// Decided once, when the sheet loads, and never again.
    ///
    /// The branch the text view sits in used to be driven by `feedback`, which is
    /// reassigned on every save. Any change to `available` or `editable` there —
    /// and Lectio answers a save in whichever mode it likes, so `available` can
    /// flicker — tore the text view down and built a new one, seeded from the
    /// text as it was when the sheet opened. Two text views, two copies of the
    /// document, and the wrong one could be the one that got saved. The editor is
    /// now built once and stays built.
    @State private var editing = false

    private var tint: Color { Color.forSubject(code) }

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if loadError != nil {
                    EmptyNotice(icon: "arrow.clockwise", text: "Couldn't reach Lectio")
                } else if !ready {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if editing {
                    editorBody
                } else if let feedback = feedback, feedback.available {
                    readOnly(feedback)
                } else {
                    EmptyNotice(icon: "square.and.pencil",
                                text: "This lesson has no Elevfeedback")
                }

                if let feedback = feedback, feedback.canDelete {
                    deleteRow
                }

                openInLectio
            }
        }
        .task { await load() }
        .onChange(of: editor.revision) { _, _ in scheduleDraftSave() }
        .onChange(of: photoItem) { _, item in
            guard let item = item else { return }
            Task { await attachPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            Task { await attachFile(result) }
        }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubjectDot(code: code, size: 9)
                Text("ELEVFEEDBACK")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Read-only content

    private func readOnly(_ feedback: LessonFeedback) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // A plain line, not a warning: nothing has gone wrong here, there's
            // just something this editor won't touch.
            Text("Written with a table or an image — edit this one in Lectio.")
                .font(.system(size: 14.5))
                .foregroundStyle(.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            if !feedback.plainText.isEmpty {
                Text(feedback.plainText)
                    .font(.system(size: 16.5))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(radius: Metrics.inner + 2)
            }
        }
    }

    // MARK: - Editing

    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if restoredDraft {
                Text("Restored what you were typing — not saved to Lectio yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary.opacity(0.55))
            }

            formatBar

            FeedbackTextView(editor: editor, initial: initial)
                .frame(minHeight: 220)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(radius: Metrics.inner + 2)

            attachRow
            saveRow
        }
    }

    private var formatBar: some View {
        HStack(spacing: 7) {
            formatButton("bold", on: editor.bold) { editor.toggle(.bold) }
            formatButton("italic", on: editor.italic) { editor.toggle(.italic) }
            // No underline button on purpose: Lectio's editor hasn't got one
            // either, and its content filter deletes <u> on the way in.
            formatButton("strikethrough", on: editor.strike) { editor.toggle(.strike) }
            Divider().frame(height: 22).opacity(0.4)
            formatButton("list.bullet", on: editor.list == "ul") { editor.toggleList("ul") }
            formatButton("list.number", on: editor.list == "ol") { editor.toggleList("ol") }
            Spacer(minLength: 0)
        }
    }

    private func formatButton(_ icon: String,
                              on: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(on ? Color.white : .primary.opacity(0.75))
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? Palette.accent : Color.clear)
                )
                .contentCard(radius: 9)
        }
        .buttonStyle(PressableCard())
    }

    private var attachRow: some View {
        HStack(spacing: 9) {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                attachLabel("photo", "Photo")
            }
            Button { showFileImporter = true } label: {
                attachLabel("folder", "File")
            }
            .buttonStyle(PressableCard())
            Spacer(minLength: 0)
        }
        .disabled(busy != nil)
    }

    private func attachLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 14.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Palette.accent)
        .padding(.vertical, 9)
        .padding(.horizontal, 13)
        .contentCard(radius: Metrics.inner)
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let busy = busy {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(busy).font(.system(size: 14.5)).foregroundStyle(.primary.opacity(0.7))
                }
            } else if saved {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                    Text("Saved to Lectio")
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                }
            }

            HStack(spacing: 9) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Save to Lectio")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.inner + 2, style: .continuous)
                            .fill(Palette.accent.opacity(editor.hasEdits ? 1 : 0.4))
                    )
                }
                .buttonStyle(PressableCard())
                .disabled(busy != nil || !editor.hasEdits)

                Button(action: exportFile) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 46, height: 44)
                        .contentCard(radius: Metrics.inner + 2)
                }
                .buttonStyle(PressableCard())
                .disabled(busy != nil)
            }
        }
    }

    /// Lectio's own delete, which removes the whole content block rather than
    /// saving an empty one. Offered even when the content is too rich for the
    /// app to edit — being unable to fix a table is no reason to be unable to
    /// throw it away.
    private var deleteRow: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash").font(.system(size: 14.5, weight: .semibold))
                Text("Delete feedback")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(Palette.ember)
            .padding(15)
            .frame(maxWidth: .infinity)
            .contentCard(radius: Metrics.inner + 2)
        }
        .buttonStyle(PressableCard())
        .disabled(busy != nil)
        .confirmationDialog("Delete this feedback in Lectio?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteFeedback() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("It's removed from Lectio for good — the app can't undo it.")
        }
    }

    private var openInLectio: some View {
        Group {
            if let feedback = feedback,
               !feedback.pageURL.isEmpty,
               let url = URL(string: feedback.pageURL) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").font(.system(size: 15, weight: .semibold))
                        Text("Open in Lectio")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
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

    // MARK: - Loading

    private func load() async {
        guard !ready, loadError == nil else { return }
        let cookies = await session.requestCookies()
        do {
            let loaded = try await LectioFeedbackService.load(lessonLink: lessonLink,
                                                             cookies: cookies)
            var startingHTML = loaded.html
            if let draft = FeedbackDrafts.draft(for: lessonLink),
               FeedbackHTML.plainText(draft) != FeedbackHTML.plainText(loaded.html) {
                startingHTML = draft
                restoredDraft = true
            }
            initial = FeedbackHTML.attributed(from: startingHTML)
            feedback = loaded
            editing = loaded.available && loaded.editable
        } catch {
            loadError = error.localizedDescription
        }
        ready = true
    }

    // MARK: - Saving

    private func save() async {
        // A queued second tap must not start a second save: two of them racing
        // each other is how a document ends up written twice.
        guard busy == nil, let current = feedback else { return }
        let html = editor.html

        busy = "Saving to Lectio…"
        actionError = nil
        saved = false
        defer { busy = nil }

        let cookies = await session.requestCookies()
        do {
            let updated = try await LectioFeedbackService.save(current,
                                                              html: html,
                                                              cookies: cookies)
            feedback = updated

            // Adopt what Lectio stored, rather than carrying on with our own
            // copy of it. Its version is the one that exists.
            if updated.hasEditor {
                editor.reseed(FeedbackHTML.attributed(from: updated.html))
            } else {
                editor.revision = 0
            }

            // Cancel before clearing: a draft write queued by the last keystroke
            // would otherwise land just after the clear and resurrect the draft.
            draftTask?.cancel()
            draftTask = nil
            FeedbackDrafts.clear(for: lessonLink)
            restoredDraft = false
            saved = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteFeedback() async {
        guard busy == nil, let current = feedback else { return }
        busy = "Deleting in Lectio…"
        actionError = nil
        saved = false
        defer { busy = nil }

        let cookies = await session.requestCookies()
        do {
            _ = try await LectioFeedbackService.deleteContent(current, cookies: cookies)
            draftTask?.cancel()
            draftTask = nil
            FeedbackDrafts.clear(for: lessonLink)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func scheduleDraftSave() {
        // Only ever writes a draft for edits you actually made. Without this the
        // reset after a save counts as a change and writes the draft straight
        // back, which is what made a cleared draft come back from the dead.
        guard editor.hasEdits else { return }
        saved = false
        let html = editor.html
        draftTask?.cancel()
        draftTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            FeedbackDrafts.save(html, for: lessonLink)
        }
    }

    // MARK: - Attaching

    private func attachPhoto(_ pick: PhotosPickerItem) async {
        photoItem = nil
        actionError = nil
        busy = "Reading photo…"
        defer { busy = nil }

        guard let raw = try? await pick.loadTransferable(type: Data.self), !raw.isEmpty else {
            actionError = "Couldn't read that photo."
            return
        }
        // HEIC is a bad thing to hand a teacher's laptop, so convert to JPEG.
        let extensionName = pick.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        var data = raw
        var filename = "Photo-\(stamp()).\(extensionName)"
        var mime = pick.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        if extensionName.lowercased() == "heic" || extensionName.lowercased() == "heif" {
            if let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.9) {
                data = jpeg
                filename = "Photo-\(stamp()).jpg"
                mime = "image/jpeg"
            }
        }
        await upload(data: data, filename: filename, mime: mime)
    }

    private func attachFile(_ result: Result<[URL], Error>) async {
        actionError = nil
        switch result {
        case .failure(let error):
            actionError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            busy = "Reading file…"
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                busy = nil
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                actionError = "Couldn't read that file."
                return
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            await upload(data: data, filename: url.lastPathComponent, mime: mime)
        }
    }

    /// Uploading puts the file in Lectio's document archive and gives back the
    /// anchor for it. Note this does NOT save the feedback — the file is only
    /// attached once you tap Save, same as in Lectio.
    private func upload(data: Data, filename: String, mime: String) async {
        busy = "Uploading \(filename)…"
        defer { busy = nil }
        let cookies = await session.requestCookies()
        do {
            let anchor = try await LectioFeedbackService.attach(data: data,
                                                               filename: filename,
                                                               mimeType: mime,
                                                               cookies: cookies)
            editor.insert(html: anchor)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Export

    /// RTF rather than a PDF: it keeps the bold, the italics and the lists, opens
    /// in Pages, Word and Notes, and needs no pagination guesswork.
    private func exportFile() {
        guard let text = editor.view?.attributedText, text.length > 0 else {
            actionError = "Nothing to export yet."
            return
        }
        do {
            let data = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LectioExports", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let safe = (code.isEmpty ? "Feedback" : code.uppercased() + " feedback")
                .replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent("\(safe) \(stamp()).rtf")
            try data.write(to: url, options: .atomic)
            preview = PreviewDocument(url: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date())
    }
}
