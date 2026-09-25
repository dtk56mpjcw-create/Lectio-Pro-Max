import SwiftUI

struct AbsenceSheet: View {
    @EnvironmentObject private var session: LectioSession
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
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .refreshable { await session.loadAbsence(force: true) }

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .task { await session.loadAbsence() }
        .sheet(item: $explaining) { record in
            ExplainAbsenceSheet(record: record).environmentObject(session)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Absence")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 34)
                .padding(.trailing, 44)
            if let total = absence.total {
                Text("Total " + total.percent + (total.modules.isEmpty ? "" : " · " + total.modules + " modules"))
                    .font(.system(size: 15))
                    .foregroundStyle(.primary.opacity(0.7))
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.6))
            content()
        }
    }

    private func subjectRow(_ subject: AbsenceSubject) -> some View {
        HStack(spacing: 10) {
            Text(AbsenceWording.subject(subject.code))
                .font(.system(size: 15, weight: subject.isTotal ? .bold : .medium))
            Spacer(minLength: 0)
            if !subject.modules.isEmpty {
                Text(subject.modules)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            Text(subject.percent)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(subject.percentValue >= 10 ? Palette.accent : Color.primary.opacity(0.8))
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
                    Text(record.whenLine)
                        .font(.system(size: 15.5, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(record.percent)
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                    if record.needsReason {
                        ReminderButton(itemKey: record.id, offersTiming: false) {
                            Task { await session.refreshReminders() }
                        }
                    }
                }
                if !record.whereLine.isEmpty {
                    Text(record.whereLine)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.6))
                }
                if !record.reason.isEmpty || !record.comment.isEmpty {
                    Text([AbsenceWording.reason(record.reason), record.comment]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.72))
                        .multilineTextAlignment(.leading)
                }
                if record.needsReason {
                    Text("Tap to explain")
                        .font(.system(size: 13, weight: .semibold))
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

    @EnvironmentObject private var session: LectioSession
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
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .padding(.top, 34)
                            .padding(.trailing, 44)
                        Text([record.whenLine, record.percent].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 15))
                            .foregroundStyle(.primary.opacity(0.7))
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
                                                .font(.system(size: 15))
                                                .foregroundStyle(reason == option ? Palette.accent : Color.primary.opacity(0.35))
                                            Text(AbsenceWording.reason(option))
                                                .font(.system(size: 15.5))
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
                            .font(.system(size: 16))
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
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                            }
                            Text(saving ? "Saving…" : "Save reason")
                                .font(.system(size: 16.5, weight: .semibold, design: .rounded))
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
        .task { await loadOptions() }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(.primary.opacity(0.6))
    }

    private func loadOptions() async {
        guard let link = record.reasonLink else { return }
        let cookies = await session.requestCookies()
        // Read the choices off Lectio's own dropdown: a school can configure them.
        options = (try? await LectioStudyService.reasonOptions(at: link, cookies: cookies)) ?? []
        if reason.isEmpty { reason = record.reason }
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
