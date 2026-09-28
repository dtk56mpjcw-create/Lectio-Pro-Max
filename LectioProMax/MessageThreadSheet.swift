import SwiftUI

struct MessageThreadSheet: View {
    let summary: MessageThreadSummary

    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var thread: MessageThread?
    @State private var loadError: String?
    @State private var reply = ""
    @State private var includeSignature = true
    @State private var attachments: [OutgoingAttachment] = []
    @State private var sending = false
    @State private var sendError: String?
    @State private var preview: PreviewDocument?
    @State private var downloading: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline

                    if loadError != nil {
                        EmptyNotice(icon: "arrow.clockwise", text: "Couldn't reach Lectio")
                    } else if thread == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    }

                    if let thread = thread {
                        ForEach(thread.messages) { message in
                            messageCard(message)
                        }
                        if thread.canReply {
                            replyBox
                        } else {
                            EmptyNotice(icon: "lock", text: "This thread can't be replied to")
                        }
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .task { await load() }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(thread?.subject.isEmpty == false ? thread!.subject : summary.subject)
                .scaledFont(size: 25, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .sheetTitleSpacing()
            if let recipients = thread?.recipients, !recipients.isEmpty {
                Text(recipients)
                    .scaledFont(size: 13.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func messageCard(_ message: ThreadMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(message.sender)
                    .scaledFont(size: 15, weight: .semibold)
                Spacer(minLength: 0)
                Text(message.date)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
            }
            if let blocks = message.blocks, !blocks.isEmpty {
                // Links tappable, pictures shown, as the sender wrote it.
                LessonBlocksView(blocks: blocks)
            } else if !message.body.isEmpty {
                Text(message.body)
                    .scaledFont(size: 16)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.attachments) { attachment in
                Button {
                    Task { await download(attachment) }
                } label: {
                    HStack(spacing: 7) {
                        if downloading == attachment.link {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperclip")
                                .scaledFont(size: 12.5, weight: .semibold)
                                .foregroundStyle(Palette.accent)
                        }
                        Text(attachment.name)
                            .scaledFont(size: 14.5, weight: .semibold)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(downloading != nil)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 3)
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reply")
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)

            TextField("Write a reply…", text: $reply, axis: .vertical)
                .scaledFont(size: 16)
                .lineLimit(4...10)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(sending)

            SignatureFooter(include: $includeSignature)

            AttachmentTray(attachments: $attachments, disabled: sending)

            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 9) {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill").scaledFont(size: 14, weight: .semibold)
                    }
                    Text(sending ? (attachments.isEmpty ? "Sending…" : "Uploading and sending…") : "Send reply")
                        .scaledFont(size: 16.5, weight: .semibold)
                    Spacer()
                }
                .foregroundStyle(Palette.accent)
                .padding(15)
                .frame(maxWidth: .infinity)
                .contentCard(radius: Metrics.inner + 2)
            }
            .buttonStyle(PressableCard())
            .disabled(sending || !hasSomethingToSend)
            .opacity(hasSomethingToSend ? 1 : 0.45)
        }
    }

    // MARK: Work

    private func load() async {
        loadError = nil
        session.markThreadOpened(summary.id)
        let cookies = await session.requestCookies()
        do {
            thread = try await LectioMessagesService.loadThread(id: summary.id, cookies: cookies)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Words, or at least a photo or file.
    private var hasSomethingToSend: Bool {
        !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func send() async {
        guard let current = thread else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSomethingToSend else { return }

        sending = true
        sendError = nil
        let cookies = await session.requestCookies()
        do {
            thread = try await LectioMessagesService.reply(
                to: current,
                body: MessageSignature.apply(to: text, include: includeSignature),
                attachments: attachments,
                cookies: cookies)
            reply = ""
            attachments = []
            includeSignature = true
            await session.loadInbox(force: true)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    private func download(_ attachment: MessageAttachment) async {
        downloading = attachment.link
        defer { downloading = nil }
        let cookies = await session.requestCookies()
        do {
            let file = try await LectioHandInService.downloadDocument(
                link: attachment.link, suggestedName: attachment.name, cookies: cookies)
            preview = PreviewDocument(url: file)
        } catch {
            sendError = error.localizedDescription
        }
    }
}
