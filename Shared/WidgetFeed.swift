import Foundation

/// What the widgets show: the coming week of your schedule, worked out by
/// the app with the same rules as the Schedule tab and handed over as one
/// small file in the app group. The widgets never talk to Lectio and never
/// see your sign-in; they only read this.
///
/// Compiled into both the app and the widget extension (the Shared folder).
struct WidgetFeed: Codable, Equatable {

    /// Shared by the app and its widgets (Signing & Capabilities → App Groups).
    /// Which group it is depends on the Apple ID the app is signed with
    /// (APP_GROUP_ID in the build settings, passed on through each Info.plist
    /// as LectioAppGroup), so it's read from the bundle, not written here.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "LectioAppGroup") as? String
        ?? "group.com.ivan.lectiopromax"
    private static let fileName = "widget-feed.json"

    struct Item: Codable, Equatable, Hashable {
        /// "Maths", "AP exam", "Intro trip".
        var title: String
        /// The lesson's topic, when it has one.
        var topic: String = ""
        var room: String = ""
        var teacher: String = ""
        var start: Date
        var end: Date
        /// One of Apple's system colours by name ("blue"), so the widget
        /// paints a subject exactly as the app does.
        var colour: String = "gray"
        /// "Exam", "Trip", "Reading day": set when it isn't a lesson.
        var tag: String? = nil
        var cancelled: Bool = false
        var changed: Bool = false
        /// After the school day (a study café): shown, never counted down to.
        var optional: Bool = false
        /// Lectio's id for it, so a tap opens this very lesson (see AppLink).
        /// Optional so a feed written before it existed still reads.
        var key: String? = nil
        /// A day of something longer, as the Schedule tab shows it: "all"
        /// (the whole day), "starts" (runs on past today), "ends" (came
        /// from yesterday). Nil for an ordinary lesson.
        var shape: String? = nil

        /// "9:50–11:25", or "from 8:00", "until 16:00", "All day".
        var hours: String {
            switch shape {
            case "all": return "All day"
            case "starts": return "from " + WidgetFeed.clock(start)
            case "ends": return "until " + WidgetFeed.clock(end)
            default: return WidgetFeed.clock(start) + "–" + WidgetFeed.clock(end)
            }
        }

        /// Whether it really begins at `start` today — not a day it goes
        /// on from yesterday, or a day-long note placed at the day's start.
        var beginsHere: Bool { shape == nil || shape == "starts" }

        /// Opens it in the app.
        var link: URL {
            AppLink.lesson(date: WidgetFeed.iso(start), start: WidgetFeed.clock(start), key: key)
        }
    }

    /// Homework or an assignment for the day, not yet done.
    struct Work: Codable, Equatable, Hashable {
        /// "Maths".
        var subject: String
        /// What to do: the homework itself, or the assignment's name.
        var text: String
        var colour: String = "gray"
        var isAssignment: Bool = false
    }

    struct Day: Codable, Equatable {
        /// yyyy-MM-dd, a Danish date.
        var date: String
        /// What the day is when it isn't an ordinary one ("Autumn break").
        var note: String? = nil
        var items: [Item] = []
        /// Due that day. Optional so a feed written before it existed reads.
        var work: [Work]? = nil
    }

    var signedIn = true
    var days: [Day] = []
    var updated = Date()

    /// Everything with a time, in order.
    var items: [Item] { days.flatMap(\.items) }

    // MARK: - Reading it

    /// Danish time, like Lectio's.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .current
        return cal
    }()

    /// "2026-09-29" for a moment, by the Danish date.
    static func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "8:00", Danish time.
    static func clock(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Midnight at the start of a Danish date.
    static func startOfDay(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// What's on right now. Cancelled and after-school things don't count.
    func current(at now: Date) -> Item? {
        items.first { !$0.cancelled && !$0.optional && $0.start <= now && now < $0.end }
    }

    /// The next thing to go to.
    func next(after now: Date) -> Item? {
        items.first { !$0.cancelled && !$0.optional && $0.start > now }
    }

    /// The day to show: today while anything of today's is still on or to
    /// come, otherwise the next day with something in it.
    func day(at now: Date) -> Day? {
        let today = Self.iso(now)
        if let day = days.first(where: { $0.date == today }),
           day.items.contains(where: { !$0.cancelled && !$0.optional && $0.end > now }) {
            return day
        }
        return days.first { $0.date > today && (!$0.items.isEmpty || $0.note != nil) }
    }

    /// When what a widget shows changes: every start and end, and each
    /// midnight, from `now` on.
    func moments(after now: Date, limit: Int = 60) -> [Date] {
        var all = Set<Date>()
        for item in items where !item.cancelled {
            if item.start > now { all.insert(item.start) }
            if item.end > now { all.insert(item.end) }
        }
        for day in days {
            if let midnight = Self.startOfDay(day.date), midnight > now { all.insert(midnight) }
        }
        return Array(all.sorted().prefix(limit))
    }

    // MARK: - The file

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> WidgetFeed? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetFeed.self, from: data)
    }

    /// Readable once the phone has been unlocked after a restart — the Lock
    /// Screen widget has to read it while the phone is locked — and left
    /// out of backups. Does nothing until the app group is set up.
    func save() {
        guard var url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
