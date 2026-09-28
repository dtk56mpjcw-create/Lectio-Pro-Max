import SwiftUI

/// Adds a private appointment to the schedule.
struct NewEventSheet: View {
    /// The day the schedule was showing, so the pickers start somewhere sensible.
    let dayISO: String
    /// Lectio's `aftaleid` when editing an existing appointment; nil for a new one.
    var eventID: String? = nil
    var onCreated: () -> Void

    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var note = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var primed = false
    @State private var loading = false
    @State private var confirmingDelete = false

    private var isEditing: Bool { eventID != nil }

    private var titleRemaining: Int { LectioEventService.titleLimit - title.count }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= LectioEventService.titleLimit
            && end > start
            && !saving
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isEditing ? "Edit event" : "New event")
                        .scaledFont(size: 26, weight: .bold)
                        .padding(.top, 34)
                        .padding(.trailing, 44)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }

                    titleField
                    timesCard

                    VStack(alignment: .leading, spacing: 9) {
                        label("Note")
                        TextField("Optional", text: $note, axis: .vertical)
                            .scaledFont(size: 16)
                            .lineLimit(3...8)
                            .padding(13)
                            .contentCard(radius: Metrics.inner)
                            .disabled(saving)
                    }

                    Text("Private appointments are only visible to you.")
                        .scaledFont(size: 13.5)
                        .foregroundStyle(.secondary)

                    // Why Lectio didn't take it (its own validator's words
                    // when it gives some). Noted and never shown before.
                    if let errorMessage {
                        Banner(text: errorMessage)
                    }

                    saveButton
                    if isEditing { deleteButton }
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
        .task { await prepare() }
        .confirmationDialog("Delete this event?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await remove() } }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("It will be removed from your Lectio schedule for good.")
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                label("Title")
                Spacer()
                // Lectio's own limit, and it silently swallows extra characters
                // on the web, so it's worth showing.
                Text("\(max(titleRemaining, 0)) left")
                    .scaledFont(size: 12.5, weight: .medium)
                    .foregroundStyle(titleRemaining < 0 ? Palette.negative : Color(.secondaryLabel))
            }
            TextField("Football practice", text: $title)
                .scaledFont(size: 16)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(saving)
                .onChange(of: title) { _, new in
                    if new.count > LectioEventService.titleLimit {
                        title = String(new.prefix(LectioEventService.titleLimit))
                    }
                }
        }
    }

    private var timesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Starts", selection: $start)
                .scaledFont(size: 16, weight: .medium)
                .disabled(saving)
            Divider().opacity(0.4)
            DatePicker("Ends", selection: $end, in: start...)
                .scaledFont(size: 16, weight: .medium)
                .disabled(saving)
        }
        // Lectio keeps Danish times; show them as such on any phone.
        .environment(\.timeZone, LectioDates.timeZone)
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(size: 13, weight: .heavy)
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 9) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "calendar.badge.plus").scaledFont(size: 15, weight: .semibold)
                }
                Text(saving ? "Saving…" : (isEditing ? "Save changes" : "Add to schedule"))
                    .scaledFont(size: 16.5, weight: .semibold)
                Spacer()
            }
            .foregroundStyle(Palette.accent)
            .padding(15)
            .frame(maxWidth: .infinity)
            .contentCard(radius: Metrics.inner + 2)
        }
        .buttonStyle(PressableCard())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.45)
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "trash").scaledFont(size: 14.5, weight: .semibold)
                Text("Delete event")
                    .scaledFont(size: 16.5, weight: .semibold)
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(15)
            .frame(maxWidth: .infinity)
            .contentCard(radius: Metrics.inner + 2)
        }
        .buttonStyle(PressableCard())
        .disabled(saving)
    }

    // MARK: Work

    private func prepare() async {
        guard !primed else { return }
        primed = true

        guard let eventID = eventID else {
            prime()
            return
        }

        loading = true
        let cookies = await session.requestCookies()
        if let draft = try? await LectioEventService.load(eventID: eventID, cookies: cookies) {
            title = draft.title
            note = draft.note
            if let from = combine(draft.startISO, draft.startTime) { start = from }
            if let to = combine(draft.endISO, draft.endTime) { end = to }
        } else {
            errorMessage = "Couldn't load this event from Lectio."
            prime()
        }
        loading = false
    }

    private func combine(_ iso: String, _ time: String) -> Date? {
        guard let day = LectioDates.date(fromISO: iso) else { return nil }
        let pieces = time.split(separator: ":")
        let calendar = LectioDates.calendar
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = pieces.count > 0 ? Int(pieces[0]) ?? 0 : 0
        components.minute = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
        return calendar.date(from: components)
    }

    private func remove() async {
        guard let eventID = eventID else { return }
        saving = true
        errorMessage = nil
        let cookies = await session.requestCookies()
        do {
            try await LectioEventService.delete(eventID: eventID, cookies: cookies)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    /// Start on the day you were looking at, at the next whole hour.
    private func prime() {

        let calendar = LectioDates.calendar
        let base = LectioDates.date(fromISO: dayISO) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: base)

        let now = Date()
        let isToday = LectioDates.isoString(from: now) == dayISO
        let hour = isToday ? min(calendar.component(.hour, from: now) + 1, 22) : 16
        components.hour = hour
        components.minute = 0

        let chosen = calendar.date(from: components) ?? now
        start = chosen
        end = chosen.addingTimeInterval(3600)
    }

    private func save() async {
        saving = true
        errorMessage = nil

        var draft = LectioEventService.Draft()
        draft.id = eventID
        draft.title = title
        draft.startISO = LectioDates.isoString(from: start)
        draft.startTime = LectioDates.timeString(start)
        draft.endISO = LectioDates.isoString(from: end)
        draft.endTime = LectioDates.timeString(end)
        draft.note = note

        let cookies = await session.requestCookies()
        do {
            try await LectioEventService.save(draft, cookies: cookies)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
