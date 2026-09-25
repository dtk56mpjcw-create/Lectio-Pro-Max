import SwiftUI

struct HomeworkTab: View {
    @EnvironmentObject private var session: LectioSession

    /// Not @AppStorage on purpose — see WorkFilterBar.
    @State private var filter = WorkFilter()

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
        NavigationStack {
            list
                .navigationTitle("Homework")
                .navigationSubtitle(subtitle)
                // A piece of homework or an assignment opens as a page of its
                // own, with the system back button — not a sheet over the list.
                .navigationDestination(for: WorkItem.self) { item in
                    workScreen(item)
                }
        }
        .task { await session.loadAbsence() }
        .sensoryFeedback(.success, trigger: session.snapshot.completedKeys.count)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkFilterBar(subjects: subjects, filter: $filter)

                if groups.isEmpty && doneItems.isEmpty {
                    EmptyNotice(icon: "checkmark.circle", text: "Nothing due — you're clear")
                } else {
                    ForEach(groups) { group in
                        groupSection(title: group.title,
                                     accent: group.isOverdue ? Color.red : nil,
                                     items: group.items)
                    }
                    if !doneItems.isEmpty {
                        groupSection(title: "Completed", accent: nil, items: doneItems)
                    }
                }


            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
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

    @ViewBuilder
    private func workScreen(_ item: WorkItem) -> some View {
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

    private func groupSection(title: String, accent: Color?, items: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(accent ?? Color.secondary)
                .padding(.leading, 4)

            VStack(spacing: 9) {
                ForEach(items) { item in
                    WorkRow(item: item,
                            done: session.snapshot.isCompleted(item)) {
                        withAnimation(.snappy(duration: 0.22)) {
                            session.toggleCompleted(item)
                        }
                    }
                }
            }
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
    @EnvironmentObject private var session: LectioSession

    private var tint: Color { Color.forSubject(item.code) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .strokeBorder(done ? tint : Color.secondary.opacity(0.4), lineWidth: 1.6)
                        .frame(width: 22, height: 22)
                    if done {
                        Circle().fill(tint).frame(width: 22, height: 22)
                            .transition(.scale.combined(with: .opacity))
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // The circle is 22 points; the target is Apple's 44.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
            // Handed in is Lectio's verdict, not a tick you can take back here.
            .disabled(item.isDelivered)
            // Laid out at the circle's size; the extra target spills over.
            .padding(-11)
            .padding(.top, 1)

            NavigationLink(value: item) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.system(size: 16.5, weight: .medium))
                        .strikethrough(done)
                        .foregroundStyle(done ? Color(.secondaryLabel) : Color.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        SubjectDot(code: item.code, size: 6)
                        Text(metaLine)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // What to actually do, so the list answers it without a
                    // tap. Left off once it's done, to keep Completed short.
                    if !done { previewLines }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The reminder lives on the thing it reminds you about.
            ReminderButton(itemKey: item.key) {
                Task { await session.refreshReminders() }
            }
            .padding(.top, -3)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .opacity(done ? 0.5 : 1)
    }

    @ViewBuilder
    private var previewLines: some View {
        let preview = item.preview
        if !preview.text.isEmpty {
            Text(preview.text)
                .font(.system(size: 14.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        if let first = preview.files.first {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .semibold))
                Text(first)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if preview.files.count > 1 {
                    Text("+\(preview.files.count - 1)")
                        .fixedSize()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, preview.text.isEmpty ? 2 : 0)
        }
    }

    private var metaLine: String {
        var bits: [String] = []
        if !item.code.isEmpty { bits.append(item.displayCode) }
        if item.isDelivered { bits.append("Handed in") }
        else if item.isAssignment { bits.append("Hand-in") }
        if !item.dueTime.isEmpty { bits.append(item.dueTime) }
        return bits.joined(separator: " · ")
    }
}

struct WorkDetailSheet: View {
    let item: WorkItem
    let done: Bool
    let toggle: () -> Void
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss

    private var tint: Color { Color.forSubject(item.code) }

    var body: some View {
        DetailSheetScaffold(onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        SubjectDot(code: item.code, size: 9)
                        Text(item.displayCode)
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(item.displayTitle)
                        .font(.system(size: 25.5, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let due = item.due {
                        Text("Due " + LectioDates.friendlyLabel(iso: due)
                             + (item.dueTime.isEmpty ? "" : " · " + item.dueTime))
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    toggle()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done ? "arrow.uturn.backward" : "checkmark")
                            .font(.system(size: 15, weight: .bold))
                        Text(done ? "Mark as not done" : "Mark as done")
                            .font(.system(size: 16.5, weight: .semibold))
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
                        .environmentObject(session)
                } else if !item.text.isEmpty {
                    Text(LectioDates.tidy(item.text))
                        .font(.system(size: 16.5))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard(radius: Metrics.inner + 2)
                }

                if let link = item.link, let url = URL(string: link) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "safari").font(.system(size: 15, weight: .semibold))
                            Text("Open in Lectio")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 12.5, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(15)
                        .frame(maxWidth: .infinity)
                        .contentCard(radius: Metrics.inner + 2)
                    }
                }
            }
        }
    }
}
