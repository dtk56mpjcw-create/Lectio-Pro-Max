import SwiftUI

enum AppTab: String, Hashable {
    case schedule, homework, messages, me, search
}

/// The native TabView is what gives us Apple's real Liquid Glass tab bar —
/// finger-tracking highlight, morphing, and minimising on scroll — rather than
/// the hand-rolled approximation this used to be.
struct RootView: View {
    @Environment(LectioSession.self) private var session
    @State private var tab: AppTab = .schedule
    @State private var query = ""
    /// The search the search button opens: the tab you were on's, or the
    /// screen you were on's own (see SearchContexts). Only read in the
    /// search tab; set the moment search is pressed.
    @State private var searchContext: SearchKind = .schedule

    /// The tab bar's selection. Pressing search goes through here, so the
    /// search is picked from where you were in the same moment, before the
    /// search tab draws: its title can't show the last search's first.
    private var selection: Binding<AppTab> {
        Binding {
            tab
        } set: { new in
            if new == .search, tab != .search { openSearch(from: tab) }
            tab = new
        }
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                // Its own navigation stack draws the background.
                ScheduleTab()
                    .environment(\.hostTab, .schedule)
            }
            // Each tab is its own navigation stack and draws its own background.
            Tab("Homework", systemImage: "checklist", value: AppTab.homework) {
                HomeworkTab()
                    .badge(session.snapshot.outstandingCount)
                    .environment(\.hostTab, .homework)
            }
            Tab("Messages", systemImage: "envelope", value: AppTab.messages) {
                MessagesTab()
                    .badge(session.snapshot.unreadMessages)
                    .environment(\.hostTab, .messages)
            }
            Tab("Me", systemImage: "person.crop.circle", value: AppTab.me) {
                MeTab()
                    .environment(\.hostTab, .me)
            }
            // Search is a tab of its own at the trailing end of the bar, as
            // iOS 26 lays it out (iOS 27 puts it back in the bar), and it
            // searches the tab you were on (see SearchTab). Its field is
            // attached here, to this tab alone: on the TabView it reached
            // every tab's navigation bar too, and on some phones a search
            // field sat over the Schedule and Homework headings — or hid
            // under them, so pulling a page down tugged at a field that
            // wasn't there.
            Tab(value: AppTab.search, role: .search) {
                SearchTab(query: query, context: searchContext)
                    .searchable(text: $query, prompt: searchContext.prompt)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // A widget or a notification: go to what it showed (see AppLink).
        .onOpenURL { AppRouter.shared.open($0) }
        // `initial`: a tap that launched the app can arrive before this
        // view does, and must still pick the tab.
        .onChange(of: AppRouter.shared.request, initial: true) { _, request in
            guard let request else { return }
            switch request.route {
            case .day, .lesson:
                tab = .schedule          // the Schedule tab takes it from here
            case .homework:
                tab = .homework
                AppRouter.shared.request = nil
            case .messages:
                tab = .messages
                AppRouter.shared.request = nil
            }
        }
    }

    /// Search was pressed on `old`: it searches what you were looking at.
    ///
    /// Read now, from the screen on show, rather than kept up to date as
    /// tabs change. Me › Find a schedule and someone's schedule are in the
    /// Me tab but have a search of their own, and pressing search there
    /// said "Search Me" (Dan, 29 Sep). A widget or a notification can also
    /// change tabs without the tab bar; that no longer matters either.
    private func openSearch(from old: AppTab) {
        let context = SearchContexts.shared.context(for: old)
        guard context != searchContext else { return }
        searchContext = context
        query = ""      // another tab's search starts empty
    }
}
