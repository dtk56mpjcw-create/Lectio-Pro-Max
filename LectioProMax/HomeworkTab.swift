import SwiftUI

struct HomeworkTab: View {
    @EnvironmentObject private var session: LectioSession

    /// Not @AppStorage on purpose — see WorkFilterBar.
    @State private var filter = WorkFilter()

    private var subjects: [String] {
        Array(Set(session.snapshot.workItems.map { $0.code }.filter { !$0.isEmpty }))
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
        ScrollView {
            RefreshHeader(space: "homework") {
                await session.refresh()
                await session.loadAbsence(force: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Homework", subtitle: subtitle)
                    .padding(.top, 6)

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
        }
        .coordinateSpace(.named("homework"))
        .scrollIndicators(.hidden)
        .task { await session.loadAbsence() }
        .sensoryFeedback(.success, trigger: session.snapshot.completedKeys.count)
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
    @State private var open = false

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
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            // Handed in is Lectio's verdict, not a tick you can take back here.
            .disabled(item.isDelivered)
            .padding(.top, 1)

            Button { open = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LectioDates.tidy(item.title))
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
                        Spacer(minLength: 0)
                    }
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
        .sheet(isPresented: $open) {
            // An assignment has a real hand-in page behind it; homework doesn't.
            if item.isAssignment, let link = item.link {
                AssignmentHandInSheet(item: item, link: link, done: done, toggle: toggle)
                    .environmentObject(session)
            } else {
                WorkDetailSheet(item: item, done: done, toggle: toggle)
                    .environmentObject(session)
            }
        }
    }

    private var metaLine: String {
        var bits: [String] = []
        if !item.code.isEmpty { bits.append(item.code.uppercased()) }
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
                        Text(item.code.uppercased())
                            .font(.system(size: 14, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(LectioDates.tidy(item.title))
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
