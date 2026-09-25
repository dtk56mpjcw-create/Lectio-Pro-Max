import SwiftUI

struct MessagesTab: View {
    @EnvironmentObject private var session: LectioSession
    @State private var composing = false

    private var threads: [MessageThreadSummary] {
        if !session.threads.isEmpty { return session.threads }
        // Until the full inbox lands (or if it fails), fall back to the handful
        // of previews the dashboard page already gave us.
        return session.snapshot.messages.compactMap { preview in
            guard let link = preview.link, let g = Rx.match("id=(\\d+)", link) else { return nil }
            return MessageThreadSummary(id: g[1],
                                        subject: preview.subject,
                                        latestSender: preview.sender,
                                        firstSender: preview.sender,
                                        recipients: "",
                                        changed: preview.date)
        }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Messages")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            composing = true
                        } label: {
                            Label("New message", systemImage: "square.and.pencil")
                        }
                    }
                }
                // A thread opens as a page of its own, with the system back
                // button. Writing a new message stays a sheet: it's a task
                // you finish or cancel.
                .navigationDestination(for: MessageThreadSummary.self) { thread in
                    MessageThreadSheet(summary: thread).asPushedScreen()
                }
        }
        .task { await session.loadInbox() }
        .sheet(isPresented: $composing) {
            NewMessageSheet().environmentObject(session)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if threads.isEmpty {
                    if session.inboxLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        EmptyNotice(icon: "tray", text: "No messages")
                    }
                } else {
                    ForEach(threads) { thread in
                        ThreadRow(thread: thread)
                    }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // The system's own pull to refresh, the work in a task of its own so
        // an update mid-refresh can't cancel it.
        .refreshable {
            await Task {
                await session.refresh()
                await session.loadInbox(force: true)
            }.value
        }
        .background { AppBackground() }
    }

    private var subtitle: String {
        if session.inboxLoading && threads.isEmpty { return "Loading…" }
        let unread = threads.filter { $0.unread }.count
        if unread == 0 { return "Nothing new" }
        return unread == 1 ? "1 unread" : "\(unread) unread"
    }
}

// MARK: - Row

struct ThreadRow: View {
    @EnvironmentObject private var session: LectioSession
    let thread: MessageThreadSummary

    var body: some View {
        NavigationLink(value: thread) { row }
            .buttonStyle(PressableCard())
            .contextMenu {
                Button {
                    Task { await toggleRead() }
                } label: {
                    Label(thread.unread ? "Mark as read" : "Mark as unread",
                          systemImage: thread.unread ? "envelope.open" : "envelope.badge")
                }
                Button {
                    Task { await toggleFlag() }
                } label: {
                    Label(thread.flagged ? "Remove flag" : "Flag", systemImage: "flag")
                }
            }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(thread.unread ? Palette.accent : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.subject)
                        .font(.system(size: 17, weight: thread.unread ? .semibold : .medium))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if thread.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.accent)
                    }
                    if thread.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(metaLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        // A link's label takes the accent colour otherwise.
        .foregroundStyle(.primary)
    }

    private var metaLine: String {
        var bits: [String] = []
        if !thread.latestSender.isEmpty { bits.append(thread.latestSender) }
        if !thread.changed.isEmpty { bits.append(thread.changed) }
        return bits.joined(separator: " · ")
    }

    private func toggleRead() async {
        let cookies = await session.requestCookies()
        if let updated = try? await LectioMessagesService.toggleRead(threadID: thread.id, cookies: cookies) {
            session.applyThreads(updated)
        }
    }

    private func toggleFlag() async {
        let cookies = await session.requestCookies()
        if let updated = try? await LectioMessagesService.toggleFlag(threadID: thread.id, cookies: cookies) {
            session.applyThreads(updated)
        }
    }
}
