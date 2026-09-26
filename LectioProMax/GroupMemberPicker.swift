import SwiftUI

/// Picking a classmate to add to a group hand-in — the class list Lectio
/// offers, with faces and a search, and a confirmation before anything is
/// written: adding someone changes their assignment in Lectio, not just yours.
struct GroupMemberPicker: View {
    let candidates: [GroupPerson]
    /// Called with the person once the add has been confirmed.
    var onAdd: (GroupPerson) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pending: GroupPerson?

    private var filtered: [GroupPerson] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            ($0.name + " " + $0.className).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add to group")
                        .scaledFont(size: 26, weight: .bold)
                        .sheetTitleSpacing()
                    Text("They'll hand this in with you.")
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                }

                TextField("Search", text: $query)
                    .scaledFont(size: 16)
                    .autocorrectionDisabled()
                    .padding(13)
                    .contentCard(radius: Metrics.inner)

                if filtered.isEmpty {
                    EmptyNotice(icon: "magnifyingglass", text: "Nothing matches")
                    Spacer()
                } else {
                    IndexedTargetList(
                        targets: filtered.map(\.asTarget),
                        showsIndex: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) { target in
                        pending = candidates.first { $0.asTarget.id == target.id }
                    }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 24)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        // Always a sheet — even when it opens from a pushed page, whose
        // "pushed" flag would otherwise carry in and hide the close button.
        .environment(\.pushedScreen, false)
        .confirmationDialog(
            "Add \(pending?.name ?? "them") to this group hand-in?",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Add to group") {
                if let person = pending {
                    pending = nil
                    onAdd(person)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("It changes the assignment for them in Lectio too.")
        }
    }
}
