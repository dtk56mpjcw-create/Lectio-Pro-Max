import Foundation

/// Something new to tell you about while the app is closed.
struct ChangeAlert: Equatable {
    enum Topic: String {
        case schedule, messages, work
    }
    var topic: Topic
    /// Stable, so the same news posted twice replaces itself.
    var id: String
    var title: String
    var subtitle: String = ""
    var body: String
}

/// Notices what's new since you last looked: a lesson cancelled, moved,
/// in another room or with another teacher, today or on the next school
/// day; a new message; new homework or a new assignment.
///
/// It compares against a record of what you've already seen. The record
/// is brought up to date whenever the app is on screen (what it shows
/// counts as seen), and by each background check, so nothing is announced
/// twice. The first time it sees a day, the inbox or the homework list it
/// only takes note — a new install doesn't announce your whole week.
enum ScheduleWatch {

    struct Record: Codable, Equatable {
        /// How a lesson looked when last seen.
        struct Seen: Codable, Equatable {
            var title: String
            var start: String
            var end: String
            var room: String
            var teacher: String
            var cancelled: Bool
        }
        /// Day (yyyy-MM-dd) → lesson → how it looked.
        var days: [String: [String: Seen]] = [:]
        /// Nil until the inbox has been seen once.
        var messages: Set<String>? = nil
        /// Nil until the homework list has been seen once.
        var work: Set<String>? = nil
    }

    private static let storageKey = "watch.seen"

    static var record: Record {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
            return record
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }

    /// The app is on screen: whatever it shows counts as seen.
    static func absorb(_ snapshot: LectioSnapshot, now: Date = Date()) {
        let old = record
        let updated = review(snapshot, against: old, now: now).record
        if updated != old { record = updated }
    }

    /// For a background check: what's new, as the alerts your settings
    /// allow — several changes at once become one.
    static func check(_ snapshot: LectioSnapshot, now: Date = Date()) -> [ChangeAlert] {
        let result = review(snapshot, against: record, now: now)
        record = result.record
        let allowed = result.alerts.filter { NotifyPrefs.allows($0.topic) }
        return bundled(allowed, now: now)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Comparing

    /// Pure, for the tests: the alerts, and the record to keep.
    static func review(_ snapshot: LectioSnapshot, against old: Record,
                       now: Date) -> (alerts: [ChangeAlert], record: Record) {
        var alerts: [ChangeAlert] = []
        var record = Record(days: [:], messages: old.messages, work: old.work)
        let className = snapshot.profile.className
        ClassNames.use(className)

        // The schedule: today and the next school day.
        for iso in watchedDays(now: now) {
            guard let lessons = lessons(on: iso, in: snapshot, className: className) else {
                // That week isn't loaded: keep what we knew.
                if let kept = old.days[iso] { record.days[iso] = kept }
                continue
            }
            var seen: [String: Record.Seen] = [:]
            for (key, lesson) in lessons { seen[key] = look(lesson) }
            record.days[iso] = seen

            guard let before = old.days[iso] else { continue }   // first look at this day
            let inOrder = lessons.sorted {
                (Lesson.minutes(from: $0.value.start) ?? 0, $0.key) < (Lesson.minutes(from: $1.value.start) ?? 0, $1.key)
            }
            for (key, lesson) in inOrder {
                if let end = LectioDates.moment(iso: iso, time: lesson.end), end <= now { continue }
                if let alert = scheduleAlert(lesson, key: key, was: before[key], on: iso, now: now) {
                    alerts.append(alert)
                }
            }
        }

        // Messages. Your own replies aren't news.
        let me = snapshot.profile.name.trimmingCharacters(in: .whitespaces).lowercased()
        let messageKeys = snapshot.messages.map(messageKey)
        if let seen = old.messages {
            for message in snapshot.messages where !seen.contains(messageKey(message)) {
                if !me.isEmpty && message.sender.lowercased().hasPrefix(me) { continue }
                alerts.append(ChangeAlert(topic: .messages, id: "message." + messageKey(message),
                                          title: message.sender.isEmpty ? "New message" : message.sender,
                                          body: LectioDates.tidy(message.subject)))
            }
        }
        var messages = (old.messages ?? []).union(messageKeys)
        if messages.count > 400 { messages = Set(messageKeys) }
        record.messages = messages

        // Homework and assignments still to do.
        let today = LectioDates.isoString(from: now)
        let open = snapshot.workItems.filter { item in
            !snapshot.isCompleted(item) && (item.due ?? today) >= today
        }
        if let seen = old.work {
            for item in open where !seen.contains(item.key) {
                alerts.append(workAlert(item, now: now))
            }
        }
        // Kept until a day after they're due, so a list that comes back
        // short once (a page that didn't load) doesn't make everything new.
        let yesterday = LectioDates.shift(iso: today, byDays: -1)
        record.work = (old.work ?? []).union(open.map(\.key)).filter { key in
            let due = key.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return due.isEmpty || due >= yesterday
        }

        return (alerts, record)
    }

    /// Today, and the next weekday after it (Monday, from a Friday).
    static func watchedDays(now: Date) -> [String] {
        let today = LectioDates.isoString(from: now)
        var next = today
        for _ in 0..<7 {
            next = LectioDates.shift(iso: next, byDays: 1)
            if LectioDates.isWeekday(iso: next) { return [today, next] }
        }
        return [today]
    }

    /// Yours on a day, by a key that survives the lesson changing: Lectio's
    /// own id for it. Nil when that week isn't loaded.
    static func lessons(on iso: String, in snapshot: LectioSnapshot,
                        className: String) -> [String: Lesson]? {
        guard let week = snapshot.weeks[LectioDates.weekCode(iso: iso)] else { return nil }
        let day = week.days.first { $0.date == iso }
        var out: [String: Lesson] = [:]
        for lesson in day?.lessons ?? [] where !lesson.isAllDay && lesson.kind != .staffOnly {
            guard lesson.isClassLesson || lesson.isPrivateEvent || lesson.isFor(className: className) else { continue }
            let key = lessonKey(lesson)
            if out[key] == nil { out[key] = lesson }
        }
        return out
    }

    static func lessonKey(_ lesson: Lesson) -> String {
        if let link = lesson.link, let g = Rx.match("(?:absid|aftaleid)=(\\d+)", link) {
            return "id:" + g[1]
        }
        return "at:" + lesson.start + "|" + lesson.code + "|" + lesson.title
    }

    private static func messageKey(_ message: MessagePreview) -> String {
        if let link = message.link, let g = Rx.match("[?&]id=(\\d+)", link) { return g[1] }
        return message.id
    }

    private static func name(_ lesson: Lesson) -> String {
        lesson.isClassLesson && lesson.markKind == nil ? lesson.headline : dayStatusTitle(lesson)
    }

    private static func look(_ lesson: Lesson) -> Record.Seen {
        Record.Seen(title: name(lesson), start: lesson.start, end: lesson.end,
                    room: lesson.room, teacher: lesson.teacher, cancelled: lesson.cancelled)
    }

    // MARK: - Wording

    private static func times(_ start: String, _ end: String) -> String {
        func short(_ t: String) -> String { t.hasPrefix("0") ? String(t.dropFirst()) : t }
        return short(start) + (end.isEmpty ? "" : "–" + short(end))
    }

    private static func scheduleAlert(_ lesson: Lesson, key: String, was: Record.Seen?,
                                      on iso: String, now: Date) -> ChangeAlert? {
        let title = name(lesson)
        let day = LectioDates.friendlyLabel(iso: iso, reference: now)
        let when = day + ", " + times(lesson.start, lesson.end)
        let room = LessonText.abbreviated(lesson.room)
        let id = "schedule." + iso + "." + key

        guard let was else {
            // New on a day we'd already seen.
            guard !lesson.cancelled, !Lesson.isVoluntary(lesson.title) else { return nil }
            return ChangeAlert(topic: .schedule, id: id + ".added", title: "Added: " + title,
                               body: when + (room.isEmpty ? "" : " · " + room))
        }
        if lesson.cancelled && !was.cancelled {
            return ChangeAlert(topic: .schedule, id: id + ".cancelled", title: title + " cancelled", body: when)
        }
        if !lesson.cancelled && was.cancelled {
            return ChangeAlert(topic: .schedule, id: id + ".back", title: title + " is back on",
                               body: when + (room.isEmpty ? "" : " · " + room))
        }
        guard !lesson.cancelled else { return nil }
        if lesson.start != was.start || lesson.end != was.end {
            return ChangeAlert(topic: .schedule, id: id + ".moved." + lesson.start, title: title + " moved",
                               body: day + ", now " + times(lesson.start, lesson.end)
                                   + " (was " + times(was.start, was.end) + ")")
        }
        if lesson.room != was.room, !lesson.room.isEmpty {
            let before = LessonText.abbreviated(was.room)
            return ChangeAlert(topic: .schedule, id: id + ".room." + lesson.room, title: "Room change: " + title,
                               body: when + " · now " + room + (before.isEmpty ? "" : " (was " + before + ")"))
        }
        if lesson.teacher != was.teacher, !lesson.teacher.isEmpty, !was.teacher.isEmpty {
            return ChangeAlert(topic: .schedule, id: id + ".teacher." + lesson.teacher,
                               title: title + ": another teacher",
                               body: when + " · " + LessonText.abbreviated(lesson.teacher))
        }
        return nil
    }

    private static func workAlert(_ item: WorkItem, now: Date) -> ChangeAlert {
        let subject = SubjectPalette.subjectKey(item.code).map(SubjectNames.name(forKey:))
            ?? item.code.uppercased()
        var due = ""
        if let iso = item.due {
            due = LectioDates.friendlyLabel(iso: iso, reference: now)
            if item.isAssignment, !item.dueTime.isEmpty { due += " at " + item.dueTime }
        }
        let title = LectioDates.tidy(item.title).components(separatedBy: "\n").first ?? item.title
        return ChangeAlert(topic: .work, id: "work." + item.key,
                           title: item.isAssignment ? "New assignment" : "New homework",
                           subtitle: subject,
                           body: title + (due.isEmpty ? "" : (item.isAssignment ? " · due " : " · for ") + due))
    }

    /// More than three of a kind at once reads better as one.
    private static func bundled(_ alerts: [ChangeAlert], now: Date) -> [ChangeAlert] {
        var out: [ChangeAlert] = []
        for topic in [ChangeAlert.Topic.schedule, .messages, .work] {
            let some = alerts.filter { $0.topic == topic }
            guard some.count > 3 else { out += some; continue }
            let title: String
            switch topic {
            case .schedule: title = "\(some.count) schedule changes"
            case .messages: title = "\(some.count) new messages"
            case .work: title = "\(some.count) new homework and assignments"
            }
            let lines = some.prefix(4).map { alert -> String in
                switch topic {
                case .schedule: return alert.title
                case .messages: return alert.title + ": " + alert.body
                case .work: return alert.subtitle + ": " + alert.body
                }
            }
            let body = (lines + (some.count > 4 ? ["and \(some.count - 4) more"] : []))
                .joined(separator: "\n")
            out.append(ChangeAlert(topic: topic,
                                   id: topic.rawValue + ".bundle." + "\(Int(now.timeIntervalSince1970))",
                                   title: title, body: body))
        }
        return out
    }
}
