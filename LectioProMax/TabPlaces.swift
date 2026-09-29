import SwiftUI
import Observation

// MARK: - Where each tab is

// The day, the week, the folder, the filter and the pages pushed are kept
// here rather than in each tab's own @State, because the search shows a
// second copy of the tab you came from behind its field (SearchTab), and
// both copies must be in the same place: the same day, the same folder, the
// same open homework. Paging a day in the copy moves the real Schedule too,
// which is what you'd expect.
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
    /// Which folder `folderThreads` is, and when it came. The tab and its
    /// copy behind the search both ask for the folder as they appear; a
    /// minute-old answer is used as it is instead of fetched again.
    var folderLoaded: (folder: MessageFolder, at: Date)?
    var path: [MessageThreadSummary] = []

    func isFresh(_ folder: MessageFolder) -> Bool {
        guard let folderLoaded, folderLoaded.folder == folder else { return false }
        return Date().timeIntervalSince(folderLoaded.at) < 60
    }

    /// Another folder: nothing of the last one is shown under its title
    /// while its own threads come. Done here, not in the tab's onChange,
    /// so the copy of the tab that wasn't on screen can't clear threads
    /// the other one has since fetched.
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
/// weeks already fetched. The same one whether it's open in the Me tab or
/// in its copy behind the search field, so that copy is on the same day
/// and fetches nothing again. Opened again within a few minutes, it's
/// still there; after that it starts afresh from today.
@MainActor
@Observable
final class TargetPlace {
    var loadedWeeks: [String: ScheduleWeek] = [:]
    var failedWeeks: Set<String> = []
    var selectedDate: String
    var dayPage: String?
    var weekPage: String?
    var weekMode = false
    @ObservationIgnored private var touched = Date()

    private init() {
        let today = LectioDates.isoString(from: Date())
        selectedDate = today
        dayPage = today
        weekPage = ScheduleTab.monday(of: today)
    }

    private static var all: [String: TargetPlace] = [:]

    /// Where `target`'s schedule is: the one already open, or a fresh one.
    static func of(_ target: ScheduleTarget) -> TargetPlace {
        if let place = all[target.id], Date().timeIntervalSince(place.touched) < 600 {
            place.touched = Date()
            return place
        }
        let place = TargetPlace()
        all[target.id] = place
        return place
    }

    /// Signing out: nobody's schedule is kept.
    static func forgetAll() {
        all = [:]
    }
}
