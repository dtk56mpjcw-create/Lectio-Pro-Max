import SwiftUI

/// Studieplan: what each subject is teaching this year, and how much of its
/// Elevtid — the hours the subject expects of you — has actually been logged.
struct StudyPlanSheet: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss

    @State private var subjects: [StudyPlanSubject] = []
    @State private var loading = true
    @State private var failed = false
    @State private var expanded: Set<String> = []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Study plan")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .padding(.top, 34)
                        .padding(.trailing, 44)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else if failed {
                        EmptyNotice(icon: "arrow.clockwise", text: "Couldn't reach Lectio")
                    } else if subjects.isEmpty {
                        EmptyNotice(icon: "list.bullet.rectangle",
                                    text: "No study plan for this year yet")
                    } else {
                        totals
                        ForEach(subjects) { subject in
                            subjectCard(subject)
                        }
                    }
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
        .task { await load() }
    }

    // MARK: Totals

    private var totals: some View {
        let done = subjects.reduce(0) { $0 + $1.hours }
        let norm = subjects.reduce(0) { $0 + $1.norm }
        return VStack(alignment: .leading, spacing: 5) {
            Text("STUDY HOURS THIS YEAR")
                .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.primary.opacity(0.55))
            Text(hours(done) + (norm > 0 ? " of " + hours(norm) + " hours" : " hours"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Lectio calls this Elevtid: hours logged against your subjects, "
                 + "against what the year expects.")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    // MARK: A subject

    private func subjectCard(_ subject: StudyPlanSubject) -> some View {
        let tint = Color.forSubject(subject.code)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                SubjectDot(code: subject.code, size: 9)
                Text(subject.name.uppercased())
                    .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(subject.hasNorm
                     ? hours(subject.hours) + " / " + hours(subject.norm) + " h"
                     : hours(subject.hours) + " h")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.6))
            }

            if subject.hasNorm {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geometry.size.width * subject.progress))
                    }
                }
                .frame(height: 5)
            }

            ForEach(subject.phases) { phase in
                phaseRow(phase)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func phaseRow(_ phase: StudyPhase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phase.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !phase.estimate.isEmpty {
                    // Lectio counts a forløb in "moduler" — lesson blocks.
                    Text(modules(phase.estimate))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.45))
                }
            }
            if !phase.period.isEmpty {
                Text(LectioDates.englishPeriod(phase.period))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            if expanded.contains(phase.id), !phase.summary.isEmpty {
                Text(LectioDates.tidy(phase.summary))
                    .font(.system(size: 14.5))
                    .lineSpacing(2)
                    .foregroundStyle(.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !phase.summary.isEmpty else { return }
            if expanded.contains(phase.id) { expanded.remove(phase.id) }
            else { expanded.insert(phase.id) }
        }
    }

    // MARK: Helpers

    private func modules(_ estimate: String) -> String {
        let trimmed = estimate.replacingOccurrences(of: ",00", with: "")
        return trimmed + (trimmed == "1" ? " module" : " modules")
    }

    private func hours(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private func load() async {
        guard loading else { return }
        let cookies = await session.requestCookies()
        do {
            subjects = try await LectioStudyService.loadStudyPlan(cookies: cookies)
        } catch {
            failed = true
        }
        loading = false
    }
}
