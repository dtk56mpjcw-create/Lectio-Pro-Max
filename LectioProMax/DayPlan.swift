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
    /// A class is a year and letters — "1j ma", "3g RE 3" — or, at a
    /// school that writes its classes another way, the shape of your own
    /// class ("1.a da", "HF1b en"; see ClassNames).
    static func classTeamParts(_ team: String) -> [String] {
        let patterns = ClassNames.teamPatterns
        return team.split(separator: ",").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            for pattern in patterns {
                if let g = Rx.match(pattern, t) {
                    return g[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
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
        let cls = Lesson.compactClass(className)
        guard let year = ClassNames.year(of: className) else { return true }
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

// MARK: - Class names

/// How this school writes its classes. Most write a year and letters
/// ("1j", "3g"); some "1.a", "2.x" or "HF1b". Lessons are told from events
/// by their team starting with a class, so the pattern is the usual one
/// plus one in the shape of your own class, learnt from your profile.
enum ClassNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var own = ""
    nonisolated(unsafe) private static var ownPattern: String?

    /// "1j" and "1i ap la": a year, one to three letters.
    static let usual = "^\\d[a-zA-ZæøåÆØÅ]{1,3}\\s+(.+)$"

    static var teamPatterns: [String] {
        lock.lock(); defer { lock.unlock() }
        return [usual] + (ownPattern.map { [$0] } ?? [])
    }

    /// Learn the shape of your class: digits stay digits, letters are
    /// letters, a dot or space may be there or not. Only a shape with a
    /// year in it — a bare word would match clubs like "MUN leadership".
    static func use(_ className: String) {
        let name = className.trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock(); defer { lock.unlock() }
        guard name != own else { return }
        own = name
        guard name.contains(where: \.isNumber), name.contains(where: \.isLetter) else {
            ownPattern = nil
            return
        }
        var shape = ""
        var inLetters = false
        for ch in name {
            if ch.isLetter {
                if !inLetters { shape += "[a-zæøå]{1,4}" }
                inLetters = true
                continue
            }
            inLetters = false
            if ch.isNumber { shape += "\\d" }
            else if ch == "." || ch == "-" { shape += "[.-]?" }
            else if ch == " " { shape += "\\s?" }
            else { shape += NSRegularExpression.escapedPattern(for: String(ch)) }
        }
        let pattern = "^" + shape + "\\s+(.+)$"
        ownPattern = pattern == usual ? nil : pattern
    }

    /// The year of a class: its first digit ("1j" → 1, "HF1b" → 1).
    static func year(of className: String) -> Character? {
        className.first(where: \.isNumber)
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

    /// The modules of your school day: all of them but the late ones your
    /// timetable hardly uses. Worked out from your own lessons — a module
    /// you have lessons in on two days of the week or more is part of the
    /// day — so a school whose lessons do run late keeps them, while a
    /// maths study hall once a week at 15:20 is "After school".
    ///
    /// A week with too few lessons to tell (exams, holidays, a timetable not
    /// out yet) goes by the last ordinary week, or failing that by the
    /// clock: modules starting at 15:00 or later.
    var dayModules: [ScheduleModule] {
        let modules = resolvedModules
        guard modules.count > 1 else { return modules }

        var daysIn: [Int: Set<String>] = [:]
        for day in days {
            for lesson in day.lessons where lesson.isClassLesson && !lesson.cancelled {
                guard let s = lesson.startMinutes, let e = lesson.endMinutes else { continue }
                for m in modules where min(e, m.endMinutes) - max(s, m.startMinutes) >= 15 {
                    daysIn[m.number, default: []].insert(day.date)
                }
            }
        }
        let busiest = daysIn.values.map(\.count).max() ?? 0
        if busiest >= 3, let last = modules.last(where: { (daysIn[$0.number]?.count ?? 0) >= 2 }) {
            ScheduleWeek.rememberDayEnd(last.number)
            return modules.filter { $0.number <= last.number }
        }
        if let remembered = ScheduleWeek.rememberedDayEnd,
           modules.contains(where: { $0.number == remembered }) {
            return modules.filter { $0.number <= remembered }
        }
        let byClock = modules.filter { $0.startMinutes < DayPlan.schoolDayEndsBy }
        return byClock.isEmpty ? modules : byClock
    }

    /// Notes that run through the week for others in turn — "1g:
    /// Introture" on all five days while each class goes on its own two
    /// — by name: on three weekdays or more and not naming your class.
    /// A day with lessons of yours leaves them out; Lectio puts them on
    /// everyone's schedule every day.
    func rollingNotes(className: String) -> Set<String> {
        var datesByName: [String: Set<String>] = [:]
        for day in days where LectioDates.isWeekday(iso: day.date) {
            for item in day.lessons where item.isAllDay && !item.namesClass(className) {
                datesByName[Lesson.squashed(item.headline), default: []].insert(day.date)
            }
        }
        return Set(datesByName.filter { $0.value.count >= 3 }.map(\.key))
    }

    /// Per school: a school you switch to has its own day.
    private static var dayEndKey: String { "schedule.dayEndModule." + LectioConfig.schoolID }

    fileprivate static var rememberedDayEnd: Int? {
        let n = UserDefaults.standard.integer(forKey: dayEndKey)
        return n > 0 ? n : nil
    }

    fileprivate static func rememberDayEnd(_ number: Int) {
        if UserDefaults.standard.integer(forKey: dayEndKey) != number {
            UserDefaults.standard.set(number, forKey: dayEndKey)
        }
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
    /// Named for your class itself: its Hold line ("Alle 1j-elever", "1j")
    /// or its title ("1i, 1j: NV-eksamen", "3b, 1j: Oprydning i Foyeren").
    func namesClass(_ className: String) -> Bool {
        let cls = Lesson.compactClass(className)
        guard !cls.isEmpty else { return false }
        if let team {
            for part in team.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces).lowercased()
                if t == cls || t == "alle \(cls)-elever" { return true }
            }
        }
        return Lesson.titleAudience(title)?.contains(cls) ?? false
    }

    /// Meant for your class, not merely open to it: named for it (above),
    /// or for your year and nobody else — a Hold line whose every year
    /// group is yours ("Alle 1. STX-elever, Alle 1i-elever": the first
    /// years' reading day), a title for your year ("1g: Matematikscreening").
    /// An offer to the whole school names every year ("Alle 1. STX-elever,
    /// Alle 2. STX-elever, …" on auditions, voluntary drama, Musicafe) and
    /// stays optional; so does anything "Frivillig". Groups without a year
    /// ("Alle Pre-IB elever", "MUN 26/27") don't count either way.
    func isFor(className: String) -> Bool {
        guard !isClassLesson, !isPrivateEvent, !Lesson.isVoluntary(title) else { return false }
        if namesClass(className) { return true }
        guard let year = ClassNames.year(of: className) else { return false }
        if let team, !team.isEmpty {
            var years: Set<Character> = []
            for part in team.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces).lowercased()
                if let g = Rx.match("^(?:alle\\s+)?(\\d)(?:\\.|[a-zæøå]{1,3}(?:-elever)?\\b)", t),
                   let digit = g[1].first {
                    years.insert(digit)
                }
            }
            if years == [year] { return true }
        }
        if let tokens = Lesson.titleAudience(title) {
            return tokens.allSatisfy { $0.hasPrefix("\(year)g") || $0.hasPrefix("\(year).g") }
        }
        return false
    }

    /// "1j", from "1j" or "1 J".
    static func compactClass(_ className: String) -> String {
        className.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// The classes and years a title starts with: "1i, 1j: NV-eksamen" →
    /// ["1i", "1j"], "1g og pre-IB: AP-stjerneløb" → ["1gogpre-ib"]. Nil
    /// when it doesn't start with any.
    static func titleAudience(_ title: String) -> [String]? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":"),
              let tokens = audience(String(t[..<colon])) else { return nil }
        return tokens.map { $0.replacingOccurrences(of: " ", with: "") }
    }

    /// "Frivillig drama", "Frivillig billedkunst & design".
    static func isVoluntary(_ title: String) -> Bool {
        Rx.test("^\\s*frivillig", title)
    }

    // MARK: What it is

    /// What something is, from the words schools write in Lectio — Danish
    /// and English. It decides where a thing goes and how loud it is; in
    /// this order when a day has several.
    enum Kind: Int, Comparable {
        case exam, noSchool, trip, readingDay, event, observance, staffOnly

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// An exam the school holds ("AP-eksamen", "Terminsprøver", "Mocks",
    /// "Matematikscreening"). The word has to end there: "Eksamensplan
    /// offentliggøres" is news about exams, not one.
    static let examWords =
        "eksamen(?:er)?(?![a-zæøå])|prøver?(?![a-zæøå])|\\btests?\\b(?!\\s+af\\b)|\\bexams?\\b|\\bmocks?\\b|screening|\\bskr\\.? ex\\b"
        + "|prüfung|klausur|abitur"

    var kind: Kind {
        let t = title
        if Rx.test("personalemøde|lærermøde|lærere møder ind|bestyrelsesmøde|indtastning af", t) {
            return .staffOnly
        }
        // A class lesson's topic ("Practice test", "Test return") isn't a
        // school exam; the topic is right there on the lesson. Nor is the
        // time to meet for one ("Mødetid AP prøve").
        if !isClassLesson, !Rx.test("^\\s*mødetid|^\\s*mødested", t), Rx.test(Lesson.examWords, t) {
            return .exam
        }
        // Danish first, then English (IB lines, international schools) and
        // German (the German minority's gymnasium).
        if Rx.test("læsedag|reading day|study day|studiedag|lesetag|studientag", t) { return .readingDay }
        if Rx.test("introtur|studietur|\\btur\\b|\\bture\\b|rejse|ekskursion|excursion|\\btrips?\\b|udveksling|lejrskole|inkursion"
                   + "|exkursion|ausflug|studienfahrt|klassenfahrt|exchange", t) {
            return .trip
        }
        if Rx.test("ferie|helligdag|fridag|\\bfri\\b|kristi himmelfart|pinsedag|påskedag|\\bholidays?\\b|no school"
                   + "|(autumn|winter|christmas|easter|spring|summer|half[- ]term|mid[- ]term) break|vacation|feiertag|schulfrei|unterrichtsfrei", t) {
            return .noSchool
        }
        if Rx.test("^\\s*(international|den internationale|verdens|world|fn-dag|un day|europæisk sprogdag|welt|internationaler)"
                   + "|\\(unesco\\)", t) {
            return .observance
        }
        return .event
    }

    var isExam: Bool { kind == .exam }

    /// The kind a block shows as a colour and tag: an exam, a day off, a
    /// trip, a reading day. A class lesson only when it's one of those over
    /// several days (the class's intro trip) — a lesson whose topic says
    /// "fri" or "trip" is still a lesson.
    var markKind: Kind? {
        let k = kind
        guard k.rawValue < Kind.event.rawValue else { return nil }
        if isClassLesson && span == nil { return nil }
        return k
    }

    // MARK: Over several days

    /// Where this day is in something over several days, and when it ends:
    /// "Day 1 of 2 · until Thu 16:00", "Day 2 of 2 · until 16:00". Nil for
    /// anything on one day. Something ending at midnight ("Vinterferie til
    /// 20/2 00:00") ends the day before.
    func spanNote(on dayISO: String) -> String? {
        guard let span, let bar = span.firstIndex(of: "|") else { return nil }
        let from = String(span[..<bar])
        let to = String(span[span.index(after: bar)...])
        guard from.count >= 16, to.count >= 16 else { return nil }
        let firstDay = String(from.prefix(10))
        let endDate = String(to.prefix(10))
        let endTime = String(to.suffix(5))
        let lastDay = endTime == "00:00" ? LectioDates.shift(iso: endDate, byDays: -1) : endDate

        var days: [String] = []
        var day = firstDay
        while day <= lastDay && days.count < 90 {
            days.append(day)
            day = LectioDates.shift(iso: day, byDays: 1)
        }
        guard days.count >= 2, let index = days.firstIndex(of: dayISO) else { return nil }

        var parts = ["Day \(index + 1) of \(days.count)"]
        if endTime != "00:00" {
            let time = endTime.hasPrefix("0") ? String(endTime.dropFirst()) : endTime
            if dayISO == lastDay {
                parts.append("until " + time)
            } else {
                // "until Thu 16:00" within the week, "until 3 Oct 16:00" beyond.
                let label = LectioDates.dayLabel(iso: lastDay).split(separator: " ").map(String.init)
                let near = days.count - index <= 6
                let when = near ? (label.first ?? "") : label.dropFirst().joined(separator: " ")
                parts.append("until " + when + " " + time)
            }
        }
        return parts.joined(separator: " · ")
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

// MARK: - A day, sorted

/// A day in order of what matters, as the day view draws it:
///
/// 1. What kind of day it is (`status`), when it isn't an ordinary one — an
///    exam, no school, a trip, a reading day, any other day-long thing of
///    yours. The first is the big card; any others are lines under it.
/// 2. Your modules (`slots`), each the same height: your lessons, and
///    events of yours for part of the day (an exam 8–11:35) as blocks.
/// 3. Everything optional in school hours (`also`), in one list.
/// 4. After school (`after`).
/// Notes for the day sit on top as chips (`allDay`); awareness days
/// ("Verdensdag for Vand") are a line at the very bottom (`observances`);
/// staff-only notes ("Personalemøde") aren't shown.
struct DayPlan {
    struct Slot: Identifiable {
        let module: ScheduleModule
        /// The last module of a block that runs on over several: a double
        /// lesson, an exam, a reading day.
        var through: ScheduleModule? = nil
        /// Every module the block covers, in order (set when it runs on).
        var covered: [ScheduleModule] = []
        var modules: [ScheduleModule] { covered.isEmpty ? [module] : covered }
        /// Yours: your class lessons, your own events, and events meant for
        /// your class (an exam, a reading day).
        var main: [Lesson] = []
        /// Something that started in an earlier module and is still going.
        var continuing: [Lesson] = []
        /// While sorting only: what else is on in the module. It all ends
        /// up in the day's "Also on" list.
        var others: [Lesson] = []
        /// On a free module: the lesson of yours that was cancelled.
        var cancelled: [Lesson] = []
        /// Short things of yours in the break after this module: the
        /// meeting time before an exam, a meeting in the lunch break.
        var breakAfter: [Lesson] = []
        /// Other things of yours at the same time as the block, less
        /// important than it: the reading day under an exam. Shown inside
        /// the block, so a module never has two.
        var alongside: [Lesson] = []

        /// How the block's one item sits in the day ("all", "starts",
        /// "ends"; see Lesson.dayShape).
        var dayShape: String? {
            (main.count == 1 && continuing.isEmpty) ? main[0].dayShape : nil
        }

        var id: Int { module.number }
        var isFree: Bool { main.isEmpty && continuing.isEmpty }
        var hasAnything: Bool { !main.isEmpty || !continuing.isEmpty || !cancelled.isEmpty }
        var hasContent: Bool { hasAnything || !breakAfter.isEmpty }

        var last: ScheduleModule { through ?? module }
        /// The whole block as one module: from the first's start to the
        /// last's end.
        var span: ScheduleModule {
            ScheduleModule(number: module.number, start: module.start, end: last.end)
        }
        /// Minutes the block runs on past its last module, when nothing
        /// follows it in the school day (an exam to 16:00 when lessons end
        /// at 15:15), or starts before its first (7:30 for an 8:00 module).
        /// The block grows by that much, at the rate of a module, so a
        /// longer day is a longer block.
        var overrunBefore = 0
        var overrunAfter = 0

        var startMinutes: Int { module.startMinutes - overrunBefore }
        var endMinutes: Int { last.endMinutes + overrunAfter }

        /// What the side of a block over several modules shows: its own
        /// hours ("12:00–15:15", "08:00–16:00"), not module numbers.
        var hours: ScheduleModule {
            guard through != nil || overrunBefore > 0 || overrunAfter > 0 else { return module }
            if main.count == 1, let lesson = main.first, !lesson.start.isEmpty, !lesson.end.isEmpty {
                return ScheduleModule(number: module.number, start: lesson.start, end: lesson.end)
            }
            return span
        }
    }

    var status: [Lesson] = []
    var allDay: [Lesson] = []
    var before: [Lesson] = []
    var slots: [Slot] = []
    var also: [Lesson] = []
    var after: [Lesson] = []
    var observances: [Lesson] = []

    /// When the last block with something of yours ends.
    var schoolEnd: Int? {
        slots.last(where: { !$0.isFree }).map { $0.endMinutes }
    }

    /// When there's nothing better to go by (see ScheduleWeek.dayModules):
    /// modules starting at 15:00 or later are after school.
    static let schoolDayEndsBy = 15 * 60

    /// `modules` are the school day's (ScheduleWeek.dayModules); anything
    /// later lands under "After school". `rolling`: see
    /// ScheduleWeek.rollingNotes.
    static func build(_ day: ScheduleDay, modules: [ScheduleModule], className: String,
                      rolling: Set<String> = []) -> DayPlan {
        ClassNames.use(className)
        var plan = DayPlan()
        let dayStart = modules.map(\.startMinutes).min()
        let dayEnd = modules.map(\.endMinutes).max()

        // 1. Sort out what has a time. All-day items that do have hours —
        // the days of something running over several, a note that names
        // its time or module — are placed like anything else. Lectio also
        // draws some tiles twice; each counts once.
        var timed: [Lesson] = []
        var notes: [Lesson] = []
        var seenTiles: Set<String> = []
        for item in day.lessons {
            let tileKey = item.id + "|" + (item.allDay ?? "~") + "|" + (item.team ?? "")
            guard seenTiles.insert(tileKey).inserted else { continue }
            if item.isAllDay {
                guard item.isRelevant(toClass: className), item.kind != .staffOnly else { continue }
                switch placement(of: item, dayStart: dayStart, dayEnd: dayEnd,
                                 modules: modules, className: className) {
                case .timed(let placed): timed.append(placed)
                case .note(let note): notes.append(note)
                case .skip: break
                }
            } else if item.kind != .staffOnly || item.isClassLesson {
                timed.append(item)
            }
        }

        let isMine: (Lesson) -> Bool = { $0.isClassLesson || $0.isPrivateEvent }
        let isYours: (Lesson) -> Bool = { isMine($0) || $0.isFor(className: className) }

        // A day-long note for your class — "1i, 1j: NV-eksamen", a trip, a
        // reading day — on a day without lessons of yours is what the day
        // is: it fills the school day like anything else of yours, instead
        // of a small note above an empty day. Not when the day already
        // shows it ("1g: AP-eksamen" beside the exam itself), and not a
        // week-long note for every class in turn (see rollingNotes).
        let hasOwnLessons = timed.contains { isMine($0) && !$0.cancelled && $0.startMinutes != nil }
        if !hasOwnLessons, let dayStart, let dayEnd {
            let timedNames = timed.flatMap {
                [Lesson.squashed($0.headline), Lesson.squashed($0.isClassLesson ? $0.title : $0.headline)]
            }.filter { $0.count >= 4 }
            notes = notes.filter { note in
                let name = Lesson.squashed(note.headline)
                guard (note.allDay ?? "").isEmpty,
                      [.exam, .trip, .readingDay].contains(note.kind),
                      note.isFor(className: className),
                      !rolling.contains(name),
                      !timedNames.contains(where: { $0 == name || (name.count >= 5 && $0.contains(name)) })
                else { return true }
                var whole = DayPlan.timedCopy(note, from: dayStart, to: dayEnd, title: note.title)
                whole.dayShape = "all"
                timed.append(whole)
                return false
            }
        }

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
                if s < firstStart {
                    plan.before.append(lesson)
                } else if let i = slots.lastIndex(where: { $0.module.startMinutes <= s }), i < slots.count - 1 {
                    // Between two modules (or just grazing the end of one):
                    // in the day, not after it.
                    if isYours(lesson) { slots[i].breakAfter.append(lesson) } else { slots[i].others.append(lesson) }
                } else {
                    plan.after.append(lesson)
                }
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

        // One block per module. Your own lesson keeps its module, and an
        // event of yours at the same time goes to "Also on". Without one,
        // the most important thing of yours holds it — an exam before a
        // reading day, whether it starts here or runs on from earlier —
        // and the rest are noted inside its block.
        for i in slots.indices {
            let lessons = slots[i].main.filter(isMine)
            if !lessons.isEmpty {
                let events = slots[i].main.filter { !isMine($0) }
                slots[i].main = lessons
                slots[i].others = events + slots[i].continuing + slots[i].others
                slots[i].continuing = []
                continue
            }
            // Running on first, so a tie keeps the block that's going.
            let candidates = slots[i].continuing + slots[i].main
            guard let best = candidates.min(by: { DayPlan.rank($0) < DayPlan.rank($1) }) else { continue }
            let runsOn = slots[i].continuing.contains { $0.id == best.id }
            slots[i].main = runsOn ? [] : [best]
            slots[i].continuing = runsOn ? [best] : []
            slots[i].alongside = candidates.filter { $0.id != best.id }
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
                if previous.covered.isEmpty { previous.covered = [previous.module] }
                previous.covered.append(slot.module)
                previous.others += slot.others
                for item in slot.alongside where !previous.alongside.contains(where: { $0.id == item.id }) {
                    previous.alongside.append(item)
                }
                // A break inside the block is part of it.
                previous.others += previous.breakAfter
                previous.breakAfter = slot.breakAfter
                merged[merged.count - 1] = previous
            } else {
                merged.append(slot)
            }
        }

        // 4. Everything optional in school hours goes to one list under the
        // day, so each module shows only what's yours and keeps its height.
        // A lesson a block of yours replaced needs no word; a free module
        // says which lesson of yours was cancelled.
        var also: [Lesson] = []
        for i in merged.indices {
            also += merged[i].others
            merged[i].others = []
            if !merged[i].isFree {
                merged[i].cancelled = []
            } else if merged[i].cancelled.count > 1 {
                also += merged[i].cancelled.dropFirst()
                merged[i].cancelled = [merged[i].cancelled[0]]
            }
        }
        var seenAlso: Set<String> = []
        plan.also = also
            .filter { seenAlso.insert($0.id).inserted }
            .sorted { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }

        // Every module up to the last one with something of yours; free
        // ones before that are real free periods.
        if let last = merged.lastIndex(where: { $0.hasContent }) {
            plan.slots = Array(merged[...last])
        }

        // A block at either end of the day that runs past the modules keeps
        // its real length: 8:00–16:00 is longer than 8:00–15:15. Only at
        // the ends — in the middle, the next module has the time.
        // Up to 2½ hours, so an evening doesn't make a block a screen tall.
        for i in plan.slots.indices where i == 0 || i == plan.slots.count - 1 {
            let slot = plan.slots[i]
            let items = slot.main + slot.continuing
            guard items.count == 1, let item = items.first,
                  let s = item.startMinutes, let e = item.endMinutes else { continue }
            if i == plan.slots.count - 1 {
                plan.slots[i].overrunAfter = min(max(0, e - slot.last.endMinutes), 150)
            }
            if i == 0 {
                plan.slots[i].overrunBefore = min(max(0, slot.module.startMinutes - s), 150)
            }
        }
        let hasLessons = plan.slots.contains { !$0.isFree }

        // 6. The notes. The ones that repeat what the day already shows go
        // ("1g: AP-eksamen" next to the exam itself, "1g: Læsedag" next to
        // the AP reading day — a lesson is matched by its topic, anything
        // else by its name, and the note must be the same thing or the
        // general word for it). What's left: a status when it says what
        // kind of day it is for you, a line at the bottom for an awareness
        // day, a chip for the rest.
        var onTheDay: [Lesson] = plan.before + plan.after
        onTheDay += plan.allDay + plan.also + plan.status
        for slot in plan.slots {
            onTheDay += slot.main + slot.continuing
            onTheDay += slot.cancelled + slot.breakAfter
            onTheDay += slot.alongside
        }
        let shown: [String] = onTheDay
            .map { Lesson.squashed($0.isClassLesson ? $0.title : $0.headline) }
            .filter { $0.count >= 4 }
        let shownKinds = Set(plan.slots.flatMap { $0.main + $0.continuing + $0.alongside }.compactMap(\.markKind))
        var chips: [Lesson] = []
        for note in notes {
            let name = Lesson.squashed(note.headline)
            let repeated = name.count >= 4 && shown.contains { other in
                other == name || (name.count >= 5 && other.contains(name))
            }
            guard !repeated, seenNames.insert(name).inserted else { continue }
            // Someone else's turn of a week-long thing (see
            // ScheduleWeek.rollingNotes) on a day you have your own.
            if rolling.contains(name) && hasLessons { continue }
            let kind = note.kind
            // Already said: a trip note next to your trip ("Pre-IB:
            // Introtur" beside the class's intro trip), a reading-day note
            // next to your reading day.
            if kind < .event, shownKinds.contains(kind) || plan.status.contains(where: { $0.kind == kind }) {
                continue
            }
            let forYou = note.isFor(className: className)
            if kind == .exam && forYou {
                // An exam of yours, even with lessons around it.
                plan.status.append(note)
            } else if !hasLessons && (kind == .noSchool || ((kind == .trip || kind == .readingDay) && forYou)) {
                // What the day is when there are no lessons of yours in it.
                plan.status.append(note)
            } else if kind == .observance {
                plan.observances.append(note)
            } else if kind != .staffOnly {
                chips.append(note)
            }
        }
        plan.allDay = chips + plan.allDay
        plan.status.sort { $0.kind < $1.kind }

        // Away all day — a trip, a day off — the school's optional things
        // aren't on for you.
        let awayInModules = !plan.slots.isEmpty && plan.slots.allSatisfy { slot in
            slot.main.count == 1 && slot.main[0].markKind == .trip && slot.main[0].dayShape == "all"
        }
        let awayAllDay = plan.slots.isEmpty
            && plan.status.contains(where: { $0.kind == .trip || $0.kind == .noSchool })
        if awayInModules || awayAllDay {
            plan.also = []
            plan.after = plan.after.filter { isYours($0) }
        }
        return plan
    }

    /// Which of two things of yours at the same time holds the module:
    /// the more important kind (exam, day off, trip, reading day, the rest),
    /// then the one that runs longer.
    private static func rank(_ item: Lesson) -> (Int, Int) {
        let kind = item.markKind?.rawValue ?? Lesson.Kind.event.rawValue
        let length = (item.endMinutes ?? 0) - (item.startMinutes ?? 0)
        return (kind, -length)
    }

    /// Where an all-day item goes on this day.
    enum Placement {
        /// It has hours here: placed like anything else.
        case timed(Lesson)
        /// A note for the day.
        case note(Lesson)
        /// Nothing on this day at all: the last day of something that
        /// ends at midnight ("Vinterferie 15/2 00:00 til 20/2 00:00").
        case skip
    }

    /// The hours an all-day item actually has. Days of something running
    /// over several days: "from 12:00" runs to the end of the school day,
    /// "until 11:00" from its start, and a day it fills — the days between,
    /// or one that starts at midnight — is the whole school day. Notes that
    /// write when into their name are placed there (see hoursInText).
    static func placement(of item: Lesson, dayStart: Int?, dayEnd: Int?,
                          modules: [ScheduleModule], className: String) -> Placement {
        let label = item.allDay ?? ""
        guard let dayStart, let dayEnd else { return .note(item) }

        // A whole school day of it: a block when it's yours (an exam over
        // several days, a trip), otherwise a plain note — "Vinterferie",
        // not "Vinterferie 08:00–15:15".
        let wholeDay: Placement
        if item.isFor(className: className) {
            var copy = DayPlan.timedCopy(item, from: dayStart, to: dayEnd, title: item.title)
            copy.dayShape = "all"
            wholeDay = .timed(copy)
        } else {
            var note = item
            note.allDay = ""
            wholeDay = .note(note)
        }

        if let g = Rx.match("^from (\\d{1,2}:\\d{2})$", label), let s = Lesson.minutes(from: g[1]) {
            if s <= dayStart { return wholeDay }
            var copy = DayPlan.timedCopy(item, from: s, to: s < dayEnd ? dayEnd : nil, title: item.title)
            copy.dayShape = "starts"
            return .timed(copy)
        }
        if let g = Rx.match("^until (\\d{1,2}:\\d{2})$", label), let e = Lesson.minutes(from: g[1]) {
            if e <= dayStart { return .skip }
            // A trip back at 16:00 is a whole day that runs a little long.
            if e > dayEnd, item.isFor(className: className) {
                var copy = DayPlan.timedCopy(item, from: dayStart, to: e, title: item.title)
                copy.dayShape = "all"
                return .timed(copy)
            }
            if e >= dayEnd { return wholeDay }
            var copy = DayPlan.timedCopy(item, from: dayStart, to: e, title: item.title)
            copy.dayShape = "ends"
            return .timed(copy)
        }
        if label == "all day" { return wholeDay }
        guard label.isEmpty else { return .note(item) }

        if let (start, end, cleaned) = hoursInText(item.title, modules: modules) {
            return .timed(DayPlan.timedCopy(item, from: start, to: end, title: cleaned))
        }
        return .note(item)
    }

    /// Hours a note writes into its name. Modules — "(4. modul)", "i
    /// 2.modul", "Koncert, 2. modul, sal", "3. og 4. modul", "(1.-2.
    /// modul)" — and clock ranges: "(13:40-15:00)", "8:00 - 13:30", "kl.
    /// 9-13". A single time ("kl 19", "klokken 12") is an evening or a
    /// deadline and stays a note, as does "efter 3. modul". The hours in
    /// brackets come out of the name.
    static func hoursInText(_ title: String, modules: [ScheduleModule]) -> (Int, Int, String)? {
        var start: Int?
        var end: Int?

        if let g = Rx.match("(?<!efter\\s)((?:\\d\\s*\\.\\s*(?:[-–/+,]|og)?\\s*)+)modul", title) {
            let numbers = g[1].compactMap { $0.wholeNumberValue }
            if let lo = numbers.min(), let hi = numbers.max(),
               let first = modules.first(where: { $0.number == lo }),
               let last = modules.first(where: { $0.number == hi }) {
                start = first.startMinutes
                end = last.endMinutes
            }
        }
        if start == nil {
            let patterns = [
                "(\\d{1,2})[:.](\\d{2})\\s*[-–]\\s*(\\d{1,2})[:.](\\d{2})",
                "\\bkl\\.?\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*[-–]\\s*(\\d{1,2})(?:[:.](\\d{2}))?",
            ]
            for pattern in patterns {
                guard let g = Rx.match(pattern, title),
                      let h1 = Int(g[1]), let h2 = Int(g[3]) else { continue }
                let m1 = Int(g[2]) ?? 0
                let m2 = Int(g[4]) ?? 0
                guard h1 < 24, h2 < 24, m1 < 60, m2 < 60, h2 * 60 + m2 > h1 * 60 + m1 else { continue }
                start = h1 * 60 + m1
                end = h2 * 60 + m2
                break
            }
        }
        guard let start, let end else { return nil }
        let cleaned = title.replacingOccurrences(
            of: "\\s*\\([^)]*(?:modul|\\d[:.]\\d{2}|kl\\.?\\s*\\d)[^)]*\\)", with: "",
            options: [.regularExpression, .caseInsensitive])
        return (start, end, cleaned)
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
