import SwiftUI
import Observation

// MARK: - Where each tab is

// The day, the week, the folder, the filter and the pages pushed are kept
// here rather than in each tab's own @State. They were shared with a working
// copy of the tab behind the search field; that copy is gone (a still
// picture now, see SearchTab), and they could go back into the tabs' @State.
// They stay for now, as they work.
//
// RootView owns one of each, so signing out and in starts afresh, and hands
// them down in the environment.

/// Schedule: the day, the week, day or week view, and the lessons open on
/// top.
@MainActor
@Observable
final class SchedulePlace {
    var selectedDate: String
    /// Where each pager rests: a swipe writes it, and writing it jumps.
    var dayPage: String?
    var weekPage: String?
    var weekMode = false
    /// The lessons pushed on top; the cards open them through it.
    let opener = LessonOpener()

    init() {
        let today = LectioDates.isoString(from: Date())
        selectedDate = today
        dayPage = today
        weekPage = ScheduleTab.monday(of: today)
    }
}

/// Homework: the filter, and the homework or assignment open on top.
@MainActor
@Observable
final class HomeworkPlace {
    /// Not saved between launches, on purpose — see WorkFilter.
    var filter = WorkFilter()
    var path: [WorkItem] = []
}

/// Messages: the folder, its threads, and the thread open on top.
@MainActor
@Observable
final class MessagesPlace {
    /// Changed through `open(_:)`.
    private(set) var folder: MessageFolder = .newest
    /// Threads of any folder but Newest, which lives on the session (the
    /// unread badge and Search read it too).
    var folderThreads: [MessageThreadSummary] = []
    var folderLoading = false
    /// Which folder `folderThreads` is, and when it came. The tab asks for
    /// the folder each time it appears; a minute-old answer is used as it
    /// is instead of fetched again.
    var folderLoaded: (folder: MessageFolder, at: Date)?
    var path: [MessageThreadSummary] = []

    func isFresh(_ folder: MessageFolder) -> Bool {
        guard let folderLoaded, folderLoaded.folder == folder else { return false }
        return Date().timeIntervalSince(folderLoaded.at) < 60
    }

    /// Another folder: nothing of the last one is shown under its title
    /// while its own threads come.
    func open(_ folder: MessageFolder) {
        guard folder != self.folder else { return }
        self.folder = folder
        folderThreads = []
        folderLoaded = nil
    }
}

/// Me: the pages open on top — absence, grades, Find a schedule and
/// someone's schedule from there, Settings…
@MainActor
@Observable
final class MePlace {
    var path = NavigationPath()
}

/// Someone's schedule (TargetScheduleScreen), where you left it and the
/// weeks already fetched. Opened again within ten minutes of leaving it,
/// it's where you left it and fetches nothing again; after that it starts
/// afresh from today.
@MainActor
@Observable
final class TargetPlace {
    var loadedWeeks: [String: ScheduleWeek] = [:]
    var failedWeeks: Set<String> = []
    var selectedDate: String
    var dayPage: String?
    var weekPage: String?
    var weekMode = false
    /// When it was last on screen.
    @ObservationIgnored private var seen = Date()

    private init() {
        let today = LectioDates.isoString(from: Date())
        selectedDate = today
        dayPage = today
        weekPage = ScheduleTab.monday(of: today)
    }

    /// One per schedule for as long as you're signed in, so every screen
    /// showing it gets the same one. A time limit here could hand a copy a new one
    /// while the old one is still on screen; `appeared()` does the
    /// starting afresh instead.
    private static var all: [String: TargetPlace] = [:]

    static func of(_ target: ScheduleTarget) -> TargetPlace {
        if let place = all[target.id] { return place }
        let place = TargetPlace()
        all[target.id] = place
        return place
    }

    /// On screen again. After ten minutes away: today, fetched afresh,
    /// as if opened for the first time.
    func appeared() {
        if Date().timeIntervalSince(seen) > 600 {
            let today = LectioDates.isoString(from: Date())
            loadedWeeks = [:]
            failedWeeks = []
            selectedDate = today
            dayPage = today
            weekPage = ScheduleTab.monday(of: today)
            weekMode = false
        }
        seen = Date()
    }

    func disappeared() {
        seen = Date()
    }

    /// Signing out: nobody's schedule is kept.
    static func forgetAll() {
        all = [:]
    }
}
