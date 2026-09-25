import SwiftUI

/// Where the rest of Lectio lives in the app — study plan, absence, other
/// people's schedules — plus your account. Called More, as in Apple's own
/// apps: it's mostly places to go, not settings.
enum MoreRoute: Hashable {
    case studyPlan, absence, findSchedule
}

struct SettingsTab: View {
    @EnvironmentObject private var session: LectioSession

    private var profile: Profile { session.snapshot.profile }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("More")
                // Each opens as a page of its own, with the system back button.
                .navigationDestination(for: MoreRoute.self) { route in
                    switch route {
                    case .studyPlan: StudyPlanSheet().asPushedScreen()
                    case .absence: AbsenceSheet().asPushedScreen()
                    case .findSchedule: FindScheduleSheet().asPushedScreen()
                    }
                }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // The system's own pull to refresh, the work in a task of its own so
        // an update mid-refresh can't cancel it.
        .refreshable { await Task { await session.refresh() }.value }
        .background { AppBackground() }
    }

    private var lectioCard: some View {
        VStack(spacing: 0) {
            link("Study plan", "list.bullet.rectangle", to: .studyPlan)
            Divider().padding(.leading, 48)
            link("Absence", "calendar.badge.exclamationmark", to: .absence)
            Divider().padding(.leading, 48)
            link("Find a schedule", "magnifyingglass", to: .findSchedule)
        }
        .contentCard()
    }

    /// A row that goes somewhere: a chevron, like Settings.
    private func link(_ title: String, _ icon: String, to route: MoreRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 15.5, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
