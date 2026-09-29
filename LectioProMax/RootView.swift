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
    /// The tab search was pressed on. The search tab shows it behind the
    /// field, where you left it, until you type; set the moment search is
    /// pressed.
    @State private var searchSource: AppTab = .schedule
    /// What was searched the last time search was pressed.
    @State private var lastContext: SearchKind = .schedule

    /// Where each tab is, shared by the tab and its copy behind the search
    /// field (see TabPlaces). Here, so signing in again starts afresh.
    @State private var schedulePlace = SchedulePlace()
    @State private var homeworkPlace = HomeworkPlace()
    @State private var messagesPlace = MessagesPlace()
    @State private var mePlace = MePlace()
    /// Find on the page open in the copy behind the search (PageFind).
    @State private var pageFind = PageFind()

    /// What the search searches: the tab's own, or the screen's on top
    /// (see SearchContexts). Followed as it changes, because the copy of
    /// the tab behind the field works: go back a page in it, and it's the
    /// tab's search again.
    private var searchContext: SearchKind {
        SearchContexts.shared.context(for: searchSource)
    }

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
                SearchTab(query: query, source: searchSource, context: searchContext, find: pageFind)
                    .searchable(text: $query, prompt: searchContext.prompt)
                    // The Search key on the keyboard: the next match on the
                    // page, as in Safari.
                    .onSubmit(of: .search) {
                        if searchContext == .page { pageFind.next() }
                    }
            }
        }
        .environment(schedulePlace)
        .environment(homeworkPlace)
        .environment(messagesPlace)
        .environment(mePlace)
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
        // Another tab's or another page's search starts empty.
        if old != searchSource || context != lastContext { query = "" }
        searchSource = old
        lastContext = context
    }
}
