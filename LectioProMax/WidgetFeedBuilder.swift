import Foundation
import WidgetKit

/// Turns the saved schedule into the widgets' feed (see WidgetFeed), and
/// keeps what hangs off it in step: the widgets, and the reminders before
/// each lesson.
@MainActor
enum WidgetFeedBuilder {

    /// A school week and a weekend: enough for Friday afternoon to show
    /// Monday, and for a Monday off.
    static let horizon = 9

    /// The last feed handed out, so an unchanged one isn't written, the
    /// widgets aren't reloaded and the reminders aren't rebuilt for nothing.
    private(set) static var latest: WidgetFeed?

    /// Hands the feed to the widgets and the lesson reminders, when it's
    /// changed.
    static func publish(_ snapshot: LectioSnapshot, now: Date = Date()) {
        let feed = build(from: snapshot, now: now)
        if let latest, latest.signedIn, latest.days == feed.days { return }
        latest = feed
        feed.save()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await NotificationService.rescheduleLessons(from: feed) }
    }

    /// Signed out: the widgets say so, rather than keep showing the last
    /// account's lessons.
    static func signedOut() {
        let feed = WidgetFeed(signedIn: false)
        latest = feed
        feed.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The days from today on that the app has a week for. Days with
    /// nothing in them are left out; a week the app hasn't loaded is never
    /// taken to be empty.
    static func build(from snapshot: LectioSnapshot, now: Date = Date()) -> WidgetFeed {
        var feed = WidgetFeed()
        let className = snapshot.profile.className
        ClassNames.use(className)
        let today = LectioDates.isoString(from: now)

        var modulesByWeek: [String: [ScheduleModule]] = [:]
        var rollingByWeek: [String: Set<String>] = [:]
        for offset in 0..<horizon {
            let iso = LectioDates.shift(iso: today, byDays: offset)
            let code = LectioDates.weekCode(iso: iso)
            guard let week = snapshot.weeks[code] else { continue }
            let modules = modulesByWeek[code] ?? week.dayModules
            modulesByWeek[code] = modules
            let rolling = rollingByWeek[code] ?? week.rollingNotes(className: className)
            rollingByWeek[code] = rolling

            let plan = WeekAgenda.plan(for: iso, in: week, modules: modules,
                                       className: className, rolling: rolling)
            var day = Self.day(iso, plan: plan)
            let due = work(due: iso, in: snapshot)
            day.work = due.isEmpty ? nil : due
            if !day.items.isEmpty || day.note != nil { feed.days.append(day) }
        }
        return feed
    }

    // MARK: - One day

    private static func day(_ iso: String, plan: DayPlan) -> WidgetFeed.Day {
        var items: [WidgetFeed.Item] = []
        func add(_ lesson: Lesson, slot: DayPlan.Slot?, cancelled: Bool = false, optional: Bool = false) {
            guard let item = item(lesson, on: iso, slot: slot, cancelled: cancelled, optional: optional) else { return }
            items.append(item)
        }

        for lesson in plan.before { add(lesson, slot: nil) }
        for slot in plan.slots {
            for lesson in slot.main { add(lesson, slot: slot) }
            for lesson in slot.cancelled { add(lesson, slot: slot, cancelled: true) }
            for lesson in slot.breakAfter { add(lesson, slot: nil) }
        }
        for lesson in plan.after { add(lesson, slot: nil, optional: true) }

        // In time order, each thing once (a block can list a lesson that
        // also sits in the break after it).
        var seen: Set<String> = []
        items = items
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            .filter { seen.insert($0.title + "|" + "\($0.start.timeIntervalSince1970)").inserted }

        return WidgetFeed.Day(date: iso,
                              note: plan.status.first.map(dayStatusTitle),
                              items: items)
    }

    private static func item(_ lesson: Lesson, on iso: String, slot: DayPlan.Slot?,
                             cancelled: Bool, optional: Bool) -> WidgetFeed.Item? {
        // Its own hours when it has them, otherwise its block's.
        let startTime = !lesson.start.isEmpty ? lesson.start : slot.map { hhmm($0.startMinutes) } ?? ""
        let endTime = !lesson.end.isEmpty ? lesson.end : slot.map { hhmm($0.endMinutes) } ?? ""
        guard let start = LectioDates.moment(iso: iso, time: startTime) else { return nil }
        let end = LectioDates.moment(iso: iso, time: endTime).flatMap { $0 > start ? $0 : nil }
            ?? start.addingTimeInterval(45 * 60)

        let mark = lesson.markKind
        let isLesson = lesson.isClassLesson && mark == nil
        var item = WidgetFeed.Item(title: isLesson ? lesson.headline : dayStatusTitle(lesson),
                                   start: start, end: end)
        if isLesson, let topic = lesson.topic {
            item.topic = LectioDates.tidy(topic).components(separatedBy: "\n").first ?? ""
        }
        item.room = LessonText.abbreviated(lesson.room)
        item.teacher = LessonText.abbreviated(lesson.teacher)
        item.colour = colourName(lesson, mark: mark)
        item.tag = mark?.label
        item.cancelled = cancelled || lesson.cancelled
        item.changed = lesson.changed
        item.optional = optional
        item.key = ScheduleWatch.lessonKey(lesson)
        return item
    }

    /// Homework and assignments due on a day and not done yet, the way the
    /// Homework tab lists them: assignments first.
    private static func work(due iso: String, in snapshot: LectioSnapshot) -> [WidgetFeed.Work] {
        snapshot.workItems
            .filter { $0.due == iso && !snapshot.isCompleted($0) }
            .sorted { $0.isAssignment && !$1.isAssignment }
            .map { item in
                let key = SubjectPalette.subjectKey(item.code)
                let own = LectioDates.tidy(item.text).components(separatedBy: "\n").first ?? ""
                let title = LectioDates.tidy(item.title).components(separatedBy: "\n").first ?? item.title
                var text = item.isAssignment || own.isEmpty ? title : own
                if item.isAssignment && !item.dueTime.isEmpty { text += " · " + item.dueTime }
                return WidgetFeed.Work(subject: key.map(SubjectNames.name(forKey:)) ?? item.code.uppercased(),
                                       text: text,
                                       colour: key.map { SubjectPalette.choice(forKey: $0).rawValue } ?? "gray",
                                       isAssignment: item.isAssignment)
            }
    }

    /// The colour the Schedule tab paints it, by name.
    static func colourName(_ lesson: Lesson, mark: Lesson.Kind?) -> String {
        switch mark {
        case .exam?: return "red"
        case .noSchool?: return "green"
        case .trip?: return "blue"
        case .readingDay?: return "indigo"
        default: break
        }
        guard lesson.isClassLesson, let key = SubjectPalette.subjectKey(lesson.code) else { return "gray" }
        return SubjectPalette.choice(forKey: key).rawValue
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

extension LectioDates {
    /// A Danish wall-clock moment: "2026-09-29" at "10:05". Built from the
    /// date and the clock, not by adding minutes to midnight, so a day the
    /// clocks change on still puts 10:05 at 10:05.
    static func moment(iso: String, time: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let minutes = Lesson.minutes(from: time) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: minutes / 60, minute: minutes % 60))
    }
}
