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

    // Group hand-in.
    @State private var choosingMember = false
    @State private var groupBusy: String?
    @State private var confirmRemove: GroupPerson?
    /// Just added, for a moment's tick next to their name.
    @State private var justAdded: String?

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
                    if handIn.isGroup {
                        groupSection(handIn)
                    }
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
        // A tap you can feel when Lectio confirms a hand-in or a new member.
        .sensoryFeedback(.success, trigger: justSent) { _, sent in sent }
        .sensoryFeedback(.success, trigger: justAdded) { _, added in added != nil }
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
        .sheet(isPresented: $choosingMember) {
            GroupMemberPicker(candidates: handIn?.groupCandidates ?? []) { person in
                choosingMember = false
                Task { await addMember(person) }
            }
        }
        .confirmationDialog(
            "Take \(confirmRemove?.name ?? "them") off this group hand-in?",
            isPresented: Binding(get: { confirmRemove != nil },
                                 set: { if !$0 { confirmRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove from group", role: .destructive) {
                if let person = confirmRemove {
                    confirmRemove = nil
                    Task { await removeMember(person) }
                }
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        }
    }

    // MARK: Header

    private var headline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SubjectDot(code: item.code, size: 9)
                Text(item.displayCode)
                    .scaledFont(size: 14, weight: .heavy)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(item.displayTitle)
                .scaledFont(size: 25.5, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
            if let due = item.due {
                Text("Due " + LectioDates.friendlyLabel(iso: due)
                     + (item.dueTime.isEmpty ? "" : " · " + item.dueTime))
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    private func statusCard(_ status: HandInStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: status.isDelivered ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(status.isDelivered ? Palette.positive : Palette.warning)
                Text(status.isDelivered ? "Handed in" : "Not handed in")
                    .scaledFont(size: 17.5, weight: .semibold)
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
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .scaledFont(size: 14.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Group hand-in

    private func groupSection(_ handIn: HandIn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Group")
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(handIn.groupMembers.enumerated()), id: \.element.id) { index, person in
                    if index > 0 { Divider().padding(.leading, 57) }
                    HStack(spacing: 11) {
                        PersonAvatar(target: person.asTarget, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name)
                                .scaledFont(size: 16, weight: .medium)
                            if !person.className.isEmpty {
                                Text(person.className)
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if justAdded == person.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        } else if person.removeTarget != nil && groupBusy == nil {
                            Button {
                                confirmRemove = person
                            } label: {
                                Image(systemName: "minus.circle")
                                    .scaledFont(size: 18, weight: .semibold)
                                    .foregroundStyle(.red)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(person.name)")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
            .contentCard(radius: Metrics.inner + 2)

            if let busy = groupBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busy)
                        .scaledFont(size: 15, weight: .medium)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(radius: Metrics.inner)
            } else if !handIn.groupCandidates.isEmpty {
                Button {
                    choosingMember = true
                } label: {
                    actionLabel("person.badge.plus", "Add to group")
                }
                .buttonStyle(PressableCard())
            }
        }
    }

    // MARK: Existing hand-ins

    private func entriesSection(_ entries: [HandInEntry]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Handed in")
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)

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
                                .scaledFont(size: 14.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text([entry.user, entry.time].filter { !$0.isEmpty }.joined(separator: " · "))
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(.secondary)
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
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(tint)
                }
                Text(entry.document)
                    .scaledFont(size: 15.5, weight: .semibold)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if entry.documentLink != nil {
                    Image(systemName: "arrow.down.circle")
                        .scaledFont(size: 13.5, weight: .semibold)
                        .foregroundStyle(.secondary)
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
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)

            TextField("Comment (optional)", text: $comment, axis: .vertical)
                .scaledFont(size: 15.5)
                .lineLimit(3...6)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(busy != nil)

            if let busy = busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busy)
                        .scaledFont(size: 15, weight: .medium)
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
                        .foregroundStyle(.green)
                    Text("Sent to Lectio")
                        .scaledFont(size: 15, weight: .semibold)
                }
            }
        }
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).scaledFont(size: 15, weight: .semibold)
            Text(title).scaledFont(size: 16.5, weight: .semibold)
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
                        Image(systemName: "safari").scaledFont(size: 15, weight: .semibold)
                        Text("Open in Lectio")
                            .scaledFont(size: 16, weight: .semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right").scaledFont(size: 12.5, weight: .bold)
                    }
                    .foregroundStyle(.secondary)
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

    /// Adds a classmate the way Lectio's Tilføj button does, on a freshly
    /// read page (its hidden state is per request), then shows the group as
    /// Lectio has it afterwards — that list is the confirmation.
    private func addMember(_ person: GroupPerson) async {
        groupBusy = "Adding \(person.name)…"
        defer { groupBusy = nil }
        let cookies = await session.requestCookies()
        do {
            let current = try await LectioHandInService.load(pageURL: link, cookies: cookies)
            guard current.groupCandidates.contains(where: { $0.id == person.id }) else {
                handIn = current          // already in, or no longer offered
                return
            }
            let updated = try await LectioHandInService.addGroupMember(person.id, to: current, cookies: cookies)
            handIn = updated
            if updated.groupMembers.contains(where: { $0.id == person.id }) {
                withAnimation(.snappy) { justAdded = person.id }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.snappy) { if justAdded == person.id { justAdded = nil } }
                }
            }
        } catch {
            // Reload so what's on screen is what Lectio actually has.
            await load()
        }
    }

    private func removeMember(_ person: GroupPerson) async {
        groupBusy = "Removing \(person.name)…"
        defer { groupBusy = nil }
        let cookies = await session.requestCookies()
        do {
            let current = try await LectioHandInService.load(pageURL: link, cookies: cookies)
            guard let fresh = current.groupMembers.first(where: { $0.id == person.id }) else {
                handIn = current
                return
            }
            handIn = try await LectioHandInService.removeGroupMember(fresh, from: current, cookies: cookies)
        } catch {
            await load()
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}
