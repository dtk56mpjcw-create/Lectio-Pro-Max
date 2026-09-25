import SwiftUI

/// What the Homework tab is currently showing.
///
/// Two independent dimensions, because they answer different questions:
/// *what kind* of work (Lectio keeps Lektier attached to lessons and Opgaver
/// you hand in as separate things) and *which subject*. They combine — you can
/// ask for hand-ins in maths without one clearing the other.
///
/// Deliberately NOT persisted: a filter that survives a relaunch is how you end
/// up opening the app, seeing three items, and thinking your homework vanished.
/// It resets every launch, and the header says how much is hidden while it's on.
struct WorkFilter: Hashable {
    enum Kind: Hashable, CaseIterable {
        case all, homework, assignments

        var label: String {
            switch self {
            case .all:         return "Everything"
            case .homework:    return "Homework"
            case .assignments: return "Hand-ins"
            }
        }

        var icon: String {
            switch self {
            case .all:         return "tray.full"
            case .homework:    return "book"
            case .assignments: return "arrow.up.doc"
            }
        }
    }

    var kind: Kind = .all
    var subject: String? = nil

    var isActive: Bool { kind != .all || subject != nil }

    func matches(_ item: WorkItem) -> Bool {
        switch kind {
        case .all: break
        case .assignments: if !item.isAssignment { return false }
        case .homework:    if item.isAssignment { return false }
        }
        if let subject = subject, item.code != subject { return false }
        return true
    }

    /// "Hand-ins · Maths", for the header.
    var label: String {
        var bits: [String] = []
        if kind != .all { bits.append(kind.label) }
        if let subject = subject { bits.append(WorkFilter.subjectName(subject)) }
        return bits.joined(separator: " · ")
    }

    /// "Maths" for "ma", "Spanish" for "SP 2"; the code itself when the app
    /// doesn't know the subject.
    static func subjectName(_ code: String) -> String {
        guard let key = SubjectPalette.subjectKey(code) else { return code.uppercased() }
        let name = SubjectNames.name(forKey: key)
        return name == key.uppercased() ? code.uppercased() : name
    }
}

/// The Homework tab's one filter button: what kind of work, and which
/// subject. It fills in while a filter is on, and the subtitle says how much
/// is hidden.
struct WorkFilterMenu: View {
    let subjects: [String]
    @Binding var filter: WorkFilter

    var body: some View {
        Menu {
            Picker("Show", selection: $filter.kind) {
                ForEach(WorkFilter.Kind.allCases, id: \.self) { kind in
                    Label(kind.label, systemImage: kind.icon).tag(kind)
                }
            }
            .pickerStyle(.inline)

            if !subjects.isEmpty {
                Picker("Subject", selection: $filter.subject) {
                    Text("All subjects").tag(String?.none)
                    ForEach(subjects, id: \.self) { code in
                        Text(title(for: code)).tag(Optional(code))
                    }
                }
                .pickerStyle(.inline)
            }

            if filter.isActive {
                Divider()
                Button {
                    filter = WorkFilter()
                } label: {
                    Label("Show everything", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .sensoryFeedback(.selection, trigger: filter)
        .accessibilityValue(filter.isActive ? filter.label : "Off")
    }

    /// "Maths · MA", so both the name and Lectio's code are there to find.
    private func title(for code: String) -> String {
        let name = WorkFilter.subjectName(code)
        let upper = code.uppercased()
        return name == upper ? upper : name + " · " + upper
    }
}
