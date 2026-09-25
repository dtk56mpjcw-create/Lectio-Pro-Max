import SwiftUI

enum AppTab: String, Hashable {
    case schedule, homework, messages, settings, search
}

/// The native TabView is what gives us Apple's real Liquid Glass tab bar —
/// finger-tracking highlight, morphing, and minimising on scroll — rather than
/// the hand-rolled approximation this used to be.
struct RootView: View {
    @EnvironmentObject private var session: LectioSession
    @State private var tab: AppTab = .schedule
    @State private var query = ""

    var body: some View {
        TabView(selection: $tab) {
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                // Its own navigation stack draws the background.
                ScheduleTab()
            }
            // Each tab is its own navigation stack and draws its own background.
            Tab("Homework", systemImage: "checklist", value: AppTab.homework) {
                HomeworkTab()
                    .badge(session.snapshot.outstandingCount)
            }
            Tab("Messages", systemImage: "envelope", value: AppTab.messages) {
                MessagesTab()
                    .badge(session.snapshot.unreadMessages)
            }
            Tab("More", systemImage: "ellipsis", value: AppTab.settings) {
                SettingsTab()
            }
            // Search is a tab of its own at the trailing end of the bar, as
            // iOS 26 lays it out; the searchable field below belongs to it.
            Tab(value: AppTab.search, role: .search) {
                SearchTab(query: query)
            }
        }
        .searchable(text: $query, prompt: "Homework, messages, lessons")
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
