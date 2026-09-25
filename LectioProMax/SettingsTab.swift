import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var session: LectioSession
    @State private var showingAbsence = false
    @State private var showingStudyPlan = false
    @State private var showingFind = false

    private var profile: Profile { session.snapshot.profile }

    var body: some View {
        ScrollView {
            RefreshHeader(space: "settings") { await session.refresh() }
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Settings")
                    .padding(.top, 6)

                accountCard
                lectioCard
                actionsCard

                if let fetched = session.snapshot.fetchedAt {
                    Text("Last updated \(LectioDates.timeString(fetched))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }

            }
            .padding(.horizontal, Metrics.margin)
        }
        .coordinateSpace(.named("settings"))
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingAbsence) { AbsenceSheet().environmentObject(session) }
        .sheet(isPresented: $showingStudyPlan) { StudyPlanSheet().environmentObject(session) }
        .sheet(isPresented: $showingFind) { FindScheduleSheet().environmentObject(session) }
    }

    private var lectioCard: some View {
        VStack(spacing: 0) {
            row("Study plan", "list.bullet.rectangle", tint: Color.primary) {
                showingStudyPlan = true
            }
            Divider().padding(.leading, 48)
            row("Absence", "calendar.badge.exclamationmark", tint: Color.primary) {
                showingAbsence = true
            }
            Divider().padding(.leading, 48)
            row("Find a schedule", "magnifyingglass", tint: Color.primary) {
                showingFind = true
            }
        }
        .contentCard()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name.isEmpty ? "Signed in" : profile.name)
                .font(.system(size: 22, weight: .bold))
            Text(profile.className.isEmpty
                 ? "Nørre Gymnasium"
                 : "Class " + profile.className + " · Nørre Gymnasium")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            row("Refresh now", "arrow.clockwise", tint: Color.primary) {
                Task { await session.refresh() }
            }
            Divider().padding(.leading, 48)
            row("Sign out", "rectangle.portrait.and.arrow.right", tint: .red) {
                Task { await session.signOut() }
            }
        }
        .contentCard()
    }

    private func row(_ title: String, _ icon: String,
                     tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 15.5, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
