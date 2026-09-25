import SwiftUI

struct ContentView: View {
    @StateObject private var session = LectioSession()
    @AppStorage("appTheme") private var themeRaw: String = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environmentObject(session)
            .task {
                await session.bootstrap()
            }
            .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
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

struct LoginScreen: View {
    @EnvironmentObject private var session: LectioSession

    var body: some View {
        NavigationStack {
            LoginWebView {
                Task { await session.handleLoginSucceeded() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in to Lectio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
