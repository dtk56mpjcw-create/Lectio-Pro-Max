import SwiftUI
import UIKit

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
    /// The search field is out, and has the keyboard. One tap on the search
    /// button should do both (TabBarBridge.searchTabActivatesField); the
    /// first tap used to only open the field, and a second one started
    /// typing (Dan, 29 Sep).
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool

    // What search was pressed on, all read in that moment (openSearch):
    /// the tab,
    @State private var searchSource: AppTab = .schedule
    /// what's searched there,
    @State private var searchContext: SearchKind = .schedule
    /// the open page, to find on (nil on a tab's first page),
    @State private var searchPage: SearchContexts.Page?
    /// and a picture of the screen, to keep behind the field.
    @State private var searchPicture: UIView?

    /// Where each tab is (see TabPlaces). Here, so signing in again starts
    /// afresh.
    @State private var schedulePlace = SchedulePlace()
    @State private var homeworkPlace = HomeworkPlace()
    @State private var messagesPlace = MessagesPlace()
    @State private var mePlace = MePlace()
    /// Find on the open page, in the search tab (PageFind).
    @State private var pageFind = PageFind()

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
                SearchTab(query: $query, presented: $searchPresented,
                          context: searchContext, page: searchPage, picture: searchPicture,
                          find: pageFind, leave: leaveSearch)
                    // The one field, at the bottom, on the first page of the
                    // search tab's stack: the only page it has, until a
                    // result is opened.
                    .searchable(text: $query, isPresented: $searchPresented,
                                prompt: searchContext.prompt)
                    .searchFocused($searchFocused)
                    // The Search key on the keyboard: the next match on the
                    // page, as in Safari.
                    .onSubmit(of: .search) {
                        if searchContext == .page { pageFind.next() }
                    }
            }
        }
        .onChange(of: tab) { old, new in
            SearchLog.note("tab \(old) → \(new), searching \(searchContext), picture: \(searchPicture != nil)")
            if new == .search { makeSureTheFieldIsOut() }
        }
        // Before the first tap on search.
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            TabBarBridge.searchTabActivatesField()
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
        let contexts = SearchContexts.shared
        let context = contexts.context(for: old)
        // Another tab's or another page's search starts empty.
        if old != searchSource || context != searchContext { query = "" }
        searchSource = old
        searchContext = context
        searchPage = contexts.page(for: old)
        // Now, before the search tab takes the screen.
        searchPicture = TabBarBridge.pictureOfSelectedTab()
        // In case SwiftUI made the tabs again since launch.
        TabBarBridge.searchTabActivatesField()
    }

    /// One tap should open the field ready to type, by iOS's own setting
    /// (TabBarBridge.searchTabActivatesField). Only if it didn't, after the
    /// tab bar has turned into the field, SwiftUI is asked instead. Asked
    /// right away that was ignored, and a fixed wait before asking made the
    /// keyboard come in a second, separate step.
    private func makeSureTheFieldIsOut() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard tab == .search else { return }
            SearchLog.note("after opening: field out \(searchPresented), keyboard \(searchFocused)")
            guard !searchPresented else { return }
            searchPresented = true
            searchFocused = true
            SearchLog.note("had to ask for the field")
        }
    }

    /// The field was closed: back to where search was pressed, as you left
    /// it. The search tab used to stay on, with a field you couldn't type
    /// in (Dan, 29 Sep).
    private func leaveSearch() {
        guard tab == .search else { return }
        SearchLog.note("field closed: back to \(searchSource)")
        query = ""
        tab = searchSource
    }
}
