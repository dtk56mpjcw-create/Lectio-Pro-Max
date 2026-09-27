import SwiftUI
import UserNotifications

/// Me → gear: how the app looks and behaves, and your account.
struct SettingsScreen: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var notifications: UNAuthorizationStatus?
    @State private var confirmingSignOut = false

    @State private var sessionStatus: LectioCookies.Status?
    @State private var testResult: String?
    @State private var testing = false

    @AppStorage(NotifyPrefs.changesKey) private var notifyChanges = true
    @AppStorage(NotifyPrefs.messagesKey) private var notifyMessages = true
    @AppStorage(NotifyPrefs.workKey) private var notifyWork = true
    @AppStorage(NotifyPrefs.lessonsKey) private var notifyLessons = false
    @AppStorage(NotifyPrefs.leadKey) private var lessonLead = 5

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

                section("Notifications",
                        footer: "Changes, messages and homework are looked for in the background when iOS allows it, so they can come a little late. Reminders before lessons are always on time.") {
                    Button {
                        if notifications == .notDetermined {
                            Task { await askIfNeeded() }
                        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        row("Notifications", "bell.badge", .red, value: notificationText,
                            chevron: notifications == .notDetermined ? nil : "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 56)
                    toggleRow("Schedule changes", "calendar.badge.exclamationmark", .orange, isOn: $notifyChanges)
                    Divider().padding(.leading, 56)
                    toggleRow("New messages", "envelope.badge", .blue, isOn: $notifyMessages)
                    Divider().padding(.leading, 56)
                    toggleRow("New homework", "book.closed", .green, isOn: $notifyWork)
                    Divider().padding(.leading, 56)
                    toggleRow("Before each lesson", "clock", .purple, isOn: $notifyLessons)
                    if notifyLessons {
                        Divider().padding(.leading, 56)
                        leadRow
                    }
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

                #if DEBUG
                section("Testing",
                        footer: "Only in builds from Xcode. Expire session throws the Lectio session away as if it had run out, to check the app gets back in by itself with the auto-login key.") {
                    row("Auto-login key", "key.fill", .gray, value: keyText, chevron: nil)
                    Divider().padding(.leading, 56)
                    row("Session", "clock.arrow.circlepath", .gray, value: sessionText, chevron: nil)
                    Divider().padding(.leading, 56)
                    Button {
                        Task { await expireSession() }
                    } label: {
                        row("Expire session", "bolt.horizontal.fill", .orange, value: testResult, chevron: nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(testing)
                }
                #endif

                footer
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        .task {
            await readNotificationStatus()
            sessionStatus = await LectioCookies.shared.status()
        }
        .onChange(of: notifyChanges) { _, on in if on { Task { await askIfNeeded() } } }
        .onChange(of: notifyMessages) { _, on in if on { Task { await askIfNeeded() } } }
        .onChange(of: notifyWork) { _, on in if on { Task { await askIfNeeded() } } }
        .onChange(of: notifyLessons) { _, on in Task { await lessonRemindersChanged(asking: on) } }
        .onChange(of: lessonLead) { _, _ in Task { await lessonRemindersChanged(asking: false) } }
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

    private func section<Content: View>(_ title: String, footer: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .scaledFont(size: 12.5, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .contentCard()
            if let footer {
                Text(footer)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// A row with a switch, the same height as the others.
    private func toggleRow(_ title: String, _ symbol: String, _ tint: Color,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 13) {
                icon(symbol, tint)
                Text(title)
                    .scaledFont(size: 16.5, weight: .medium)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// How long before a lesson its reminder comes. A menu whose label is
    /// one line in the row's own type, so the row is as tall as the others.
    private var leadRow: some View {
        HStack(spacing: 13) {
            icon("timer", .gray)
            Text("Remind me")
                .scaledFont(size: 16.5, weight: .medium)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Picker("Remind me", selection: $lessonLead) {
                    ForEach(NotifyPrefs.leads, id: \.self) { minutes in
                        Text("\(minutes) min before").tag(minutes)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(lessonLead) min before")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                }
                .scaledFont(size: 15.5)
                .fixedSize()
            }
            .accessibilityLabel("Remind me")
            .accessibilityValue("\(lessonLead) minutes before")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Settings' coloured icon square.
    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)   // the row's words say it
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
            // Said plainly, as the App Store and Macom would expect.
            Text("An unofficial app, not made by Macom or your school.")
        }
        .multilineTextAlignment(.center)
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
        case .notDetermined: return "Turn on"
        default: return ""
        }
    }

    // MARK: Testing the session

    private var keyText: String {
        guard let status = sessionStatus else { return "" }
        guard status.hasKey else { return "Missing" }
        return status.keyExpires.map { "Until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Saved"
    }

    private var sessionText: String {
        guard let status = sessionStatus else { return "" }
        return status.hasSession ? "Active" : "None"
    }

    private func expireSession() async {
        testing = true
        testResult = "Checking…"
        let renewed = await session.simulateExpiredSession()
        testResult = renewed ? "Got back in" : "Needed a sign-in"
        sessionStatus = await LectioCookies.shared.status()
        testing = false
    }

    /// Asks for permission the first time something is switched on.
    private func askIfNeeded() async {
        guard notifications == .notDetermined else { return }
        _ = await NotificationService.requestPermission()
        await readNotificationStatus()
    }

    private func lessonRemindersChanged(asking: Bool) async {
        if asking { await askIfNeeded() }
        let feed = WidgetFeedBuilder.latest ?? WidgetFeedBuilder.build(from: session.snapshot)
        await NotificationService.rescheduleLessons(from: feed)
    }

    private func readNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = settings.authorizationStatus
    }
}
