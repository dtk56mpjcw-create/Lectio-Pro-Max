import SwiftUI

struct AbsenceSheet: View {
    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var explaining: AbsenceRecord?

    private var absence: LectioStudyService.Absence { session.absence }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if session.absenceLoading && absence.subjects.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 50)
                    }

                    if !absence.unexplained.isEmpty {
                        section("Needs a reason") {
                            ForEach(absence.unexplained) { record in
                                recordCard(record, actionable: true)
                            }
                        }
                    }

                    if !absence.subjects.isEmpty {
                        section("By subject") {
                            VStack(spacing: 0) {
                                ForEach(absence.subjects) { subject in
                                    subjectRow(subject)
                                }
                            }
                            .contentCard(radius: Metrics.inner + 2)
                        }
                    }

                    let logged = absence.records.filter { !$0.needsReason }
                    if !logged.isEmpty {
                        section("Registered") {
                            ForEach(logged) { record in
                                recordCard(record, actionable: true)
                            }
                        }
                    }

                    if !session.absenceLoading && absence.subjects.isEmpty && absence.records.isEmpty {
                        EmptyNotice(icon: "checkmark.circle", text: "No absence registered")
                    }
                }
                .findScroller()
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            // In a task of its own, so an update mid-refresh can't cancel it.
            .refreshable { await Task { await session.loadAbsence(force: true) }.value }

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .task { await session.loadAbsence() }
        .sheet(item: $explaining) { record in
            ExplainAbsenceSheet(record: record).environment(session)
        }
        // Its words can be found with the search field (see PageFind).
        .findsOnPage()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Absence")
                .scaledFont(size: 26, weight: .bold)
                .sheetTitleSpacing()
            if let total = absence.total {
                Text("Total " + total.percent + (total.modules.isEmpty ? "" : " · " + total.modules + " modules"))
                    .scaledFont(size: 15)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func subjectRow(_ subject: AbsenceSubject) -> some View {
        HStack(spacing: 10) {
            FindableText(AbsenceWording.subject(subject.code))
                .scaledFont(size: 15, weight: subject.isTotal ? .bold : .medium)
            Spacer(minLength: 0)
            if !subject.modules.isEmpty {
                Text(subject.modules)
                    .scaledFont(size: 13.5)
                    .foregroundStyle(.secondary)
            }
            Text(subject.percent)
                .scaledFont(size: 15, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(subject.percentValue >= 10 ? Palette.warning : Color.primary)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 15)
    }

    private func recordCard(_ record: AbsenceRecord, actionable: Bool) -> some View {
        Button {
            if record.reasonLink != nil { explaining = record }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    SubjectDot(code: record.code, size: 7)
                    FindableText(record.whenLine)
                        .scaledFont(size: 15.5, weight: .semibold)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(record.percent)
                        .scaledFont(size: 14.5, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                    if record.needsReason {
                        ReminderButton(itemKey: record.id, offersTiming: false) {
                            Task { await session.refreshReminders() }
                        }
                    }
                }
                if !record.whereLine.isEmpty {
                    FindableText(record.whereLine)
                        .scaledFont(size: 13.5, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                if !record.reason.isEmpty || !record.comment.isEmpty {
                    FindableText([AbsenceWording.reason(record.reason), record.comment]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .scaledFont(size: 14)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                if record.needsReason {
                    Text("Tap to explain")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 2)
        }
        .buttonStyle(PressableCard())
        .disabled(record.reasonLink == nil)
    }
}

// MARK: - Giving a reason

struct ExplainAbsenceSheet: View {
    let record: AbsenceRecord

    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var options: [String] = []
    @State private var reason = ""
    @State private var comment = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Explain absence")
                            .scaledFont(size: 25, weight: .bold)
                            .sheetTitleSpacing()
                        Text([record.whenLine, record.percent].filter { !$0.isEmpty }.joined(separator: " · "))
                            .scaledFont(size: 15)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        label("Reason")
                        if options.isEmpty {
                            ProgressView().padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(options, id: \.self) { option in
                                    Button { reason = option } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: reason == option ? "largecircle.fill.circle" : "circle")
                                                .scaledFont(size: 15)
                                                .foregroundStyle(reason == option ? Palette.accent : Color(.tertiaryLabel))
                                            Text(AbsenceWording.reason(option))
                                                .scaledFont(size: 15.5)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 11)
                                        .padding(.horizontal, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .contentCard(radius: Metrics.inner)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        label("Comment")
                        TextField("Optional", text: $comment, axis: .vertical)
                            .scaledFont(size: 16)
                            .lineLimit(3...8)
                            .padding(13)
                            .contentCard(radius: Metrics.inner)
                            .disabled(saving)
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 9) {
                            if saving {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark").scaledFont(size: 14, weight: .bold)
                            }
                            Text(saving ? "Saving…" : "Save reason")
                                .scaledFont(size: 16.5, weight: .semibold)
                            Spacer()
                        }
                        .foregroundStyle(Palette.accent)
                        .padding(15)
                        .frame(maxWidth: .infinity)
                        .contentCard(radius: Metrics.inner + 2)
                    }
                    .buttonStyle(PressableCard())
                    .disabled(reason.isEmpty || saving)
                    .opacity(reason.isEmpty ? 0.45 : 1)
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        // Always a sheet — even when it opens from a pushed page, whose
        // "pushed" flag would otherwise carry in and hide the close button.
        .environment(\.pushedScreen, false)
        .task { await loadOptions() }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(size: 13, weight: .heavy)
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }

    /// Lectio's own form: its reasons (a school can configure them), and
    /// the reason and comment already given. The comment has to come from
    /// there: saving sends the box as it stands, so changing only the reason
    /// used to wipe the comment written with it.
    private func loadOptions() async {
        guard let link = record.reasonLink else { return }
        let cookies = await session.requestCookies()
        guard let form = try? await LectioStudyService.reasonForm(at: link, cookies: cookies) else { return }
        options = form.options
        if reason.isEmpty { reason = form.reason.isEmpty ? record.reason : form.reason }
        if comment.isEmpty { comment = form.comment }
    }

    private func save() async {
        guard let link = record.reasonLink else { return }
        saving = true
        errorMessage = nil
        let cookies = await session.requestCookies()
        do {
            try await LectioStudyService.submitReason(
                pageURL: link, reason: reason, comment: comment, cookies: cookies)
            await session.loadAbsence(force: true)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
