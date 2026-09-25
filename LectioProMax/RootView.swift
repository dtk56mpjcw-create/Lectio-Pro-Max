import SwiftUI

enum AppTab: String, Hashable {
    case schedule, homework, messages, settings
}

/// The native TabView is what gives us Apple's real Liquid Glass tab bar —
/// finger-tracking highlight, morphing, and minimising on scroll — rather than
/// the hand-rolled approximation this used to be.
struct RootView: View {
    @EnvironmentObject private var session: LectioSession
    @State private var tab: AppTab = .schedule

    var body: some View {
        TabView(selection: $tab) {
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                ScheduleTab()
                    .background { AppBackground() }
            }
            Tab("Homework", systemImage: "checklist", value: AppTab.homework) {
                HomeworkTab()
                    .background { AppBackground() }
                    .badge(session.snapshot.outstandingCount)
            }
            Tab("Messages", systemImage: "envelope", value: AppTab.messages) {
                MessagesTab()
                    .background { AppBackground() }
                    .badge(session.snapshot.unreadMessages)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
                    .background { AppBackground() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
