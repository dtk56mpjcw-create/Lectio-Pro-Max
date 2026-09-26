import Foundation

// MARK: - What an item on the schedule is

extension Lesson {
    /// A lesson for a class in a subject — "1j ma", "1ij daAB", "1j SP 2",
    /// or a shared one like "1i ap la, 1j ap la". Not an event for whole
    /// year groups ("Alle 1. STX-elever, …"), a club ("26/27, MUN
    /// LEADERSHIP"), or something optional ("Frivillig billedkunst").
    var isClassLesson: Bool {
        guard !isPrivateEvent, !isAllDay else { return false }
        if let team, !team.isEmpty {
            return Lesson.classTeamParts(team).first != nil
        }
        // Cached before `team` existed: fall back to a known subject code.
        guard !code.contains(","), let key = SubjectPalette.subjectKey(code) else { return false }
        return SubjectNames.knownName(forKey: key) != nil
    }

    /// The subject part of the first class team: "ma", "daAB", "SP 2", "ap la".
    var subjectPart: String? {
        if let team, let first = Lesson.classTeamParts(team).first { return first }
        return isClassLesson ? code : nil
    }

    /// "Maths" — only for a class lesson in a subject the app knows. The old
    /// guess from any code's first letters made MUN into "Music".
    var subjectName: String? {
        guard isClassLesson, let part = subjectPart,
              let key = SubjectPalette.subjectKey(part) else { return nil }
        return SubjectNames.knownName(forKey: key)
    }

    /// The big line: the subject, or the event's own title.
    var headline: String {
        if let subjectName { return subjectName }
        if isClassLesson, let part = subjectPart { return part.uppercased() }
        let cleaned = Lesson.withoutAudience(title)
        return cleaned.isEmpty ? displayTitle : cleaned
    }

    /// Under it: the lesson's topic ("Start radicals"). Events get nothing —
    /// "1. STX-elever +2" told you nothing.
    var topic: String? {
        guard isClassLesson else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A few letters for a grid cell: "MA", "DAAB", "SP", "AP".
    var shortLabel: String {
        if let part = subjectPart, isClassLesson {
            let first = part.split(separator: " ").first.map(String.init) ?? part
            return String(first.prefix(4)).uppercased()
        }
        return headline
    }

    var startMinutes: Int? { Lesson.minutes(from: start) }
    var endMinutes: Int? { Lesson.minutes(from: end) }

    /// The class-and-subject teams in a Hold line, as their subject parts.
    static func classTeamParts(_ team: String) -> [String] {
        team.split(separator: ",").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard let g = Rx.match("^\\d[a-zA-ZæøåÆØÅ]{1,3}\\s+(.+)$", t) else { return nil }
            return g[1].trimmingCharacters(in: .whitespaces)
        }
    }

    /// "1g: AP-eksamen" -> "AP-eksamen"; "1i, 1j: NV-eksamen" -> "NV-eksamen".
    static func withoutAudience(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = t.firstIndex(of: ":"), audience(String(t[..<colon])) != nil {
            return t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// The classes and years an all-day item names up front, if it does:
    /// "1g", "1i, 1j", "3g (enkelte klasser)". Nil when it doesn't start
    /// with one.
    static func audience(_ prefix: String) -> [String]? {
        let tokens = prefix.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let known = tokens.filter { Rx.test("^\\d\\.?\\s?[a-zæøå]{1,3}\\b", $0) }
        return known.isEmpty ? nil : known
    }

    /// Whether an all-day item is for you. Lectio shows every year's all-day
    /// items to everyone; "3m, 1i: Tidying up the Foyer" isn't yours if
    /// you're in 1j.
    func isRelevant(toClass className: String) -> Bool {
        let cls = className.lowercased()
        guard let year = cls.first, year.isNumber else { return true }
        let t = title.trimmingCharacters(in: .whitespaces)
        let head: String
        if let colon = t.firstIndex(of: ":") {
            head = String(t[..<colon])
        } else {
            head = String(t.split(separator: ",").first ?? "")
        }
        guard let tokens = Lesson.audience(head) else { return true }
        return tokens.contains { token in
            let compact = token.replacingOccurrences(of: " ", with: "")
            return compact == cls || compact.hasPrefix(String(year) + "g") || compact.hasPrefix(String(year) + ".g")
        }
    }
}

// MARK: - Modules

extension ScheduleWeek {
    /// Lectio's modules, or — for a week cached before they were read —
    /// slots worked out from when this week's lessons actually run.
    var resolvedModules: [ScheduleModule] {
        if let modules, !modules.isEmpty { return modules }
        return ScheduleModule.derive(from: days.flatMap(\.lessons))
    }
}

extension ScheduleModule {
    /// The start–end pairs class lessons use most, as slots that don't
    /// overlap.
    static func derive(from lessons: [Lesson]) -> [ScheduleModule] {
        var counts: [String: Int] = [:]
        for lesson in lessons where lesson.isClassLesson && !lesson.isAllDay {
            guard lesson.startMinutes != nil, lesson.endMinutes != nil else { continue }
            counts[lesson.start + "|" + lesson.end, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value > $1.value }.map { $0.key }
        var chosen: [(Int, Int, String, String)] = []
        for key in ranked {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, let s = Lesson.minutes(from: parts[0]),
                  let e = Lesson.minutes(from: parts[1]) else { continue }
            if chosen.contains(where: { s < $0.1 && $0.0 < e }) { continue }
            chosen.append((s, e, parts[0], parts[1]))
        }
        return chosen.sorted { $0.0 < $1.0 }.enumerated().map { index, slot in
            ScheduleModule(number: index + 1, start: slot.2, end: slot.3)
        }
    }

    /// "8:00" rather than "08:00", for the narrow column.
    var shortStart: String { start.hasPrefix("0") ? String(start.dropFirst()) : start }
    var shortEnd: String { end.hasPrefix("0") ? String(end.dropFirst()) : end }
}

// MARK: - A day, sorted into modules

/// A day as the module view draws it: all-day items on top, the school's
/// modules in order with what's in each, and anything outside them before
/// or after.
struct DayPlan {
    struct Slot: Identifiable {
        let module: ScheduleModule
        /// Yours: class lessons and your own events. When a module has none
        /// of those, the events in it (an exam, a trip) take their place.
        var main: [Lesson] = []
        /// Something that started in an earlier module and is still going.
        var continuing: [Lesson] = []
        /// Everything else in the module: optional things, clubs, events.
        var others: [Lesson] = []
        /// Your lessons in this module that were cancelled.
        var cancelled: [Lesson] = []

        var id: Int { module.number }
        var isFree: Bool { main.isEmpty && continuing.isEmpty }
        var hasAnything: Bool { !main.isEmpty || !continuing.isEmpty || !cancelled.isEmpty }
    }

    var allDay: [Lesson] = []
    var before: [Lesson] = []
    var slots: [Slot] = []
    var after: [Lesson] = []

    /// When the last module with something of yours ends.
    var schoolEnd: Int? {
        slots.last(where: { !$0.isFree }).map { $0.module.endMinutes }
    }

    static func build(_ day: ScheduleDay, modules: [ScheduleModule], className: String) -> DayPlan {
        var plan = DayPlan()

        // All-day: yours only, each once.
        var seen: Set<String> = []
        for item in day.lessons where item.isAllDay && item.isRelevant(toClass: className) {
            let key = item.headline.lowercased()
            if seen.insert(key).inserted { plan.allDay.append(item) }
        }

        let timed = day.lessons.filter { !$0.isAllDay }
            .sorted { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }
        var slots = modules.map { Slot(module: $0) }
        guard let firstStart = modules.map(\.startMinutes).min() else {
            plan.after = timed
            return plan
        }

        for lesson in timed {
            guard let s = lesson.startMinutes, let e = lesson.endMinutes else {
                plan.after.append(lesson)
                continue
            }
            // A module holds a lesson that fills a good part of it: 15
            // minutes, or half the lesson when it's shorter than that.
            let needed = min(15, max(1, (e - s) / 2))
            let hits = slots.indices.filter { i in
                let m = slots[i].module
                return min(e, m.endMinutes) - max(s, m.startMinutes) >= needed
            }
            guard let first = hits.first else {
                if s < firstStart { plan.before.append(lesson) } else { plan.after.append(lesson) }
                continue
            }
            for i in hits {
                let mine = lesson.isClassLesson || lesson.isPrivateEvent
                if lesson.cancelled {
                    if i == first {
                        if mine { slots[i].cancelled.append(lesson) } else { slots[i].others.append(lesson) }
                    }
                } else if i != first {
                    slots[i].continuing.append(lesson)
                } else if mine {
                    slots[i].main.append(lesson)
                } else {
                    slots[i].others.append(lesson)
                }
            }
        }

        // A module with nothing of yours: its events are what's on.
        for i in slots.indices where slots[i].main.isEmpty && slots[i].continuing.isEmpty {
            let held = slots[i].others.filter { !$0.cancelled }
            if !held.isEmpty {
                slots[i].main = held
                slots[i].others.removeAll { !$0.cancelled }
            }
        }
        // A continuing event under a module's own lesson is just noise there.
        for i in slots.indices where !slots[i].main.isEmpty {
            slots[i].others += slots[i].continuing
            slots[i].continuing = []
        }

        // Every module up to the last one with something in it; free ones
        // before that are real free periods.
        if let last = slots.lastIndex(where: { $0.hasAnything }) {
            plan.slots = Array(slots[...last])
        }
        return plan
    }
}
