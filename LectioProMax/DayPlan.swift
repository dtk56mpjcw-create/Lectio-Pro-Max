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

// MARK: - Whose it is

extension Lesson {
    /// An event meant for your class, not merely open to it: its Hold line
    /// names the class itself ("Alle 1j-elever", "1j"), or its title does
    /// ("1i, 1j: NV-eksamen"). "Alle 1. STX-elever" alone isn't enough —
    /// Lectio puts it on auditions, voluntary drama and Musicafe too.
    func isFor(className: String) -> Bool {
        guard !isClassLesson, !isPrivateEvent, !Lesson.isVoluntary(title) else { return false }
        let cls = className.lowercased().replacingOccurrences(of: " ", with: "")
        guard !cls.isEmpty else { return false }
        if let team {
            for part in team.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces).lowercased()
                if t == cls || t == "alle \(cls)-elever" { return true }
            }
        }
        let t = title.trimmingCharacters(in: .whitespaces)
        if let colon = t.firstIndex(of: ":"), let tokens = Lesson.audience(String(t[..<colon])) {
            return tokens.contains { $0.replacingOccurrences(of: " ", with: "") == cls }
        }
        return false
    }

    /// "Frivillig drama", "Frivillig billedkunst & design".
    static func isVoluntary(_ title: String) -> Bool {
        Rx.test("^\\s*frivillig", title)
    }

    /// An exam the school holds: "AP-eksamen", "1i, 1j: NV-eksamen",
    /// "Sygeeksamen AP". Not a class lesson's topic — "Practice test",
    /// "Revision for screening test" and "Test return" say "test" too, and
    /// the topic is right there on the lesson anyway.
    /// The word has to end there: "Eksamensplan offentliggøres" is news
    /// about exams, not one.
    var isExam: Bool {
        guard !isClassLesson else { return false }
        return Rx.test("eksamen(?![a-zæøå])|prøve(?![a-zæøå])|\\btest\\b|\\bexams?\\b", title)
    }

    /// An exam note addressed to your class or year ("1i, 1j: NV-eksamen",
    /// "1g: AP-eksamen"): a banner, and the Exam tag in the week. One for
    /// whoever takes it ("DELF-eksamen", "MU skr eksamen") is a plain note.
    var isAddressedExam: Bool {
        guard isExam else { return false }
        let t = title
        return t.firstIndex(of: ":").flatMap { Lesson.audience(String(t[..<$0])) } != nil
    }

    /// Letters and digits only, lowercased: "AP-eksamen" and "Ap Eksamen"
    /// are both "apeksamen".
    static func squashed(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.append(u)
        }
        return String(out)
    }
}

// MARK: - A day, sorted into modules

/// A day as the module view draws it: exam banners and all-day notes on
/// top, the school's modules in order with what's in each, and anything
/// outside them before or after.
struct DayPlan {
    struct Slot: Identifiable {
        let module: ScheduleModule
        /// The last module of a block that runs on over several: a double
        /// lesson, an exam, a reading day ("1–3").
        var through: ScheduleModule? = nil
        /// Yours: your class lessons, your own events, and events meant for
        /// your class (an exam, a reading day).
        var main: [Lesson] = []
        /// Something that started in an earlier module and is still going.
        var continuing: [Lesson] = []
        /// Everything else in the module: optional things, clubs, events
        /// that are open to you but not for you.
        var others: [Lesson] = []
        /// Your lessons in this module that were cancelled.
        var cancelled: [Lesson] = []

        var id: Int { module.number }
        var isFree: Bool { main.isEmpty && continuing.isEmpty }
        var hasAnything: Bool { !main.isEmpty || !continuing.isEmpty || !cancelled.isEmpty }
        var hasContent: Bool { hasAnything || !others.isEmpty }

        var last: ScheduleModule { through ?? module }
        /// "2", or "1–3" for a block over several.
        var label: String { through.map { "\(module.number)–\($0.number)" } ?? "\(module.number)" }
        /// The whole block as one module: from the first's start to the
        /// last's end.
        var span: ScheduleModule {
            ScheduleModule(number: module.number, start: module.start, end: last.end)
        }
        var startMinutes: Int { module.startMinutes }
        var endMinutes: Int { last.endMinutes }
    }

    /// An exam for your class with no time given ("1i, 1j: NV-eksamen"):
    /// too important for a grey chip.
    var banners: [Lesson] = []
    var allDay: [Lesson] = []
    var before: [Lesson] = []
    var slots: [Slot] = []
    var after: [Lesson] = []

    /// When the last block with something of yours ends.
    var schoolEnd: Int? {
        slots.last(where: { !$0.isFree }).map { $0.endMinutes }
    }

    /// Modules starting at 15:00 or later are outside the school day. The
    /// day's last lessons end by about 15:15; what Lectio puts in the late
    /// module after that — a maths study hall, a club — is optional, and
    /// belongs under "After school", not among your lessons.
    static let schoolDayEndsBy = 15 * 60

    static func build(_ day: ScheduleDay, modules allModules: [ScheduleModule], className: String) -> DayPlan {
        var plan = DayPlan()
        let within = allModules.filter { $0.startMinutes < schoolDayEndsBy }
        let modules = within.isEmpty ? allModules : within
        let dayStart = modules.map(\.startMinutes).min()
        let dayEnd = modules.map(\.endMinutes).max()

        // 1. Sort out what has a time. All-day items that do have hours —
        // the first and last day of something running over several days,
        // or a note naming its time or module — are placed like anything
        // else. Lectio also draws some tiles twice; each counts once.
        var timed: [Lesson] = []
        var notes: [Lesson] = []
        var seenTiles: Set<String> = []
        for item in day.lessons {
            let tileKey = item.id + "|" + (item.allDay ?? "~") + "|" + (item.team ?? "")
            guard seenTiles.insert(tileKey).inserted else { continue }
            if item.isAllDay {
                guard item.isRelevant(toClass: className) else { continue }
                switch placement(of: item, dayStart: dayStart, dayEnd: dayEnd,
                                 modules: modules, className: className) {
                case .timed(let placed): timed.append(placed)
                case .note(let note): notes.append(note)
                case .skip: break
                }
            } else {
                timed.append(item)
            }
        }

        let isMine: (Lesson) -> Bool = { $0.isClassLesson || $0.isPrivateEvent }
        let isYours: (Lesson) -> Bool = { isMine($0) || $0.isFor(className: className) }

        // 2. Your lesson and the event it's part of are one thing. Lectio
        // lists "Ap Eksamen" on your AP team (with your room) and
        // "AP-eksamen" for the whole year (08:00–11:35, fifteen rooms):
        // one block, with the event's name and hours and your room.
        var absorbed: Set<String> = []
        for i in timed.indices where timed[i].isFor(className: className) && !timed[i].cancelled {
            let name = Lesson.squashed(timed[i].headline)
            guard name.count >= 4,
                  let s = timed[i].startMinutes, let e = timed[i].endMinutes else { continue }
            let candidates = timed
            for lesson in candidates where isMine(lesson) && !lesson.cancelled && !absorbed.contains(lesson.id) {
                guard let ls = lesson.startMinutes, let le = lesson.endMinutes,
                      ls < e, s < le,
                      Lesson.squashed(lesson.title) == name else { continue }
                absorbed.insert(lesson.id)
                if !lesson.room.isEmpty { timed[i].room = lesson.room }
                if !lesson.teacher.isEmpty { timed[i].teacher = lesson.teacher }
                if timed[i].note.isEmpty { timed[i].note = lesson.note }
                if timed[i].homework.isEmpty { timed[i].homework = lesson.homework }
                if let link = lesson.link { timed[i].link = link }
            }
        }
        timed.removeAll { absorbed.contains($0.id) }
        timed.sort { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }

        // 3. Into the modules.
        var slots = modules.map { Slot(module: $0) }
        var seenNames: Set<String> = []
        guard let firstStart = dayStart else {
            plan.after = timed
            plan.allDay = notes
            return plan
        }

        for lesson in timed {
            guard let s = lesson.startMinutes, let e = lesson.endMinutes else {
                if let s = lesson.startMinutes, s < firstStart { plan.before.append(lesson) }
                else { plan.after.append(lesson) }
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
            let mine = isMine(lesson)
            let yours = isYours(lesson)
            // Something optional across three modules or more (an audition
            // day) isn't something in each module; it goes up top with its
            // hours. Anything of yours stays in the modules, however long.
            if hits.count >= 3 && !yours && !lesson.cancelled {
                var spanning = lesson
                spanning.allDay = lesson.start + "–" + lesson.end
                if seenNames.insert(Lesson.squashed(spanning.headline)).inserted {
                    plan.allDay.append(spanning)
                }
                continue
            }
            for i in hits {
                if lesson.cancelled {
                    if i == first {
                        if mine { slots[i].cancelled.append(lesson) } else { slots[i].others.append(lesson) }
                    }
                } else if !yours {
                    // Optional: noted once, where it starts.
                    if i == first { slots[i].others.append(lesson) }
                } else if i != first {
                    slots[i].continuing.append(lesson)
                } else {
                    slots[i].main.append(lesson)
                }
            }
        }

        // Your own lesson keeps its module. An event of yours running
        // through it — or starting in it — is noted underneath, so a module
        // never has two big blocks.
        for i in slots.indices {
            let lessons = slots[i].main.filter(isMine)
            let events = slots[i].main.filter { !isMine($0) }
            if !lessons.isEmpty {
                slots[i].main = lessons
                slots[i].others = events + slots[i].continuing + slots[i].others
                slots[i].continuing = []
            } else if !events.isEmpty {
                slots[i].others = slots[i].continuing + slots[i].others
                slots[i].continuing = []
            }
        }

        // A block that runs on — a double lesson, an exam, a reading day —
        // is one block across its modules, not a card in each.
        var merged: [Slot] = []
        for slot in slots {
            if var previous = merged.last,
               !previous.main.isEmpty,
               slot.main.isEmpty, !slot.continuing.isEmpty,
               Set(slot.continuing.map(\.id)).isSubset(of: Set(previous.main.map(\.id))) {
                previous.through = slot.module
                for item in slot.others where !previous.others.contains(where: { $0.id == item.id }) {
                    previous.others.append(item)
                }
                // A lesson the exam replaced is still worth a word.
                previous.cancelled += slot.cancelled
                merged[merged.count - 1] = previous
            } else {
                merged.append(slot)
            }
        }

        // Every module up to the last one with something in it; free ones
        // before that are real free periods.
        if let last = merged.lastIndex(where: { $0.hasContent }) {
            plan.slots = Array(merged[...last])
        }

        // 4. The notes left: an exam for your class becomes a banner; the
        // rest stay as chips — unless the day already shows the same thing
        // ("1g: AP-eksamen" next to the exam itself, "1g: Læsedag" next to
        // the AP reading day). A lesson is matched by its title (its topic),
        // anything else by its name; the note has to be the same thing or
        // the general word for it ("Læsedag" in "AP-læsedag"), never the
        // other way round.
        var onTheDay: [Lesson] = plan.before + plan.after
        onTheDay += plan.allDay
        for slot in plan.slots {
            onTheDay += slot.main + slot.continuing
            onTheDay += slot.others + slot.cancelled
        }
        let shown: [String] = onTheDay
            .map { Lesson.squashed($0.isClassLesson ? $0.title : $0.headline) }
            .filter { $0.count >= 4 }
        var chips: [Lesson] = []
        for note in notes {
            let name = Lesson.squashed(note.headline)
            let repeated = name.count >= 4 && shown.contains { other in
                other == name || (name.count >= 5 && other.contains(name))
            }
            guard !repeated, seenNames.insert(name).inserted else { continue }
            if note.isAddressedExam { plan.banners.append(note) } else { chips.append(note) }
        }
        plan.allDay = chips + plan.allDay
        return plan
    }

    /// Where an all-day item goes on this day.
    enum Placement {
        /// It has hours here: placed like anything else.
        case timed(Lesson)
        /// A note for the top of the day.
        case note(Lesson)
        /// Nothing on this day at all: the last day of something that
        /// ends at midnight ("Vinterferie 15/2 00:00 til 20/2 00:00").
        case skip
    }

    /// The hours an all-day item actually has. Days of something running
    /// over several days: "from 12:00" runs to the end of the school day,
    /// "until 11:00" from its start, and a day it fills — the days between,
    /// or one that starts at midnight — is the whole school day. Notes that
    /// say when: "Nørre Skriver (13:40-15:00)", "DELF Master Class (4.
    /// modul)". Anything else stays a note.
    static func placement(of item: Lesson, dayStart: Int?, dayEnd: Int?,
                          modules: [ScheduleModule], className: String) -> Placement {
        let label = item.allDay ?? ""
        guard let dayStart, let dayEnd else { return .note(item) }

        // A whole school day of it: a block when it's yours (an exam over
        // several days, a trip), otherwise a plain note — "Vinterferie",
        // not "Vinterferie 08:00–15:15".
        let wholeDay: Placement
        if item.isFor(className: className) {
            wholeDay = .timed(DayPlan.timedCopy(item, from: dayStart, to: dayEnd, title: item.title))
        } else {
            var note = item
            note.allDay = ""
            wholeDay = .note(note)
        }

        if let g = Rx.match("^from (\\d{1,2}:\\d{2})$", label), let s = Lesson.minutes(from: g[1]) {
            if s <= dayStart { return wholeDay }
            return .timed(DayPlan.timedCopy(item, from: s, to: s < dayEnd ? dayEnd : nil, title: item.title))
        }
        if let g = Rx.match("^until (\\d{1,2}:\\d{2})$", label), let e = Lesson.minutes(from: g[1]) {
            if e <= dayStart { return .skip }
            if e >= dayEnd { return wholeDay }
            return .timed(DayPlan.timedCopy(item, from: dayStart, to: e, title: item.title))
        }
        if label == "all day" { return wholeDay }
        guard label.isEmpty else { return .note(item) }

        let title = item.title
        let timePattern = "\\s*\\((\\d{1,2})[:.](\\d{2})\\s*[-–]\\s*(\\d{1,2})[:.](\\d{2})\\)"
        let modulePattern = "\\s*\\((\\d{1,2})\\.\\s*modul\\)"
        if let g = Rx.match(timePattern, title),
           let h1 = Int(g[1]), let m1 = Int(g[2]), let h2 = Int(g[3]), let m2 = Int(g[4]) {
            let cleaned = title.replacingOccurrences(of: timePattern, with: "", options: .regularExpression)
            return .timed(DayPlan.timedCopy(item, from: h1 * 60 + m1, to: h2 * 60 + m2, title: cleaned))
        }
        if let g = Rx.match(modulePattern, title), let n = Int(g[1]),
           let module = modules.first(where: { $0.number == n }) {
            let cleaned = title.replacingOccurrences(of: modulePattern, with: "",
                                                     options: [.regularExpression, .caseInsensitive])
            return .timed(DayPlan.timedCopy(item, from: module.startMinutes, to: module.endMinutes, title: cleaned))
        }
        return .note(item)
    }

    /// The item as an ordinary timed one. No end (or none after the start)
    /// leaves just a start time: it lands before or after school.
    private static func timedCopy(_ item: Lesson, from start: Int, to end: Int?, title: String) -> Lesson {
        var copy = item
        copy.allDay = nil
        copy.title = title.trimmingCharacters(in: .whitespaces)
        copy.start = DayPlan.clock(start)
        if let end, end > start {
            copy.end = DayPlan.clock(end)
        } else {
            copy.end = ""
        }
        return copy
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
