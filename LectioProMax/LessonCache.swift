import Foundation

/// Lesson pages and their Elevfeedback, fetched ahead of time.
///
/// Opening a lesson used to start two requests (the lesson's page, then its
/// Elevfeedback tab) and draw them as they came — a visible beat every time.
/// Now, when a day settles on screen, its lessons are loaded quietly in the
/// background, two at a time; opening one then shows it at once, and a copy
/// older than a few minutes is shown straight away while a fresh one loads.
@MainActor
final class LessonCache {
    static let shared = LessonCache()

    private struct Entry<Value> {
        var value: Value
        var at: Date
    }

    private var details: [String: Entry<LessonDetail>] = [:]
    private var feedbacks: [String: Entry<LessonFeedback>] = [:]
    /// One load per lesson at a time; a second asker waits for the first.
    private var loading: [String: Task<Void, Never>] = [:]
    private var prefetching: Task<Void, Never>?

    /// How long a copy counts as current.
    private static let fresh: TimeInterval = 300

    private init() {}

    /// Everything, for signing out: a lesson's feedback is someone's own.
    func clear() {
        prefetching?.cancel()
        prefetching = nil
        loading.values.forEach { $0.cancel() }
        loading.removeAll()
        details.removeAll()
        feedbacks.removeAll()
    }

    // MARK: Reading

    func detail(_ link: String) -> LessonDetail? { details[link]?.value }
    func feedback(_ link: String) -> LessonFeedback? { feedbacks[link]?.value }

    func isDetailFresh(_ link: String) -> Bool {
        details[link].map { Date().timeIntervalSince($0.at) < Self.fresh } ?? false
    }

    func isFeedbackFresh(_ link: String) -> Bool {
        feedbacks[link].map { Date().timeIntervalSince($0.at) < Self.fresh } ?? false
    }

    func store(feedback: LessonFeedback, for link: String) {
        feedbacks[link] = Entry(value: feedback, at: Date())
    }

    // MARK: Loading

    /// Loads what isn't current for one lesson. If it's already loading
    /// (say, a prefetch), waits for that instead of asking twice.
    func load(_ link: String, detail wantDetail: Bool, feedback wantFeedback: Bool,
              cookies: [HTTPCookie]) async {
        if let running = loading[link] {
            await running.value
            // The prefetch may not have asked for feedback; fall through if so.
            if (!wantDetail || isDetailFresh(link)) && (!wantFeedback || isFeedbackFresh(link)) { return }
        }
        let needDetail = wantDetail && !isDetailFresh(link)
        let needFeedback = wantFeedback && !isFeedbackFresh(link)
        guard needDetail || needFeedback else { return }

        let task = Task { @MainActor in
            async let page = Self.fetchDetail(link, needDetail, cookies)
            async let tab = Self.fetchFeedback(link, needFeedback, cookies)
            if let detail = await page { self.details[link] = Entry(value: detail, at: Date()) }
            if let feedback = await tab { self.feedbacks[link] = Entry(value: feedback, at: Date()) }
        }
        loading[link] = task
        await task.value
        loading[link] = nil
    }

    /// Days' lessons in the order given — the day on screen, then the next —
    /// soonest first within a day, two at a time. A new call replaces the
    /// last one's queue, so flicking through a week doesn't pile up requests.
    func prefetch(_ days: [(dayISO: String, lessons: [Lesson])], cookies: [HTTPCookie]) {
        prefetching?.cancel()
        let wanted = days.flatMap { Self.queue($0.lessons, dayISO: $0.dayISO) }
        guard !wanted.isEmpty else { return }

        prefetching = Task { @MainActor in
            var index = 0
            while index < wanted.count, !Task.isCancelled {
                let batch = wanted[index..<min(index + 2, wanted.count)]
                await withTaskGroup(of: Void.self) { group in
                    for (link, feedback) in batch {
                        group.addTask { @MainActor in
                            await self.load(link, detail: true, feedback: feedback, cookies: cookies)
                        }
                    }
                }
                index += 2
            }
        }
    }

    /// One day's lessons worth fetching, what's still to come today first.
    private static func queue(_ lessons: [Lesson], dayISO: String) -> [(String, Bool)] {
        let now = Lesson.minutes(from: LectioDates.timeString(Date())) ?? 0
        let isToday = dayISO == LectioDates.isoString(from: Date())
        return lessons
            .filter { !$0.isAllDay && !$0.cancelled && !$0.isPrivateEvent && $0.link != nil }
            .sorted { a, b in
                // Today: what's still to come before what's over.
                let aLater = !isToday || (a.endMinutes ?? 0) >= now
                let bLater = !isToday || (b.endMinutes ?? 0) >= now
                if aLater != bLater { return aLater }
                return (a.startMinutes ?? 0) < (b.startMinutes ?? 0)
            }
            .compactMap { lesson -> (String, Bool)? in
                guard let link = lesson.link else { return nil }
                // Only a real lesson has an Elevfeedback tab.
                return (link, lesson.isClassLesson)
            }
    }

    private nonisolated static func fetchDetail(_ link: String, _ needed: Bool,
                                                _ cookies: [HTTPCookie]) async -> LessonDetail? {
        guard needed else { return nil }
        return try? await LectioStudyService.loadLessonDetail(link: link, cookies: cookies)
    }

    private nonisolated static func fetchFeedback(_ link: String, _ needed: Bool,
                                                  _ cookies: [HTTPCookie]) async -> LessonFeedback? {
        guard needed else { return nil }
        return try? await LectioFeedbackService.load(lessonLink: link, cookies: cookies)
    }
}
