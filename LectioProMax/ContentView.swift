import SwiftUI

struct ContentView: View {
    @State private var session = LectioSession()
    @Environment(\.scenePhase) private var scenePhase
    /// Set when the app goes to the background, so coming back refreshes —
    /// but pulling down Control Centre or a notification (which only makes
    /// the app inactive for a moment) doesn't fetch four pages again.
    @State private var wasAway = false

    var body: some View {
        RootView()
            .environment(session)
            .task {
                await session.bootstrap()
            }
            // No in-app light/dark switch: Apple's Dark Mode guidance asks apps to
            // follow the phone's own setting, which people expect to apply everywhere.
            .fullScreenCover(isPresented: $session.showLogin) {
                LoginScreen()
                    .environment(session)
                    .interactiveDismissDisabled(true)
            }
            // Reopening the app pulls straight from Lectio, so what you see is
            // whatever is actually on Lectio right now.
            .onChange(of: scenePhase) { _, newPhase in
                // Back in the app: a new day since you left moves the
                // schedule on (see DayClock).
                if newPhase == .active { DayClock.shared.refresh() }
                if newPhase == .active && wasAway {
                    wasAway = false
                    if session.hasLoadedOnce && !session.showLogin {
                        Task { await session.refresh() }
                    }
                }
                if newPhase == .background {
                    wasAway = true
                    // Leaving the app: ask iOS to look for news in a while.
                    if session.isLoggedIn { BackgroundCheck.schedule() }
                }
            }
    }
}

/// Signing in: first which school (Lectio is per school — its number is in
/// every address), then that school's own Lectio login.
struct LoginScreen: View {
    @Environment(LectioSession.self) private var session
    @State private var pickingSchool = !LectioConfig.hasChosenSchool
    @State private var schoolName = LectioConfig.schoolName
    /// Bumped by Reload: a new web view, starting the sign-in over.
    @State private var attempt = 0

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
                // A fresh web view per school, so it loads that school's
                // login — and per Reload.
                .id(LectioConfig.schoolID + "#\(attempt)")
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(schoolName.isEmpty ? "Sign in to Lectio" : schoolName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Change school") { pickingSchool = true }
                    }
                    // When Lectio's page is stuck on an error: start over.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reload", systemImage: "arrow.clockwise") { attempt += 1 }
                    }
                }
            }
        }
    }
}
