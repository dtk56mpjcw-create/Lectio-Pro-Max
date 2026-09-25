import Foundation

/// Regex convenience that avoids NSRange <-> String.Index juggling everywhere.
enum Rx {
    /// NSRegularExpression compilation is expensive and the parser runs the same
    /// handful of patterns hundreds of times per page, so compile each once.
    private static let cacheLock = NSLock()
    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        cache[pattern] = made
        return made
    }

    /// Returns capture groups (index 0 = whole match) or nil when there's no match.
    static func match(_ pattern: String, _ input: String) -> [String]? {
        guard let re = regex(pattern) else { return nil }
        let ns = input as NSString
        guard let m = re.firstMatch(in: input, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        groups.reserveCapacity(m.numberOfRanges)
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    static func test(_ pattern: String, _ input: String) -> Bool {
        guard let re = regex(pattern) else { return false }
        let ns = input as NSString
        return re.firstMatch(in: input, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }
}

enum LectioDates {
    // MARK: - Shared, built once

    private static let utcTimeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utcTimeZone
        return cal
    }()

    private static let isoWeekCalendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        return cal
    }()

    private static func formatter(_ format: String, utc: Bool = true) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = posix
        if utc { fmt.timeZone = utcTimeZone }
        fmt.dateFormat = format
        return fmt
    }

    private static let isoFormatter = formatter("yyyy-MM-dd", utc: false)
    private static let isoUTCFormatter = formatter("yyyy-MM-dd")
    private static let dayLabelFormatter = formatter("EEE d MMM")
    private static let longLabelFormatter = formatter("EEEE d MMMM")
    private static let timeFormatter = formatter("HH:mm", utc: false)

    /// Labels are re-derived for every visible row on every frame of a drag;
    /// memoising them keeps that free.
    ///
    /// These are touched from several threads at once — a week fetch parses on a
    /// background executor while the UI formats labels on the main one — and an
    /// unsynchronised Dictionary write from two threads corrupts it, which
    /// showed up as the schedule wedging mid-load. Hence the lock.
    private static let cacheLock = NSLock()
    private static var labelCache: [String: String] = [:]
    private static var longLabelCache: [String: String] = [:]
    private static var dateCache: [String: Date] = [:]

    private static func cachedLabel(_ iso: String, long: Bool) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return long ? longLabelCache[iso] : labelCache[iso]
    }

    private static func storeLabel(_ value: String, _ iso: String, long: Bool) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if long {
            if longLabelCache.count > 400 { longLabelCache.removeAll(keepingCapacity: true) }
            longLabelCache[iso] = value
        } else {
            if labelCache.count > 400 { labelCache.removeAll(keepingCapacity: true) }
            labelCache[iso] = value
        }
    }


    /// Lectio writes dates Danish-style: "25/9-2026 09:00:00" or "21/9-2026 08:00".
    /// Returns ISO date ("2026-09-25") plus "HH:mm" when a time was present.
    static func parseDanish(_ raw: String) -> (date: String, time: String)? {
        guard let g = Rx.match("(\\d{1,2})/(\\d{1,2})-(\\d{4})(?:\\s+(\\d{1,2}):(\\d{2}))?", raw) else {
            return nil
        }
        guard let day = Int(g[1]), let month = Int(g[2]), let year = Int(g[3]) else { return nil }
        let iso = String(format: "%04d-%02d-%02d", year, month, day)
        var time = ""
        if g.count > 5, !g[4].isEmpty, let h = Int(g[4]) {
            time = String(format: "%02d:%@", h, g[5])
        }
        return (iso, time)
    }

    /// "2026-09-24" -> "24/9-2026", which is how Lectio writes and expects dates
    /// (its datepicker format is literally d/m-yy with a four-digit year).
    static func danishDate(iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return iso
        }
        // Lectio writes these back as "24/09-2026", so match it exactly.
        return String(format: "%02d/%02d-%04d", d, m, y)
    }

    /// "2026-09-21" -> "Mon 21 Sep"
    static func dayLabel(iso: String) -> String {
        if let hit = cachedLabel(iso, long: false) { return hit }
        guard let date = date(fromISO: iso) else { return iso }
        let label = dayLabelFormatter.string(from: date)
        storeLabel(label, iso, long: false)
        return label
    }

    /// 1 = Sunday ... 7 = Saturday
    /// Lectio writes a forløb's period as "to 13/8-26 - to 20/8-26" — Danish
    /// weekday abbreviations and a d/m-yy date. This is the English reading of
    /// it: "Thu 13 Aug – Thu 20 Aug".
    static func englishPeriod(_ danish: String) -> String {
        let pattern = "([a-zæøå]{2})\\s+([0-9]{1,2})/([0-9]{1,2})-([0-9]{2,4})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return danish }

        let ns = danish as NSString
        let matches = regex.matches(in: danish, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return danish }

        var parts: [String] = []
        for match in matches where match.numberOfRanges >= 5 {
            let day = ns.substring(with: match.range(at: 1)).lowercased()
            let date = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let month = Int(ns.substring(with: match.range(at: 3))) ?? 0
            let name = weekdayNames[day] ?? day.capitalized
            parts.append("\(name) \(date) \(monthName(month))")
        }
        return parts.joined(separator: " – ")
    }

    private static let weekdayNames: [String: String] = [
        "ma": "Mon", "ti": "Tue", "on": "Wed", "to": "Thu",
        "fr": "Fri", "lø": "Sat", "lo": "Sat", "sø": "Sun", "so": "Sun",
    ]

    private static func monthName(_ month: Int) -> String {
        let names = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month < names.count else { return "" }
        return names[month]
    }

    static func weekday(iso: String) -> Int? {
        guard let date = date(fromISO: iso) else { return nil }
        return utcCalendar.component(.weekday, from: date)
    }

    static func isWeekday(iso: String) -> Bool {
        guard let wd = weekday(iso: iso) else { return false }
        return wd >= 2 && wd <= 6   // Mon...Fri
    }

    static func date(fromISO iso: String) -> Date? {
        cacheLock.lock()
        let hit = dateCache[iso]
        cacheLock.unlock()
        if let hit = hit { return hit }
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard let date = utcCalendar.date(from: comps) else { return nil }
        cacheLock.lock()
        if dateCache.count > 400 { dateCache.removeAll(keepingCapacity: true) }
        dateCache[iso] = date
        cacheLock.unlock()
        return date
    }



    /// Lectio addresses weeks as week+year, e.g. "392026" for week 39 of 2026.
    static func weekCode(for date: Date) -> String {
        let cal = isoWeekCalendar
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%02d%04d", week, year)
    }

    /// A run of consecutive week codes centred on `date`, for the swipe pager.
    static func weekCodes(around date: Date, back: Int, forward: Int) -> [String] {
        let cal = isoWeekCalendar
        var codes: [String] = []
        var offset = -back
        while offset <= forward {
            if let d = cal.date(byAdding: .weekOfYear, value: offset, to: date) {
                codes.append(weekCode(for: d))
            }
            offset += 1
        }
        return codes
    }

    /// "392026" -> "Week 39"
    static func weekLabel(code: String) -> String {
        if code.count >= 2, let w = Int(code.prefix(2)) { return "Week \(w)" }
        return code
    }

    /// Move an ISO date by whole days.
    static func shift(iso: String, byDays delta: Int) -> String {
        guard let date = date(fromISO: iso),
              let moved = utcCalendar.date(byAdding: .day, value: delta, to: date) else { return iso }
        return isoUTCFormatter.string(from: moved)
    }

    /// Week code for an ISO date string.
    static func weekCode(iso: String) -> String {
        guard let d = date(fromISO: iso) else { return "" }
        return weekCode(for: d)
    }

    /// "Mon 21 September"
    static func longLabel(iso: String) -> String {
        if let hit = cachedLabel(iso, long: true) { return hit }
        guard let date = date(fromISO: iso) else { return iso }
        let label = longLabelFormatter.string(from: date)
        storeLabel(label, iso, long: true)
        return label
    }

    /// Today in the user's own timezone, as "yyyy-MM-dd".
    static func isoString(from date: Date) -> String {
        return isoFormatter.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }

    /// Lectio's raw strings carry list dashes, hard line breaks and its own
    /// "[...]" truncation marker. Tidy them up for display.
    static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "[...]", with: "…")
        text = text.replacingOccurrences(of: "\r", with: "")
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
            else if t == "-" { continue }
            if !t.isEmpty { lines.append(t) }
        }
        return lines.joined(separator: "\n")
    }

    /// "2026-09-25" -> "Fri 25 Sep", or "Today"/"Tomorrow" when close.
    static func friendlyLabel(iso: String, reference: Date = Date()) -> String {
        let todayISO = isoString(from: reference)
        if iso == todayISO { return "Today" }
        if iso == shift(iso: todayISO, byDays: 1) { return "Tomorrow" }
        if iso == shift(iso: todayISO, byDays: -1) { return "Yesterday" }
        return dayLabel(iso: iso)
    }
}
