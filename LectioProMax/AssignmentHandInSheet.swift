import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The hand-in screen: what Lectio's ElevAflevering page gives you, natively.
struct AssignmentHandInSheet: View {
    let item: WorkItem
    let link: String
    let done: Bool
    let toggle: () -> Void

    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss

    @State private var handIn: HandIn?
    @State private var loadError: String?
    @State private var comment = ""
    @State private var busy: String?          // non-nil while uploading
    @State private var actionError: String?
    @State private var justSent = false

    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var preview: PreviewDocument?
    @State private var downloading: String?

    private var tint: Color { Color.forSubject(item.code) }

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 20) {
                headline

                if loadError != nil {
                    EmptyNotice(icon: "arrow.clockwise", text: "Couldn't reach Lectio")
                } else if handIn == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                if let handIn = handIn {
                    statusCard(handIn.status)
                    entriesSection(handIn.entries)
                    if handIn.canHandIn {
                        handInSection
                    } else {
                        EmptyNotice(icon: "lock", text: "Lectio has closed this assignment")
                    }
                }

                openInLectio
            }
        }
        .task { await load() }
        .onChange(of: photoItem) { _, newValue in
            guard let newValue = newValue else { return }
            Task { await sendPickedPhoto(newValue) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            Task { await sendPickedFile(result) }
        }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
    }

    // MARK: Header

    private var headline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SubjectDot(code: item.code, size: 9)
                Text(item.code.uppercased())
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(LectioDates.tidy(item.title))
                .font(.system(size: 25.5, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            if let due = item.due {
                Text("Due " + LectioDates.friendlyLabel(iso: due)
                     + (item.dueTime.isEmpty ? "" : " · " + item.dueTime))
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
            }
        }
    }

    // MARK: Status

    private func statusCard(_ status: HandInStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: status.isDelivered ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(status.isDelivered ? tint : Palette.accent)
                Text(status.isDelivered ? "Handed in" : "Not handed in")
                    .font(.system(size: 17.5, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            if !status.deliveryLine.isEmpty {
                detailRow("Status", status.deliveryLine)
            }
            if !status.waitingFor.isEmpty {
                detailRow("Waiting on", status.waitingOnTeacher ? "Teacher" : "You")
            }
            if !status.grade.isEmpty { detailRow("Grade", status.grade) }
            if !status.gradeNote.isEmpty { detailRow("Grade note", status.gradeNote) }
            if !status.studentNote.isEmpty { detailRow("Note to you", status.studentNote) }
            if status.finished { detailRow("Closed", "Yes") }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.58))
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 14.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Existing hand-ins

    private func entriesSection(_ entries: [HandInEntry]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Handed in")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.6))

            if entries.isEmpty {
                EmptyNotice(icon: "tray", text: "Nothing handed in yet")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        if !entry.document.isEmpty {
                            documentRow(entry)
                        }
                        if !entry.comment.isEmpty {
                            Text(entry.comment)
                                .font(.system(size: 14.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text([entry.user, entry.time].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.58))
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(radius: Metrics.inner)
                }
            }
        }
    }

    /// Opens the file in the app. A plain Link would hand the URL to Safari,
    /// which has its own cookie jar and is often met with the login page.
    private func documentRow(_ entry: HandInEntry) -> some View {
        Button {
            Task { await open(entry) }
        } label: {
            HStack(spacing: 7) {
                if downloading == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(entry.document)
                    .font(.system(size: 15.5, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if entry.documentLink != nil {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.documentLink == nil || downloading != nil)
    }

    private func open(_ entry: HandInEntry) async {
        guard let link = entry.documentLink else { return }
        actionError = nil
        downloading = entry.id
        defer { downloading = nil }

        let cookies = await session.requestCookies()
        do {
            let file = try await LectioHandInService.downloadDocument(
                link: link, suggestedName: entry.document, cookies: cookies)
            preview = PreviewDocument(url: file)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Hand in

    private var handInSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Add to this assignment")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.6))

            TextField("Comment (optional)", text: $comment, axis: .vertical)
                .font(.system(size: 15.5))
                .lineLimit(3...6)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(busy != nil)

            if let busy = busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busy)
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(radius: Metrics.inner)
            } else {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    actionLabel("photo.on.rectangle", "Choose a photo")
                }
                Button { showFileImporter = true } label: {
                    actionLabel("folder", "Choose a file")
                }
                .buttonStyle(PressableCard())

                Button {
                    Task { await sendCommentOnly() }
                } label: {
                    actionLabel("text.bubble", "Send comment only")
                }
                .buttonStyle(PressableCard())
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }

            if justSent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                    Text("Sent to Lectio")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 16.5, weight: .semibold, design: .rounded))
            Spacer()
        }
        .foregroundStyle(Palette.accent)
        .padding(15)
        .frame(maxWidth: .infinity)
        .contentCard(radius: Metrics.inner + 2)
    }

    private var openInLectio: some View {
        Group {
            if let url = URL(string: link) {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").font(.system(size: 15, weight: .semibold))
                        Text("Open in Lectio")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(15)
                    .frame(maxWidth: .infinity)
                    .contentCard(radius: Metrics.inner + 2)
                }
            }
        }
    }

    // MARK: Work

    private func load() async {
        loadError = nil
        let cookies = await session.requestCookies()
        do {
            handIn = try await LectioHandInService.load(pageURL: link, cookies: cookies)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sendPickedPhoto(_ pick: PhotosPickerItem) async {
        photoItem = nil
        busy = "Reading photo…"
        actionError = nil
        defer { busy = nil }

        guard let raw = try? await pick.loadTransferable(type: Data.self), !raw.isEmpty else {
            actionError = "Couldn't read that photo."
            return
        }
        // Lectio (and teachers' laptops) deal with HEIC badly, so hand in a JPEG.
        let suggested = pick.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        var data = raw
        var filename = "Photo-\(stamp()).\(suggested)"
        var mime = pick.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        if suggested.lowercased() == "heic" || suggested.lowercased() == "heif" {
            if let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.9) {
                data = jpeg
                filename = "Photo-\(stamp()).jpg"
                mime = "image/jpeg"
            }
        }
        await send(data: data, filename: filename, mime: mime)
    }

    private func sendPickedFile(_ result: Result<[URL], Error>) async {
        actionError = nil
        switch result {
        case .failure(let error):
            actionError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            busy = "Reading file…"
            defer { busy = nil }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                actionError = "Couldn't read that file."
                return
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            await send(data: data, filename: url.lastPathComponent, mime: mime)
        }
    }

    private func send(data: Data, filename: String, mime: String) async {
        guard var current = handIn else { return }
        actionError = nil
        justSent = false

        let cookies = await session.requestCookies()
        do {
            // Lectio's __VIEWSTATEX and __EVENTVALIDATION are per-request, so
            // re-read the page immediately before posting it back.
            busy = "Uploading \(filename)…"
            current = try await LectioHandInService.load(pageURL: link, cookies: cookies)
            guard current.canHandIn else { throw LectioHandInService.UploadError.notAcceptingHandIns }

            let documentID = try await LectioHandInService.uploadDocument(
                data: data, filename: filename, mimeType: mime, cookies: cookies)

            busy = "Attaching to the assignment…"
            let updated = try await LectioHandInService.attachDocument(
                serializedID: documentID,
                comment: comment,
                to: current,
                cookies: cookies)

            handIn = updated
            comment = ""
            justSent = true
            await session.refresh()
        } catch {
            actionError = error.localizedDescription
        }
        busy = nil
    }

    private func sendCommentOnly() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actionError = nil
        justSent = false
        busy = "Sending comment…"
        defer { busy = nil }

        let cookies = await session.requestCookies()
        do {
            let current = try await LectioHandInService.load(pageURL: link, cookies: cookies)
            let updated = try await LectioHandInService.sendComment(text, to: current, cookies: cookies)
            handIn = updated
            comment = ""
            justSent = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}
