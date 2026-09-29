import Foundation
import Testing
@testable import LectioProMax

/// Which search the search button opens (see SearchContexts): the tab
/// you're on's, except where the screen on show has its own — Me › Find a
/// schedule and someone's schedule search for a schedule. Screens appear and
/// disappear in either order, and leaving a tab takes them all off, so each
/// case is played out in both orders.
@MainActor
struct SearchContextTests {
    let meRoot = UUID()
    let find = UUID()
    let theirs = UUID()

    @Test func eachTabSearchesItselfByDefault() {
        let contexts = SearchContexts()
        #expect(contexts.context(for: .schedule) == .schedule)
        #expect(contexts.context(for: .homework) == .homework)
        #expect(contexts.context(for: .messages) == .messages)
        #expect(contexts.context(for: .me) == .me)
    }

    @Test func findAScheduleHasItsOwnSearch() {
        for newFirst in [true, false] {
            let contexts = SearchContexts()
            contexts.appeared(meRoot, context: .me, in: .me)
            #expect(contexts.context(for: .me) == .me)

            // Me › Find a schedule.
            replace(meRoot, with: find, as: .findSchedule, newFirst: newFirst, contexts)
            #expect(contexts.context(for: .me) == .findSchedule)

            // Then someone's schedule, and a lesson in it (says nothing).
            replace(find, with: theirs, as: .findSchedule, newFirst: newFirst, contexts)
            contexts.disappeared(theirs, in: .me)
            #expect(contexts.context(for: .me) == .findSchedule)
        }
    }

    @Test func pressingSearchTakesTheScreenOff() {
        // Switching to the search tab makes the screen on show disappear,
        // perhaps before the search is picked: it's still where you were.
        let contexts = SearchContexts()
        contexts.appeared(meRoot, context: .me, in: .me)
        replace(meRoot, with: find, as: .findSchedule, newFirst: true, contexts)
        contexts.disappeared(find, in: .me)
        #expect(contexts.context(for: .me) == .findSchedule)

        // Back in Me, and back to its first page.
        contexts.appeared(find, context: .findSchedule, in: .me)
        replace(find, with: meRoot, as: .me, newFirst: false, contexts)
        #expect(contexts.context(for: .me) == .me)
        contexts.disappeared(meRoot, in: .me)
        #expect(contexts.context(for: .me) == .me)
    }

    @Test func aSwipeBackLetGoStaysPut() {
        // The page under shows during the swipe, then goes again.
        let contexts = SearchContexts()
        contexts.appeared(meRoot, context: .me, in: .me)
        replace(meRoot, with: find, as: .findSchedule, newFirst: true, contexts)
        contexts.appeared(meRoot, context: .me, in: .me)
        contexts.disappeared(meRoot, in: .me)
        #expect(contexts.context(for: .me) == .findSchedule)
    }

    @Test func tabsDontMix() {
        let contexts = SearchContexts()
        contexts.appeared(find, context: .findSchedule, in: .me)
        #expect(contexts.context(for: .messages) == .messages)
        #expect(contexts.context(for: .schedule) == .schedule)
    }

    /// `new` takes `old`'s place on screen (a push or a pop), appearing
    /// before or after `old` disappears.
    private func replace(_ old: UUID, with new: UUID, as context: SearchKind, newFirst: Bool,
                         _ contexts: SearchContexts) {
        if newFirst {
            contexts.appeared(new, context: context, in: .me)
            contexts.disappeared(old, in: .me)
        } else {
            contexts.disappeared(old, in: .me)
            contexts.appeared(new, context: context, in: .me)
        }
    }
}
