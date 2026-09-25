import SwiftUI

struct ContentView: View {
    @StateObject private var session = LectioSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environmentObject(session)
            .task {
                await session.bootstrap()
            }
            // No in-app light/dark switch: Apple's Dark Mode guidance asks apps to
            // follow the phone's own setting, which people expect to apply everywhere.
            .fullScreenCover(isPresented: $session.showLogin) {
                LoginScreen()
                    .environmentObject(session)
                    .interactiveDismissDisabled(true)
            }
            // Reopening the app pulls straight from Lectio, so what you see is
            // whatever is actually on Lectio right now.
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active && session.hasLoadedOnce && !session.showLogin {
                    Task { await session.refresh() }
                }
            }
    }
}

/// Signing in: first which school (Lectio is per school — its number is in
/// every address), then that school's own Lectio login.
struct LoginScreen: View {
    @EnvironmentObject private var session: LectioSession
    @State private var pickingSchool = !LectioConfig.hasChosenSchool
    @State private var schoolName = LectioConfig.schoolName

    var body: some View {
        NavigationStack {
            if pickingSchool {
                SchoolPicker { school in
                    LectioConfig.choose(school)
                    schoolName = school.name
                    pickingSchool = false
                }
            } else {
                LoginWebView {
                    Task { await session.handleLoginSucceeded() }
                }
                // A fresh web view per school, so it loads that school's login.
                .id(LectioConfig.schoolID)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(schoolName.isEmpty ? "Sign in to Lectio" : schoolName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Change school") { pickingSchool = true }
                    }
                }
            }
        }
    }
}
