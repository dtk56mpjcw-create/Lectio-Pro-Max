import SwiftUI

/// Messages: Lectio's folders, with the actions Mail has — swipe a thread to
/// delete or flag it, swipe the other way to mark it read or unread, or hold
/// it for the same in a menu. Deleting can be undone for a few seconds, and
/// for good from the Deleted folder, because Lectio's own delete ("Slet/
/// gendan") only moves a thread there.
struct MessagesTab: View {
    @EnvironmentObject private var session: LectioSession
    @State private var composing = false
    @State private var path: [MessageThreadSummary] = []

    @State private var folder: MessageFolder = .newest
    /// Threads of any folder but Newest, which lives on the session (the
    /// unread badge and Search read it too).
    @State private var folderThreads: [MessageThreadSummary] = []
    @State private var folderLoading = false

    /// The thread just deleted, while its Undo is on screen.
    @State private var undoable: MessageThreadSummary?
    @State private var undoTask: Task<Void, Never>?
    @State private var deleteCount = 0

    /// "Sent", after a new message goes out, with the thread to open once
    /// the inbox has it.
    @State private var sentShown = false
    @State private var sentThread: MessageThreadSummary?
    @State private var sentTask: Task<Void, Never>?
    @State private var sentCount = 0

    private var threads: [MessageThreadSummary] {
        guard folder == .newest else { return folderThreads }
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

    private var loading: Bool {
        folder == .newest ? session.inboxLoading : folderLoading
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(folder.title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Folder", selection: $folder) {
                                ForEach(MessageFolder.allCases) { option in
                                    Label(option.menuTitle, systemImage: option.icon).tag(option)
                                }
                            }
                        } label: {
                            Label("Folders", systemImage: "tray.2")
                        }
                    }
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
        .task(id: folder) { await loadFolder() }
        .onChange(of: folder) {
            // Don't show the last folder's threads under the new title.
            folderThreads = []
            undoTask?.cancel()
            undoable = nil
        }
        .sensoryFeedback(.success, trigger: deleteCount)
        .sensoryFeedback(.success, trigger: sentCount)
        .sheet(isPresented: $composing) {
            NewMessageSheet(onSent: { subject in
                Task { await messageSent(subject) }
            })
            .environmentObject(session)
        }
    }

    // MARK: List

    /// A List rather than a stack of cards, because only a List gives rows
    /// the system's swipe actions. Rows still look like cards.
    private var list: some View {
        List {
            if threads.isEmpty {
                Group {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        EmptyNotice(icon: folder.icon, text: folder.emptyText)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(threads) { thread in
                    ThreadRow(thread: thread,
                              onOpen: { path.append(thread) },
                              onRead: { Task { await setRead(thread, thread.unread) } },
                              onFlag: { Task { await flag(thread) } },
                              onDelete: { Task { await delete(thread) } },
                              inDeleted: folder == .deleted)
                        .listRowInsets(EdgeInsets(top: 4.5, leading: Metrics.margin,
                                                  bottom: 4.5, trailing: Metrics.margin))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if folder == .deleted {
                                Button {
                                    Task { await delete(thread) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.green)
                            } else {
                                Button(role: .destructive) {
                                    Task { await delete(thread) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await flag(thread) }
                                } label: {
                                    Label(thread.flagged ? "Unflag" : "Flag",
                                          systemImage: thread.flagged ? "flag.slash" : "flag")
                                }
                                .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await setRead(thread, thread.unread) }
                            } label: {
                                Label(thread.unread ? "Read" : "Unread",
                                      systemImage: thread.unread ? "envelope.open" : "envelope.badge")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        // The system's own pull to refresh, the work in a task of its own so
        // an update mid-refresh can't cancel it.
        .refreshable {
            await Task {
                if folder == .newest {
                    await session.refresh()
                    await session.loadInbox(force: true)
                } else {
                    await loadFolder()
                }
            }.value
        }
        .safeAreaInset(edge: .bottom) {
            if let thread = undoable {
                undoBar(thread)
                    .padding(.horizontal, Metrics.margin)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if sentShown {
                sentBar
                    .padding(.horizontal, Metrics.margin)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: undoable?.id)
        .animation(.snappy, value: sentShown)
        .animation(.snappy, value: sentThread?.id)
    }

    private func undoBar(_ thread: MessageThreadSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Deleted")
                .font(.system(size: 15.5, weight: .medium))
            Spacer(minLength: 0)
            Button("Undo") {
                Task { await undoDelete(thread) }
            }
            .font(.system(size: 15.5, weight: .semibold))
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .glassEffect(.regular, in: .capsule)
    }

    private var sentBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
            Text("Message sent")
                .font(.system(size: 15.5, weight: .medium))
            Spacer(minLength: 0)
            if let thread = sentThread {
                Button("View") {
                    hideSent()
                    path.append(thread)
                }
                .font(.system(size: 15.5, weight: .semibold))
                .frame(minHeight: 44)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .glassEffect(.regular, in: .capsule)
    }

    private var subtitle: String {
        if loading && threads.isEmpty { return "Loading…" }
        if folder != .newest {
            return threads.count == 1 ? "1 message" : "\(threads.count) messages"
        }
        let unread = threads.filter { $0.unread }.count
        if unread == 0 { return "Nothing new" }
        return unread == 1 ? "1 unread" : "\(unread) unread"
    }

    // MARK: Work

    private func loadFolder() async {
        guard folder != .newest else { return }
        folderLoading = true
        defer { folderLoading = false }
        let cookies = await session.requestCookies()
        let showing = folder
        if let loaded = try? await LectioMessagesService.loadFolder(showing, cookies: cookies),
           showing == folder {
            folderThreads = loaded
        }
    }

    /// What Lectio returns after a command is the folder as it now stands.
    private func apply(_ updated: [MessageThreadSummary], from origin: MessageFolder) {
        if origin == .newest {
            session.applyThreads(updated)
        } else if origin == folder {
            folderThreads = updated
        }
    }

    private func setRead(_ thread: MessageThreadSummary, _ read: Bool) async {
        let origin = folder
        let cookies = await session.requestCookies()
        if let updated = try? await LectioMessagesService.setRead(
            threadID: thread.id, read: read, in: origin, cookies: cookies) {
            apply(updated, from: origin)
        }
        if origin != .newest { await session.loadInbox(force: true) }
    }

    private func flag(_ thread: MessageThreadSummary) async {
        let origin = folder
        let cookies = await session.requestCookies()
        if let updated = try? await LectioMessagesService.toggleFlag(
            threadID: thread.id, in: origin, cookies: cookies) {
            apply(updated, from: origin)
        }
    }

    /// Deletes (or, in Deleted, restores). The row goes at once; Lectio's
    /// answer then replaces the list.
    private func delete(_ thread: MessageThreadSummary) async {
        let origin = folder
        withAnimation(.snappy) {
            if origin == .newest {
                session.removeThreadLocally(thread.id)
            } else {
                folderThreads.removeAll { $0.id == thread.id }
            }
        }
        deleteCount += 1

        let cookies = await session.requestCookies()
        if let updated = try? await LectioMessagesService.toggleDeleted(
            threadID: thread.id, in: origin, cookies: cookies) {
            // Lectio's reply is the whole folder; an empty one is left alone
            // rather than trusted, in case the page came back short.
            if !updated.isEmpty || origin != .newest { apply(updated, from: origin) }
        }

        if origin == .deleted {
            // Restored: it's back in the inbox.
            await session.loadInbox(force: true)
        } else {
            offerUndo(thread)
        }
    }

    /// The sheet has closed: say so, bring the inbox up to date, and offer
    /// the new thread once it's there — the newest one with that subject.
    private func messageSent(_ subject: String) async {
        sentCount += 1
        sentThread = nil
        sentShown = true
        hideSentLater()

        await session.loadInbox(force: true)
        if folder != .newest { await loadFolder() }
        let found = session.threads.first {
            $0.subject.trimmingCharacters(in: .whitespacesAndNewlines) == subject
        }
        if sentShown, let found {
            sentThread = found
            hideSentLater()
        }
    }

    private func hideSentLater() {
        sentTask?.cancel()
        sentTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { hideSent() }
        }
    }

    private func hideSent() {
        sentTask?.cancel()
        sentShown = false
        sentThread = nil
    }

    private func offerUndo(_ thread: MessageThreadSummary) {
        undoTask?.cancel()
        undoable = thread
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, undoable?.id == thread.id { undoable = nil }
        }
    }

    /// Undo = the same Slet/gendan command, posted from the Deleted folder
    /// where the thread now sits.
    private func undoDelete(_ thread: MessageThreadSummary) async {
        undoTask?.cancel()
        undoable = nil
        let cookies = await session.requestCookies()
        _ = try? await LectioMessagesService.toggleDeleted(
            threadID: thread.id, in: .deleted, cookies: cookies)
        if folder == .newest {
            await session.loadInbox(force: true)
        } else {
            await loadFolder()
        }
    }
}

// MARK: - Row

struct ThreadRow: View {
    let thread: MessageThreadSummary
    var onOpen: () -> Void
    var onRead: () -> Void
    var onFlag: () -> Void
    var onDelete: () -> Void
    var inDeleted = false

    var body: some View {
        Button(action: onOpen) { row }
            .buttonStyle(PressableCard())
            .contextMenu {
                Button(action: onRead) {
                    Label(thread.unread ? "Mark as read" : "Mark as unread",
                          systemImage: thread.unread ? "envelope.open" : "envelope.badge")
                }
                if !inDeleted {
                    Button(action: onFlag) {
                        Label(thread.flagged ? "Remove flag" : "Flag", systemImage: "flag")
                    }
                }
                Divider()
                if inDeleted {
                    Button(action: onDelete) {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
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
                            .foregroundStyle(.orange)
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
        // A button's label takes the accent colour otherwise.
        .foregroundStyle(.primary)
    }

    private var metaLine: String {
        var bits: [String] = []
        if !thread.latestSender.isEmpty { bits.append(thread.latestSender) }
        if !thread.changed.isEmpty { bits.append(thread.changed) }
        return bits.joined(separator: " · ")
    }
}
