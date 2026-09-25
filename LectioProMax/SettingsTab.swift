import SwiftUI

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsTab: View {
    @EnvironmentObject private var session: LectioSession
    @AppStorage("appTheme") private var themeRaw: String = AppTheme.system.rawValue
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
                appearanceCard
                actionsCard

                if let fetched = session.snapshot.fetchedAt {
                    Text("Last updated \(LectioDates.timeString(fetched))")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.58))
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(profile.className.isEmpty
                 ? "Nørre Gymnasium"
                 : "Class " + profile.className + " · Nørre Gymnasium")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.72))
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APPEARANCE")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.primary.opacity(0.58))

            HStack(spacing: 8) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Button {
                        withAnimation(.snappy(duration: 0.24, extraBounce: 0.12)) {
                            themeRaw = theme.rawValue
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: theme.icon)
                                .font(.system(size: 17, weight: .semibold))
                            Text(theme.label)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background {
                            if themeRaw == theme.rawValue {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.9)
                                    )
                            }
                        }
                        .foregroundStyle(themeRaw == theme.rawValue
                                         ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(PressableCard())
                }
            }
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
            row("Sign out", "rectangle.portrait.and.arrow.right", tint: Palette.accent) {
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
