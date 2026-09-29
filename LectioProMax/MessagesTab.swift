import SwiftUI

/// Messages: Lectio's folders, with the actions Mail has — swipe a thread to
/// delete or flag it, swipe the other way to mark it read or unread, or hold
/// it for the same in a menu. Deleting can be undone for a few seconds, and
/// later from the Deleted folder, because Lectio's own delete ("Slet") only
/// moves a thread there. Lectio can't delete for good; the app can clear
/// threads out of its own Deleted list.
struct MessagesTab: View {
    @Environment(LectioSession.self) private var session
    /// The folder, its threads and the open thread, shared with the copy
    /// behind the search (see TabPlaces).
    @Environment(MessagesPlace.self) private var place
    @State private var composing = false

    private var path: [MessageThreadSummary] {
        get { place.path }
        nonmutating set { place.path = newValue }
    }
    private var folder: MessageFolder { place.folder }
    /// Threads of any folder but Newest, which lives on the session (the
    /// unread badge and Search read it too).
    private var folderThreads: [MessageThreadSummary] {
        get { place.folderThreads }
        nonmutating set { place.folderThreads = newValue }
    }
    private var folderLoading: Bool {
        get { place.folderLoading }
        nonmutating set { place.folderLoading = newValue }
    }

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

    /// Threads cleared out of the Deleted list (in the app only).
    @State private var cleared: Set<String> = ClearedDeleted.ids
    @State private var confirmingClear = false
    /// Who sent what, for photos. Built from the directory New message uses.
    @State private var directory = SenderDirectory()

    private var threads: [MessageThreadSummary] {
        guard folder == .newest else {
            return folder == .deleted
                ? folderThreads.filter { !cleared.contains($0.id) }
                : folderThreads
        }
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
        NavigationStack(path: Bindable(place).path) {
            list
                .navigationTitle(folder.title)
                .navigationSubtitle(subtitle)
                .searchedAs(.messages)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Folder", selection: Binding { place.folder } set: { place.open($0) }) {
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
                // No search bar of its own: the search button in the tab
                // bar searches messages from here (SearchTab).
        }
        .task { await session.loadInbox() }
        // The people directory, for senders' photos. Fetched once a session.
        .task { await session.loadRecipients() }
        .task(id: session.recipients.count) {
            directory = SenderDirectory(session.recipients)
        }
        .confirmationDialog("Clear the Deleted list?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear list", role: .destructive) { clearDeleted() }
        } message: {
            Text("Lectio doesn't let anyone delete messages for good; it empties Deleted by itself after 3 months. This hides them in the app. You can still see them on lectio.dk.")
        }
        // As the tab appears, and for another folder. Not again if the copy
        // of the tab behind the search fetched it a moment ago.
        .task(id: folder) { await loadFolder(force: false) }
        .onChange(of: folder) {
            // The last folder's threads go in MessagesPlace.open.
            undoTask?.cancel()
            undoable = nil
        }
        .sensoryFeedback(.success, trigger: deleteCount)
        .sensoryFeedback(.success, trigger: sentCount)
        .sheet(isPresented: $composing) {
            NewMessageSheet(onSent: { subject in
                Task { await messageSent(subject) }
            })
            .environment(session)
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
                if folder == .deleted {
                    deletedNote
                        .listRowInsets(EdgeInsets(top: 2, leading: Metrics.margin,
                                                  bottom: 6, trailing: Metrics.margin))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(threads) { thread in
                    ThreadRow(thread: thread,
                              personID: directory.id(for: thread.latestSender),
                              onOpen: { path.append(thread) },
                              onRead: { Task { await setRead(thread, thread.unread) } },
                              onFlag: { Task { await flag(thread) } },
                              onDelete: { Task { await delete(thread) } },
                              onRemove: { remove(thread) },
                              inDeleted: folder == .deleted)
                        .listRowInsets(EdgeInsets(top: 4.5, leading: Metrics.margin,
                                                  bottom: 4.5, trailing: Metrics.margin))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if folder == .deleted {
                                Button(role: .destructive) {
                                    remove(thread)
                                } label: {
                                    Label("Remove", systemImage: "trash.slash")
                                }
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
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("Deleted")
                .scaledFont(size: 15.5, weight: .medium)
            Spacer(minLength: 0)
            Button("Undo") {
                Task { await undoDelete(thread) }
            }
            .scaledFont(size: 15.5, weight: .semibold)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .glassEffect(.regular, in: .capsule)
    }

    private var sentBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(.green)
            Text("Message sent")
                .scaledFont(size: 15.5, weight: .medium)
            Spacer(minLength: 0)
            if let thread = sentThread {
                Button("View") {
                    hideSent()
                    path.append(thread)
                }
                .scaledFont(size: 15.5, weight: .semibold)
                .frame(minHeight: 44)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
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

    private func loadFolder(force: Bool = true) async {
        guard folder != .newest else { return }
        if !force, place.isFresh(folder) { return }
        folderLoading = true
        defer { folderLoading = false }
        let cookies = await session.requestCookies()
        let showing = folder
        if let loaded = try? await LectioMessagesService.loadFolder(showing, cookies: cookies),
           showing == folder {
            folderThreads = loaded
            place.folderLoaded = (showing, Date())
        }
    }

    /// What Lectio returns after a command is the folder as it now stands.
    private func apply(_ updated: [MessageThreadSummary], from origin: MessageFolder) {
        if origin == .newest {
            session.applyThreads(updated)
        } else if origin == folder {
            folderThreads = updated
            place.folderLoaded = (origin, Date())
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
        if origin == .deleted {
            ClearedDeleted.remove(thread.id)
            cleared.remove(thread.id)
        }
        if let updated = try? await LectioMessagesService.setDeleted(
            threadID: thread.id, deleted: origin != .deleted, in: origin, cookies: cookies) {
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

    // MARK: Clearing Deleted (in the app)

    private var deletedNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Lectio empties Deleted after 3 months.")
                .scaledFont(size: 13.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Clear list") { confirmingClear = true }
                .scaledFont(size: 14.5, weight: .semibold)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
        }
    }

    private func remove(_ thread: MessageThreadSummary) {
        ClearedDeleted.add([thread.id])
        withAnimation(.snappy) { _ = cleared.insert(thread.id) }
        deleteCount += 1
    }

    private func clearDeleted() {
        let ids = threads.map(\.id)
        ClearedDeleted.add(ids)
        withAnimation(.snappy) { cleared.formUnion(ids) }
        deleteCount += 1
    }

    private func offerUndo(_ thread: MessageThreadSummary) {
        undoTask?.cancel()
        undoable = thread
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, undoable?.id == thread.id { undoable = nil }
        }
    }

    /// Undo = "Gendan", posted from the Deleted folder where the thread now
    /// sits.
    private func undoDelete(_ thread: MessageThreadSummary) async {
        undoTask?.cancel()
        undoable = nil
        let cookies = await session.requestCookies()
        _ = try? await LectioMessagesService.setDeleted(
            threadID: thread.id, deleted: false, in: .deleted, cookies: cookies)
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
    /// The sender in Lectio's directory, for their photo; nil shows initials.
    var personID: String?
    var onOpen: () -> Void
    var onRead: () -> Void
    var onFlag: () -> Void
    var onDelete: () -> Void
    var onRemove: () -> Void = {}
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
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove from list", systemImage: "trash.slash")
                    }
                } else {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
    }

    /// Mail's order: who, then what. The face is the quickest thing to find
    /// in a list; unread shows as a dot on it and a bolder line.
    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(name: thread.latestSender, personID: personID, size: 42)
                .overlay(alignment: .topLeading) {
                    if thread.unread {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                            .offset(x: -2, y: -2)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(senderName)
                        .scaledFont(size: 15.5, weight: thread.unread ? .semibold : .medium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(changedText)
                        .scaledFont(size: 13.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(thread.subject)
                        .scaledFont(size: 16, weight: thread.unread ? .semibold : .regular)
                        .foregroundStyle(thread.unread ? Color.primary : Color(.secondaryLabel))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if thread.flagged {
                        Image(systemName: "flag.fill")
                            .scaledFont(size: 11.5)
                            .foregroundStyle(Palette.warning)
                    }
                    if thread.hasAttachment {
                        Image(systemName: "paperclip")
                            .scaledFont(size: 11.5, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                if !thread.recipients.isEmpty {
                    Text("To " + thread.recipients)
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        // A button's label takes the accent colour otherwise.
        .foregroundStyle(.primary)
    }

    /// Lectio writes "to 16:35" (Danish "torsdag"); the rest of the app is
    /// in English.
    private var changedText: String {
        let parts = thread.changed.split(separator: " ", maxSplits: 1).map(String.init)
        let days = ["ma": "Mon", "ti": "Tue", "on": "Wed", "to": "Thu",
                    "fr": "Fri", "lø": "Sat", "sø": "Sun"]
        if parts.count == 2, let day = days[parts[0].lowercased()] { return day + " " + parts[1] }
        return thread.changed
    }

    /// "Julie Skov Nikolajsen (JN)" reads as the name; the bracket stays
    /// out of the way.
    private var senderName: String {
        let raw = thread.latestSender.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "Lectio" }
        if let open = raw.lastIndex(of: "("), raw.hasSuffix(")") {
            let name = raw[..<open].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? raw : name
        }
        return raw
    }
}
