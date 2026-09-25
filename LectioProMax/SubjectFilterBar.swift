import SwiftUI

/// What the Homework tab is currently showing.
///
/// Two independent dimensions, because they answer different questions:
/// *what kind* of work (Lectio keeps Lektier attached to lessons and Opgaver
/// you hand in as separate things) and *which subject*. They combine — you can
/// ask for homework in AP LA without one clearing the other.
struct WorkFilter: Hashable {
    enum Kind: Hashable {
        case all, assignments, homework

        var label: String {
            switch self {
            case .all:         return "All"
            case .assignments: return "Assignments"
            case .homework:    return "Homework"
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

    /// "Assignments · AP LA", for the header.
    var label: String {
        var bits: [String] = []
        if kind != .all { bits.append(kind.label) }
        if let subject = subject { bits.append(subject.uppercased()) }
        return bits.joined(separator: " · ")
    }
}

/// A row of filter chips: kind on the left, subjects after the divider.
///
/// Deliberately NOT persisted: a filter that survives a relaunch is how you end
/// up opening the app, seeing three items, and thinking your homework vanished.
/// It resets every launch, and the header says how much is hidden while it's on.
struct WorkFilterBar: View {
    let subjects: [String]
    @Binding var filter: WorkFilter

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach([WorkFilter.Kind.all, .assignments, .homework], id: \.self) { kind in
                    chip(title: kind.label, code: nil, isOn: filter.kind == kind) {
                        filter.kind = (filter.kind == kind && kind != .all) ? .all : kind
                    }
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                ForEach(subjects, id: \.self) { code in
                    chip(title: code.uppercased(), code: code, isOn: filter.subject == code) {
                        filter.subject = (filter.subject == code) ? nil : code
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(title: String,
                      code: String?,
                      isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { action() }
        } label: {
            HStack(spacing: 5) {
                if let code = code {
                    SubjectDot(code: code, size: 6)
                }
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isOn ? Color.primary : Color.primary.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isOn ? Color.primary.opacity(0.10) : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(isOn ? 0.18 : 0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
