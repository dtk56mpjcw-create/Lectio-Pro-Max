import SwiftUI

struct HomeworkTab: View {
    @Environment(LectioSession.self) private var session
    /// The filter and the open homework (see TabPlaces).
    @Environment(HomeworkPlace.self) private var place

    /// Not @AppStorage on purpose — see WorkFilter.
    private var filter: WorkFilter {
        get { place.filter }
        nonmutating set { place.filter = newValue }
    }
    private var path: [WorkItem] {
        get { place.path }
        nonmutating set { place.path = newValue }
    }
    /// What a swipe asked to be reminded about, while its time is chosen.
    @State private var remindAbout: WorkItem?
    @State private var notificationsOff = false

    private var subjects: [String] {
        // Only real subjects: a school-wide event's list of classes isn't one.
        Array(Set(session.snapshot.workItems.filter { $0.isSubjectCode }.map { $0.code }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var groups: [WorkGroup] {
        WorkGroup.build(from: session.snapshot, filter: filter)
    }
    private var doneItems: [WorkItem] {
        // Most recent first — the one you just handed in should be at the top,
        // not buried under everything you finished in August.
        session.snapshot.workItems
            .filter { filter.matches($0) }
            .filter { session.snapshot.isCompleted($0) }
            .sorted { ($0.due ?? "") > ($1.due ?? "") }
    }

    var body: some View {
        NavigationStack(path: Bindable(place).path) {
            list
                .navigationTitle("Homework")
                .navigationSubtitle(subtitle)
                .searchedAs(.homework)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        WorkFilterMenu(subjects: subjects, filter: Bindable(place).filter)
                    }
                }
                // A piece of homework or an assignment opens as a page of its
                // own, with the system back button — not a sheet over the list.
                .navigationDestination(for: WorkItem.self) { [session] item in
                    Self.workScreen(item, session: session)
                        // Search here finds on the page.
                        .searchPage(.page) { Self.workScreen(item, session: session) }
                }
        }
        .task { await session.loadAbsence() }
        .sensoryFeedback(.success, trigger: session.snapshot.completedKeys.count)
        .confirmationDialog("Remind me",
                            isPresented: Binding(get: { remindAbout != nil },
                                                 set: { if !$0 { remindAbout = nil } }),
                            titleVisibility: .visible,
                            presenting: remindAbout) { item in
            ForEach(ReminderTiming.allCases, id: \.self) { option in
                Button(option.label) {
                    Task { await setReminder(option, on: item) }
                }
            }
        } message: { item in
            Text(item.displayTitle)
        }
        .alert("Notifications are off", isPresented: $notificationsOff) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Reminders arrive as notifications. Turn them on for Lectio Pro Max in Settings.")
        }
    }

    /// A List, for the system's swipe actions: right to tick off, left for a
    /// reminder. Rows still look like cards.
    private var list: some View {
        List {
            if groups.isEmpty && doneItems.isEmpty {
                if filter.isActive {
                    VStack(spacing: 10) {
                        EmptyNotice(icon: "line.3.horizontal.decrease.circle",
                                    text: "Nothing matches this filter")
                        Button("Show everything") {
                            withAnimation(.snappy) { filter = WorkFilter() }
                        }
                        .scaledFont(size: 16, weight: .semibold)
                        .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity)
                    .homeworkRow()
                } else {
                    EmptyNotice(icon: "checkmark.circle", text: "Nothing due — you're clear")
                        .homeworkRow()
                }
            } else {
                ForEach(groups) { group in
                    header(group.title, accent: group.isOverdue ? Palette.negative : nil)
                    ForEach(group.items) { item in row(item) }
                }
                if !doneItems.isEmpty {
                    header("Completed", accent: nil)
                    ForEach(doneItems) { item in row(item) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        // The system's own pull to refresh. The work runs in a task of its
        // own: SwiftUI cancels the refresh's task if the view updates while
        // it runs — as it does when the new data arrives — and a cancelled
        // request is why the spinner once spun without refreshing.
        .refreshable {
            await Task {
                await session.refresh()
                await session.loadAbsence(force: true)
            }.value
        }
        .background { AppBackground() }
    }

    private func header(_ title: String, accent: Color?) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 13, weight: .heavy)
            .tracking(0.8)
            .foregroundStyle(accent ?? Color.secondary)
            .padding(.leading, 4)
            .homeworkRow(top: 14, bottom: 4)
    }

    private func row(_ item: WorkItem) -> some View {
        WorkRow(item: item,
                done: session.snapshot.isCompleted(item),
                toggle: { toggle(item) },
                open: { path.append(item) },
                askReminder: { remindAbout = item },
                setReminder: { option in Task { await setReminder(option, on: item) } })
            .homeworkRow(top: 4.5, bottom: 4.5)
    }

    private func toggle(_ item: WorkItem) {
        guard !item.isDelivered else { return }
        withAnimation(.snappy(duration: 0.22)) { session.toggleCompleted(item) }
    }

    private func setReminder(_ option: ReminderTiming?, on item: WorkItem) async {
        if await ReminderBook.shared.set(option, for: item.key) {
            await session.refreshReminders()
        } else {
            notificationsOff = true
        }
    }

    /// Static and given the session, so it can be drawn again behind the
    /// search field (searchPage) outside this tab's own drawing.
    @ViewBuilder
    private static func workScreen(_ item: WorkItem, session: LectioSession) -> some View {
        let done = session.snapshot.isCompleted(item)
        let toggle: () -> Void = {
            withAnimation(.snappy(duration: 0.22)) { session.toggleCompleted(item) }
        }
        // An assignment has a real hand-in page behind it; homework doesn't.
        if item.isAssignment, let link = item.link {
            AssignmentHandInSheet(item: item, link: link, done: done, toggle: toggle)
                .asPushedScreen()
        } else {
            WorkDetailSheet(item: item, done: done, toggle: toggle)
                .asPushedScreen()
        }
    }

    private var subtitle: String {
        let total = session.snapshot.outstandingCount
        if filter.isActive {
            // Say what's hidden, so a filter never looks like missing data.
            let shown = session.snapshot.workItems
                .filter { filter.matches($0) && !session.snapshot.isCompleted($0) }.count
            return "\(shown) of \(total) · \(filter.label)"
        }
        if total == 0 { return "All caught up" }
        return total == 1 ? "1 thing to do" : "\(total) things to do"
    }
}

private extension View {
    /// A List row that looks like the rest of the app: no separator, no row
    /// background, the page's own margins.
    func homeworkRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: Metrics.margin,
                                      bottom: bottom, trailing: Metrics.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct WorkGroup: Identifiable {
    var id: String { title }
    var title: String
    var items: [WorkItem]
    var isOverdue: Bool

    static func build(from snapshot: LectioSnapshot, filter: WorkFilter = WorkFilter()) -> [WorkGroup] {
        let today = LectioDates.isoString(from: Date())
        let outstanding = snapshot.workItems
            .filter { filter.matches($0) }
            .filter { !snapshot.isCompleted($0) }

        var overdue: [WorkItem] = []
        var byDate: [String: [WorkItem]] = [:]
        var undated: [WorkItem] = []

        for item in outstanding {
            guard let due = item.due, !due.isEmpty else { undated.append(item); continue }
            if due < today { overdue.append(item) } else { byDate[due, default: []].append(item) }
        }

        var groups: [WorkGroup] = []
        if !overdue.isEmpty {
            groups.append(WorkGroup(title: "Overdue",
                                    items: overdue.sorted { ($0.due ?? "") < ($1.due ?? "") },
                                    isOverdue: true))
        }
        for date in byDate.keys.sorted() {
            groups.append(WorkGroup(title: LectioDates.friendlyLabel(iso: date),
                                    items: byDate[date] ?? [], isOverdue: false))
        }
        if !undated.isEmpty {
            groups.append(WorkGroup(title: "No date", items: undated, isOverdue: false))
        }
        return groups
    }
}

struct WorkRow: View {
    let item: WorkItem
    let done: Bool
    let toggle: () -> Void
    var open: () -> Void
    /// A swipe asks; the list shows the choice of times.
    var askReminder: () -> Void
    var setReminder: (ReminderTiming?) -> Void
    @Environment(LectioSession.self) private var session

    private var tint: Color { Color.forSubject(item.code) }
    private var reminder: ReminderTiming? { ReminderBook.shared.timing(for: item.key) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark

            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .scaledFont(size: 16.5, weight: .medium)
                        .strikethrough(done)
                        .foregroundStyle(done ? Color(.secondaryLabel) : Color.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    meta
                    // What to actually do, so the list answers it without a
                    // tap. Left off once it's done, to keep Completed short.
                    if !done { previewLines }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The bell only where a reminder is set; swipe left or hold the
            // row to add one.
            if reminder != nil {
                ReminderButton(itemKey: item.key) {
                    Task { await session.refreshReminders() }
                }
                .padding(.top, -3)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .opacity(done ? 0.5 : 1)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .contextMenu { menu }
        // Swipe right: done (or not). Handed in is Lectio's verdict, so
        // there's nothing to undo there.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !item.isDelivered {
                Button(action: toggle) {
                    Label(done ? "Not done" : "Done",
                          systemImage: done ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(done ? .gray : .green)
            }
        }
        // Swipe left: a reminder, or take it off.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if reminder != nil {
                Button {
                    setReminder(nil)
                } label: {
                    Label("No reminder", systemImage: "bell.slash")
                }
                .tint(.gray)
            } else {
                Button(action: askReminder) {
                    Label("Remind", systemImage: "bell")
                }
                .tint(.orange)
            }
        }
    }

    // MARK: The mark on the left

    /// Homework: the tick circle. A hand-in: the same circle with an arrow,
    /// or an exclamation mark once it's late. Tapping ticks it off here;
    /// handed in is Lectio's verdict and can't be taken back.
    private var mark: some View {
        TimelineView(.everyMinute) { context in
            let late = item.isAssignment && !done && item.deadlineStatus(now: context.date).isLate
            Button(action: toggle) {
                ZStack {
                    if done {
                        Circle().fill(item.isDelivered ? Color.green : tint)
                            .transition(.scale.combined(with: .opacity))
                        Image(systemName: "checkmark")
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle()
                            .strokeBorder(late ? Color.red : Color.secondary.opacity(0.4), lineWidth: 1.6)
                        if item.isAssignment {
                            Image(systemName: late ? "exclamationmark" : "arrow.up")
                                .scaledFont(size: 10.5, weight: .heavy)
                                .foregroundStyle(late ? Color.red : Color.secondary)
                        }
                    }
                }
                .frame(width: 22, height: 22)
                // The circle is 22 points; the target is Apple's 44.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
            .disabled(item.isDelivered)
        }
        // Laid out at the circle's size; the extra target spills over.
        .padding(-11)
        .padding(.top, 1)
    }

    // MARK: The line under the title

    private var meta: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 6) {
                SubjectDot(code: item.code, size: 6)
                if item.isAssignment {
                    let status = item.deadlineStatus(now: context.date, markedDone: done)
                    Text(item.displayCode + " ·")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(status.text)
                        .foregroundStyle(color(for: status.tone))
                        .lineLimit(1)
                } else {
                    Text(homeworkMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .scaledFont(size: 14, weight: .medium)
        }
    }

    private func color(for tone: DeadlineStatus.Tone) -> Color {
        switch tone {
        case .done: return Palette.positive
        case .calm: return Color(.secondaryLabel)
        case .soon: return Palette.warning
        case .late: return Palette.negative
        }
    }

    private var homeworkMeta: String {
        var bits: [String] = []
        if !item.code.isEmpty { bits.append(item.displayCode) }
        if !item.dueTime.isEmpty { bits.append(item.dueTime) }
        return bits.joined(separator: " · ")
    }

    // MARK: The preview

    @ViewBuilder
    private var previewLines: some View {
        let preview = item.preview
        if !preview.text.isEmpty {
            Text(preview.text)
                .scaledFont(size: 14.5)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        if let first = preview.files.first {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .scaledFont(size: 12, weight: .semibold)
                Text(first)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if preview.files.count > 1 {
                    Text("+\(preview.files.count - 1)")
                        .fixedSize()
                }
            }
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.top, preview.text.isEmpty ? 2 : 0)
        }
    }

    // MARK: Hold

    @ViewBuilder
    private var menu: some View {
        if !item.isDelivered {
            Button(action: toggle) {
                Label(done ? "Mark as not done" : "Mark as done",
                      systemImage: done ? "circle" : "checkmark.circle")
            }
        }
        Menu {
            ForEach(ReminderTiming.allCases, id: \.self) { option in
                Button {
                    setReminder(option)
                } label: {
                    Label(option.label, systemImage: reminder == option ? "checkmark" : option.icon)
                }
            }
        } label: {
            Label(reminder == nil ? "Remind me" : "Change reminder", systemImage: "bell")
        }
        if reminder != nil {
            Button(role: .destructive) {
                setReminder(nil)
            } label: {
                Label("Remove reminder", systemImage: "bell.slash")
            }
        }
        Divider()
        Button(action: open) {
            Label(item.isAssignment ? "Open hand-in" : "Open", systemImage: "arrow.up.forward.square")
        }
    }
}

struct WorkDetailSheet: View {
    let item: WorkItem
    let done: Bool
    let toggle: () -> Void
    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var tint: Color { Color.forSubject(item.code) }

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        SubjectDot(code: item.code, size: 9)
                        Text(item.displayCode)
                            .scaledFont(size: 14, weight: .heavy)
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    FindableText(item.displayTitle)
                        .scaledFont(size: 25.5, weight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                    if let due = item.due {
                        Text("Due " + LectioDates.friendlyLabel(iso: due)
                             + (item.dueTime.isEmpty ? "" : " · " + item.dueTime))
                            .scaledFont(size: 15.5, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    toggle()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done ? "arrow.uturn.backward" : "checkmark")
                            .scaledFont(size: 15, weight: .bold)
                        Text(done ? "Mark as not done" : "Mark as done")
                            .scaledFont(size: 16.5, weight: .semibold)
                        Spacer()
                    }
                    .foregroundStyle(done ? Color.secondary : Palette.accent)
                    .padding(15)
                    .frame(maxWidth: .infinity)
                    .contentCard(radius: Metrics.inner + 2)
                }
                .buttonStyle(PressableCard())

                // The lesson's own page: the full homework text Lectio truncates
                // on the dashboard, plus anything the teacher pinned to it.
                if let link = item.link {
                    LessonContentView(link: link, placeholder: item.text)
                        .environment(session)
                } else if !item.text.isEmpty {
                    FindableText(LectioDates.tidy(item.text))
                        .scaledFont(size: 16.5)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard(radius: Metrics.inner + 2)
                }

                if let link = item.link, let url = URL(string: link) {
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
        // Its words can be found with the search field (see PageFind).
        .findsOnPage()
    }
}
