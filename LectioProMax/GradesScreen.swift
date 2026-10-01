import SwiftUI

/// Me → Grades: each subject's grades as Lectio lists them, your weighted
/// average, and any notes your teachers wrote.
struct GradesScreen: View {
    @Environment(LectioSession.self) private var session
    /// True until the first load has answered, so an empty screen never
    /// flashes "couldn't reach Lectio" before it's even asked.
    @State private var loading = true

    private var report: GradeReport? { session.grades }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grades")
                        .scaledFont(size: 26, weight: .bold)
                    Text("This school year, from Lectio.")
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                }

                if let report {
                    if report.rows.isEmpty {
                        EmptyNotice(icon: "star", text: "No grades yet")
                        Text("They'll show here as soon as your teachers give them.")
                            .scaledFont(size: 14.5)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    } else {
                        if let average = report.average { averageCard(average, report) }
                        subjects(report)
                        if !report.notes.isEmpty { notes(report.notes) }
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    EmptyNotice(icon: "arrow.clockwise", text: "Couldn't reach Lectio")
                }

                if let url = URL(string: LectioMeService.gradesURL) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "safari").scaledFont(size: 15, weight: .semibold)
                            Text("Open in Lectio").scaledFont(size: 16, weight: .semibold)
                            Spacer()
                            Image(systemName: "arrow.up.right").scaledFont(size: 12.5, weight: .bold)
                        }
                        .foregroundStyle(Palette.accent)
                        .padding(15)
                        .frame(maxWidth: .infinity)
                        .contentCard(radius: Metrics.inner + 2)
                    }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        .refreshable { await Task { await session.loadGrades(force: true) }.value }
        .task {
            loading = true
            await session.loadGrades()
            loading = false
        }
    }

    // MARK: Pieces

    private func averageCard(_ average: Double, _ report: GradeReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(average.formatted(.number.precision(.fractionLength(1))))
                .scaledFont(size: 40, weight: .bold, design: .rounded)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text("Average")
                    .scaledFont(size: 16, weight: .semibold)
                Text("Newest grade in \(report.gradedSubjects) subject\(report.gradedSubjects == 1 ? "" : "s"), weighted")
                    .scaledFont(size: 13.5)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private func subjects(_ report: GradeReport) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(report.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 34) }
                subjectRow(row)
            }
        }
        .contentCard()
    }

    private func subjectRow(_ row: GradeRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SubjectDot(code: row.team, size: 9)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: row))
                    .scaledFont(size: 16.5, weight: .semibold)
                    .lineLimit(2)
                Text(row.team)
                    .scaledFont(size: 13.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                ForEach(row.cells, id: \.column) { cell in
                    VStack(spacing: 1) {
                        Text(cell.grade.isEmpty ? "–" : cell.grade)
                            .scaledFont(size: 19, weight: .bold, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(cell.grade.isEmpty ? Color(.tertiaryLabel) : Color.primary)
                        Text(Self.short(cell.column))
                            .scaledFont(size: 10.5, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 36)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func title(for row: GradeRow) -> String {
        if !row.subject.isEmpty { return row.subject }
        if let key = SubjectPalette.subjectKey(row.team) { return SubjectNames.name(forKey: key) }
        return row.team
    }

    /// Lectio's column headings are long and Danish; the row only has room
    /// for a word.
    static func short(_ column: String) -> String {
        let c = column.lowercased()
        if c.contains("1. standpunkt") { return "1st" }
        if c.contains("2. standpunkt") { return "2nd" }
        if c.contains("3. standpunkt") { return "3rd" }
        if c.contains("intern") { return "Internal" }
        if c.contains("eksamen") || c.contains("prøve") { return "Exam" }
        if c.contains("års") || c.contains("afsluttende") { return "Final" }
        return column.count <= 10 ? column : String(column.prefix(9)) + "…"
    }

    private func notes(_ notes: [GradeNote]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 9) {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(note.fields.enumerated()), id: \.offset) { _, field in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(field.label)
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .leading)
                                Text(field.value)
                                    .scaledFont(size: 15)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(radius: Metrics.inner + 2)
                }
            }
        }
    }
}
