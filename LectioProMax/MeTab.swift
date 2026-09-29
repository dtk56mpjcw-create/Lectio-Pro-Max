import SwiftUI

/// Me: you at a glance. Tiles that answer something without being opened —
/// how much you've missed, your grades, your study hours — plus the student
/// card, with the app's settings behind the gear.
enum MeRoute: Hashable {
    case absence, grades, studyPlan, findSchedule
    case settings, subjectColors, signature
}

struct MeTab: View {
    @Environment(LectioSession.self) private var session
    @State private var showingCard = false

    private var profile: Profile { session.snapshot.profile }
    /// Read from Lectio, not written into the app.
    private var school: String { profile.schoolName ?? LectioConfig.schoolName }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(profile.name.isEmpty ? "Me" : profile.name)
                .navigationSubtitle(subtitle)
                // Find a schedule, pushed from here, has a search of its
                // own; back here it's Me's again.
                .searchedAs(.me)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: MeRoute.settings) {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: MeRoute.self) { route in
                    destination(route)
                }
        }
        .fullScreenCover(isPresented: $showingCard) {
            StudentCardScreen().environment(session)
        }
        .task { await loadAll(force: false) }
    }

    private var subtitle: String {
        [profile.className, school].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func destination(_ route: MeRoute) -> some View {
        switch route {
        case .absence: AbsenceSheet().asPushedScreen()
        case .grades: GradesScreen().toolbarTitleDisplayMode(.inline)
        case .studyPlan: StudyPlanSheet().asPushedScreen()
        case .findSchedule: FindScheduleScreen()
        case .settings: SettingsScreen().toolbarTitleDisplayMode(.inline)
        case .subjectColors: SubjectColorsScreen().toolbarTitleDisplayMode(.inline)
        case .signature: SignatureScreen().toolbarTitleDisplayMode(.inline)
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 10) {
                if profile.isStudent == false {
                    Banner(text: "Lectio Pro Max is made for student accounts. The schedule and messages work, "
                           + "but the class, grades, absence and student card are a student's.")
                }
                // Grid rather than LazyVGrid: it makes the two tiles in a row
                // the same height.
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        NavigationLink(value: MeRoute.absence) { absenceTile }
                            .buttonStyle(PressableCard())
                        NavigationLink(value: MeRoute.grades) { gradesTile }
                            .buttonStyle(PressableCard())
                    }
                    GridRow {
                        NavigationLink(value: MeRoute.studyPlan) { studyTile }
                            .buttonStyle(PressableCard())
                        Button { showingCard = true } label: { cardTile }
                            .buttonStyle(PressableCard())
                    }
                }

                NavigationLink(value: MeRoute.findSchedule) { findRow }
                    .buttonStyle(PressableCard())
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await Task { await loadAll(force: true) }.value }
        .background { AppBackground() }
    }

    private func loadAll(force: Bool) async {
        async let absence: () = session.loadAbsence(force: force)
        async let grades: () = session.loadGrades(force: force)
        async let plan: () = session.loadStudyPlan(force: force)
        _ = await (absence, grades, plan)
    }

    // MARK: Tiles

    private var absenceTile: some View {
        let absence = session.absence
        let unexplained = absence.unexplained.count
        let value: String
        let caption: String
        var captionTint: Color? = nil

        if let total = absence.total {
            value = percent(total.percentValue)
            if unexplained > 0 {
                caption = unexplained == 1 ? "1 to explain" : "\(unexplained) to explain"
                captionTint = Palette.warning
            } else {
                caption = "All explained"
            }
        } else if session.absenceLoading {
            value = "–"
            caption = "Loading…"
        } else if !absence.subjects.isEmpty || !absence.records.isEmpty {
            value = "0 %"
            caption = "No absence"
        } else {
            value = "–"
            caption = " "
        }
        return MeTile(title: "Absence", icon: "calendar.badge.exclamationmark", tint: Palette.warning,
                      value: value, caption: caption, captionTint: captionTint)
    }

    private var gradesTile: some View {
        let value: String
        let caption: String
        if let report = session.grades {
            if let average = report.average {
                value = average.formatted(.number.precision(.fractionLength(1)))
                let count = report.gradedSubjects
                caption = "Average · " + (count == 1 ? "1 subject" : "\(count) subjects")
            } else if report.rows.isEmpty {
                value = "–"
                caption = "No grades yet"
            } else {
                value = "\(report.rows.count)"
                caption = "Subjects"
            }
        } else {
            value = "–"
            caption = "Loading…"
        }
        return MeTile(title: "Grades", icon: "star.fill", tint: .yellow,
                      value: value, caption: caption)
    }

    private var studyTile: some View {
        let value: String
        let caption: String
        var progress: Double? = nil
        if let plan = session.studyPlan {
            let done = plan.reduce(0) { $0 + $1.hours }
            let norm = plan.reduce(0) { $0 + $1.norm }
            value = hours(done) + " h"
            if norm > 0 {
                caption = "of " + hours(norm) + " h study time"
                progress = min(done / norm, 1)
            } else {
                caption = "Study time"
            }
        } else {
            value = "–"
            caption = "Loading…"
        }
        return MeTile(title: "Study plan", icon: "list.bullet.rectangle", tint: .blue,
                      value: value, caption: caption, progress: progress)
    }

    private var cardTile: some View {
        MeTile(title: "Student card", icon: "person.text.rectangle", tint: .green,
               value: "", caption: "Photo & QR code", valueIcon: "qrcode")
    }

    private var findRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.teal)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Find a schedule")
                    .scaledFont(size: 16.5, weight: .semibold)
                Text("Classes, teachers, students and rooms")
                    .scaledFont(size: 13.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 4)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .foregroundStyle(.primary)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + " %"
    }

    private func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// A small card that answers one question: a label, one number, one line.
struct MeTile: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let caption: String
    var captionTint: Color? = nil
    var progress: Double? = nil
    /// Shown instead of a number, for a tile that opens something.
    var valueIcon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(tint)
                Text(title)
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Group {
                if let valueIcon {
                    Image(systemName: valueIcon)
                        .scaledFont(size: 24, weight: .semibold)
                } else {
                    Text(value)
                        .scaledFont(size: 26, weight: .bold, design: .rounded)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(minHeight: 30, alignment: .leading)

            Text(caption)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(captionTint ?? Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let progress {
                ProgressView(value: progress)
                    .tint(tint)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(radius: Metrics.inner + 4)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.inner + 4, style: .continuous))
        .foregroundStyle(.primary)
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}
