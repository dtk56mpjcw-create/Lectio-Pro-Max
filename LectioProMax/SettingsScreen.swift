import SwiftUI
import UserNotifications

/// Me → gear: how the app looks and behaves, and your account.
struct SettingsScreen: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var notifications: UNAuthorizationStatus?
    @State private var confirmingSignOut = false

    private var school: String {
        session.snapshot.profile.schoolName ?? LectioConfig.schoolName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .scaledFont(size: 26, weight: .bold)

                section("Appearance") {
                    link("Subject colours", "paintpalette", .pink, to: .subjectColors)
                }

                section("Messages") {
                    link("Message signature", "signature", .blue, to: .signature)
                }

                section("Notifications") {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        row("Notifications", "bell.badge", .red, value: notificationText, chevron: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                }

                section("Account") {
                    row("School", "building.columns", .gray, value: school, chevron: nil)
                    Divider().padding(.leading, 56)
                    Button {
                        confirmingSignOut = true
                    } label: {
                        HStack(spacing: 13) {
                            icon("rectangle.portrait.and.arrow.right", .red)
                            Text("Sign out")
                                .scaledFont(size: 16.5, weight: .medium)
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                footer
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        .task { await readNotificationStatus() }
        // Back from the Settings app with notifications switched.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await readNotificationStatus() } }
        }
        .confirmationDialog("Sign out of Lectio?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await session.signOut() }
            }
        } message: {
            Text("You can change school when you sign in again.")
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .scaledFont(size: 12.5, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .contentCard()
        }
    }

    /// Settings' coloured icon square.
    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color,
                     value: String?, chevron: String?) -> some View {
        HStack(spacing: 13) {
            icon(symbol, tint)
            Text(title)
                .scaledFont(size: 16.5, weight: .medium)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .scaledFont(size: 15.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let chevron {
                Image(systemName: chevron)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func link(_ title: String, _ symbol: String, _ tint: Color, to route: MeRoute) -> some View {
        NavigationLink(value: route) {
            row(title, symbol, tint, value: nil, chevron: "chevron.right")
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 3) {
            if let fetched = session.snapshot.fetchedAt {
                Text("Last updated \(LectioDates.timeString(fetched))")
            }
            Text("Lectio Pro Max \(version)")
        }
        .scaledFont(size: 13)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var notificationText: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not set up"
        default: return ""
        }
    }

    private func readNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = settings.authorizationStatus
    }
}
