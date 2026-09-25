import Foundation

struct Lesson: Identifiable, Codable, Hashable {
    /// Derived, not a fresh UUID: a UUID changes on every parse, so SwiftUI
    /// threw away and rebuilt every row on each refresh instead of updating it.
    var id: String { start + "|" + end + "|" + code + "|" + title + "|" + room }
    var start: String = ""
    var end: String = ""
    var code: String = ""
    var title: String = ""
    var teacher: String = ""
    var room: String = ""
    var homework: String = ""   // Lectio's "Lektier:" block
    var note: String = ""       // Lectio's "Note:" block
    var cancelled: Bool = false
    var changed: Bool = false
    var link: String? = nil

    var timeRange: String {
        if start.isEmpty && end.isEmpty { return "" }
        if end.isEmpty { return start }
        return start + " – " + end
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !code.isEmpty { return code.uppercased() }
        return isPrivateEvent ? "Event" : "Lesson"
    }

    /// Lectio renders your own private appointments as ordinary schedule tiles;
    /// the only thing that gives them away is that they link to
    /// privat_aftale.aspx rather than an activity page.
    var isPrivateEvent: Bool {
        return (link ?? "").lowercased().contains("privat_aftale.aspx")
    }

    var privateEventID: String? {
        guard let link = link, let g = Rx.match("aftaleid=(\\d+)", link) else { return nil }
        return g[1]
    }
}

enum LessonState {
    case past, current, upcoming
}

extension Lesson {
    /// Where this lesson sits relative to now, used to dim past lessons and
    /// highlight the one happening right now.
    func state(onDay dayISO: String, now: Date = Date()) -> LessonState {
        let todayISO = LectioDates.isoString(from: now)
        if dayISO < todayISO { return .past }
        if dayISO > todayISO { return .upcoming }

        let comps = Lesson.sharedCalendar.dateComponents([.hour, .minute], from: now)
        let minutesNow = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let startMinutes = Lesson.minutes(from: start)
        let endMinutes = Lesson.minutes(from: end)
        if let e = endMinutes, minutesNow > e { return .past }
        if let st = startMinutes, let e = endMinutes, minutesNow >= st, minutesNow <= e { return .current }
        return .upcoming
    }

    static let sharedCalendar = Calendar.current

    static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

struct ScheduleWeek: Identifiable, Codable, Hashable {
    var id: String { code }
    var code: String = ""        // Lectio's week param, e.g. "392026"
    var label: String = ""       // "Week 39"
    var dateRange: String = ""   // "21/9-27/9"
    var days: [ScheduleDay] = []
}

struct ScheduleDay: Identifiable, Codable, Hashable {
    var id: String { date }
    var date: String = ""      // ISO yyyy-MM-dd
    var label: String = ""     // "Mon 21 Sep"
    var lessons: [Lesson] = []
}

struct HomeworkItem: Identifiable, Codable, Hashable {
    var id: String { code + "|" + title + "|" + (due ?? "") }
    var code: String = ""
    var title: String = ""
    var due: String? = nil     // ISO yyyy-MM-dd
    var time: String = ""
    /// The homework as Lectio writes it, not the truncated dashboard version.
    var text: String = ""
    /// The lesson this homework belongs to, so the full page can be opened.
    var link: String? = nil
}

struct AssignmentItem: Identifiable, Codable, Hashable {
    var id: String { code + "|" + title + "|" + (due ?? "") }
    var code: String = ""
    var title: String = ""
    var due: String? = nil     // ISO yyyy-MM-dd
    var dueTime: String = ""
    var status: String = ""
    var link: String? = nil

    var isPending: Bool {
        return status.lowercased().contains("pending") || status.lowercased().contains("venter")
    }

    /// Lectio's own verdict on whether this has been handed in.
    var isDelivered: Bool {
        let lower = status.lowercased()
        if lower.contains("ikke") { return false }     // "Ikke afleveret"
        return lower.contains("afleveret") || lower == "done"
    }
}

struct MessagePreview: Identifiable, Codable, Hashable {
    var id: String { (link ?? "") + "|" + subject + "|" + date }
    var subject: String = ""
    var sender: String = ""
    var date: String = ""
    var link: String? = nil
}

/// Homework and assignments merged into one thing the Homework tab can group,
/// sort and tick off. `key` is stable across refreshes (unlike a fresh UUID),
/// so completion survives reloads.
struct Profile: Codable, Hashable {
    var name: String = ""
    var className: String = ""
}

/// Lessons that share a time slot, so the schedule can place them side by side
/// instead of stacking them as if they were sequential.
struct LessonCluster: Identifiable {
    var id: String
    var lessons: [Lesson]

    static func build(_ lessons: [Lesson]) -> [LessonCluster] {
        let sorted = lessons.sorted { $0.start < $1.start }
        var buckets: [[Lesson]] = []

        for lesson in sorted {
            let start = Lesson.minutes(from: lesson.start)
            let end = Lesson.minutes(from: lesson.end)
            var placed = false

            // A long block (a whole-morning event, say) overlaps everything, so
            // it would drag every lesson into one unreadable row of slivers.
            let duration = (start != nil && end != nil) ? end! - start! : 0
            let isLongEvent = duration > 240

            if !isLongEvent, let s = start, let e = end, var last = buckets.last,
               last.count < 2 {
                // Require overlap with EVERY member, not just one — otherwise
                // A/B and B/C chain together into a single giant cluster.
                let overlapsAll = last.allSatisfy { other in
                    guard let os = Lesson.minutes(from: other.start),
                          let oe = Lesson.minutes(from: other.end) else { return false }
                    let otherLong = (oe - os) > 240
                    return !otherLong && s < oe && os < e
                }
                if overlapsAll {
                    last.append(lesson)
                    buckets[buckets.count - 1] = last
                    placed = true
                }
            }
            if !placed { buckets.append([lesson]) }
        }

        return buckets.enumerated().map { index, group in
            LessonCluster(id: "\(index)-\(group.first?.id ?? "")", lessons: group)
        }
    }
}

struct WorkItem: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var code: String
    var title: String
    var due: String?
    var dueTime: String
    var isAssignment: Bool
    var link: String?
    /// Handed in according to Lectio, as opposed to ticked off by hand here.
    var isDelivered: Bool = false
    /// Homework's own text. Assignments carry theirs on their hand-in page.
    var text: String = ""

    static func key(code: String, title: String, due: String?) -> String {
        return code + "|" + title + "|" + (due ?? "")
    }
}

struct LectioSnapshot: Codable {
    var weekLabel: String = ""
    var currentWeekCode: String = ""
    var weeks: [String: ScheduleWeek] = [:]
    var schedule: [ScheduleDay] = []   // convenience: the current week's days
    var homework: [HomeworkItem] = []
    var assignments: [AssignmentItem] = []
    var messages: [MessagePreview] = []
    var unreadMessages: Int = 0
    var fetchedAt: Date? = nil
    var completedKeys: Set<String> = []
    var profile = Profile()

    var isEmpty: Bool {
        return schedule.isEmpty && homework.isEmpty && assignments.isEmpty && messages.isEmpty
    }

    /// Today's lessons, if today appears in the scraped week.
    func today(reference: Date = Date()) -> ScheduleDay? {
        let iso = LectioDates.isoString(from: reference)
        for day in schedule where day.date == iso {
            return day
        }
        return nil
    }

    /// The next school day at or after today that still has lessons.
    func nextDay(reference: Date = Date()) -> ScheduleDay? {
        let iso = LectioDates.isoString(from: reference)
        let upcoming = schedule.filter { $0.date >= iso && !$0.lessons.isEmpty }
        return upcoming.sorted { $0.date < $1.date }.first
    }

    /// Everything due, from both sources, de-duplicated by key.
    var workItems: [WorkItem] {
        var out: [WorkItem] = []
        var seen: Set<String> = []
        for h in homework {
            let k = WorkItem.key(code: h.code, title: h.title, due: h.due)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(WorkItem(key: k, code: h.code, title: h.title,
                                due: h.due, dueTime: h.time, isAssignment: false,
                                link: h.link, text: h.text))
        }
        // Every assignment, including handed-in ones. Filtering those out here
        // made an assignment vanish from the app the moment you handed it in,
        // instead of moving down to Completed.
        for a in assignments {
            let k = WorkItem.key(code: a.code, title: a.title, due: a.due)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(WorkItem(key: k, code: a.code, title: a.title,
                                due: a.due, dueTime: a.dueTime, isAssignment: true,
                                link: a.link, isDelivered: a.isDelivered))
        }
        return out
    }

    /// Done means either you ticked it off, or Lectio says it's handed in.
    func isCompleted(_ item: WorkItem) -> Bool {
        return item.isDelivered || completedKeys.contains(item.key)
    }

    var outstandingCount: Int {
        return workItems.filter { !isCompleted($0) }.count
    }

    var pendingAssignments: [AssignmentItem] {
        return assignments.filter { !$0.status.lowercased().contains("afleveret") && !$0.status.lowercased().contains("done") }
    }
}
