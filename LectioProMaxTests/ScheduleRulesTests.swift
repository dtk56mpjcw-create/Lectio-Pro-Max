import Foundation
import Testing
@testable import LectioProMax

/// The schedule's rules, checked against the real weeks they were built
/// from (1j at Nørre Gymnasium, autumn 2026): what's yours and what's
/// optional, exams over reading days, days that are one thing, multi-day
/// items, notes that repeat the day, the end of the school day, other
/// schools' class names, Danish time, and the absence tables.
///
/// Run with ⌘U. Each test builds a small Lectio page the way SkemaNy.aspx
/// writes it and reads it through the app's own parser, so a change to
/// the parser or the day's layout rules that breaks one of these days
/// shows up here before it shows up on a phone.
///
/// Serialized: the class-name rules are shared state (see ClassNames).
@Suite(.serialized)
struct ScheduleRulesTests {

    // MARK: - Building pages

    /// Nørre's modules, with the late one after school.
    static let moduleHTML = [
        "1. modul<br>8:00 - 9:35", "2. modul<br>9:50 - 11:25", "3. modul<br>11:55 - 13:30",
        "4. modul<br>13:40 - 15:15", "5. modul<br>15:20 - 16:55",
    ].map { "<div class='s2module-info'>\($0)</div>" }.joined()

    /// One schedule tile, its tooltip as Lectio writes it.
    static func tile(_ tooltip: String, cancelled: Bool = false) -> String {
        let escaped = tooltip
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return "<a class='s2skemabrik\(cancelled ? " s2cancelled" : "")' data-tooltip='\(escaped)'>x</a>"
    }

    static func week(_ tiles: [String]) -> ScheduleWeek {
        LectioParser.parseSchedule("<html><body>" + moduleHTML + tiles.joined() + "</body></html>").week
    }

    /// A day's plan with the school day's four modules.
    static func plan(_ date: String, in week: ScheduleWeek, className: String = "1j") -> DayPlan {
        let modules = (week.modules ?? []).filter { $0.number <= 4 }
        let day = week.days.first { $0.date == date }
            ?? ScheduleDay(date: date, label: "", lessons: [])
        return DayPlan.build(day, modules: modules, className: className)
    }

    static let firstYears = "Alle 1. STX-elever, Alle 1i-elever, Alle 1j-elever"
    static let wholeSchool = "Alle 1. IB-elever, Alle 1. STX-elever, Alle 2. IB-elever, Alle 2. STX-elever, Alle 3. STX-elever, Alle Pre-IB elever"

    // MARK: - Exam week (week 41)

    static let examWeek = week([
        tile("1g: Læsedag\n5/10-2026 Hele dagen"),
        tile("International læredag (UNESCO)\n5/10-2026 Hele dagen"),
        tile("Ændret!\nAP-læsedag\n5/10-2026 08:00 til 15:15\nHold: \(firstYears)"),
        tile("1g: AP-eksamen\n6/10-2026 Hele dagen"),
        tile("Ændret!\nMødetid AP prøve\n6/10-2026 07:40 til 08:00\nHold: Alle 1a-elever, Alle 1i-elever, Alle 1j-elever, Forlænget tid årgang 26-27\nLærere: KF, MI"),
        tile("Ændret!\nAP-eksamen\n6/10-2026 08:00 til 11:35\nHold: \(firstYears)\nLærere: KF, MI, MLo\nLokaler: 060, 061, 062, 063, 064, 114"),
        tile("Ændret!\nAp Eksamen\n6/10-2026 08:00 til 09:35\nHold: 1i ap la, 1j ap la\nLærere: AM, KF, LS, Mar, MI\nLokaler: 062, 064"),
        tile("Ændret!\nNV-læsedag\n6/10-2026 12:00 til 7/10-2026 15:15\nHold: \(firstYears)"),
        tile("1i, 1j: NV-eksamen\n7/10-2026 Hele dagen"),
        tile("1g: Læsedag\n7/10-2026 Hele dagen"),
        tile("Nørre Skriver (13:40-15:00)\n7/10-2026 Hele dagen"),
        tile("Frivillig drama\n7/10-2026 13:40 til 15:15\nHold: \(wholeSchool), Frivillig Drama\nLærer: Julie Skov Nikolajsen (JN)\nLokale: 050"),
        tile("MUN\n7/10-2026 13:45 til 15:15\nHold: MUN 26/27, MUN leadership\nLærere: Gr, Mar\nLokaler: 132, 134"),
        tile("Ændret!\nNV-eksamen\n8/10-2026 08:00 til 16:00\nHold: \(firstYears), Alle Biologi-lærer\nLærer: MJ"),
        tile("Efterårsferie\n10/10-2026 Hele dagen"),
    ])

    @Test func readingDayFillsTheDay() {
        let plan = Self.plan("2026-10-05", in: Self.examWeek)
        #expect(plan.slots.count == 1)
        #expect(plan.slots.first?.main.first?.headline == "AP-læsedag")
        #expect(plan.slots.first?.through?.number == 4)
        #expect(plan.slots.first?.main.first?.markKind == .readingDay)
        // "1g: Læsedag" repeats the block; the UNESCO day is a quiet note.
        #expect(!plan.allDay.contains { $0.headline == "Læsedag" })
        #expect(plan.observances.map(\.headline) == ["International læredag (UNESCO)"])
    }

    @Test func examThenReadingDay() {
        let plan = Self.plan("2026-10-06", in: Self.examWeek)
        #expect(plan.before.map(\.headline) == ["Mødetid AP prøve"])
        #expect(plan.before.first?.isExam == false)
        #expect(plan.slots.count == 2)

        // Your AP lesson and the year's AP exam are one block, in your rooms.
        let exam = plan.slots[0]
        #expect(exam.main.first?.headline == "AP-eksamen")
        #expect(exam.main.first?.room == "062, 064")
        #expect(exam.main.first?.markKind == .exam)
        #expect(exam.through?.number == 2)
        #expect(exam.hours.start == "08:00" && exam.hours.end == "11:35")

        // The reading day that starts at noon and goes on tomorrow.
        let reading = plan.slots[1]
        #expect(reading.main.first?.headline == "NV-læsedag")
        #expect(reading.main.first?.dayShape == "starts")
        #expect(reading.module.number == 3 && reading.through?.number == 4)
        #expect(reading.main.first?.spanNote(on: "2026-10-06") == "Day 1 of 2 · ends tomorrow")

        #expect(!plan.allDay.contains { $0.headline == "AP-eksamen" })
    }

    @Test func examOverReadingDay() {
        let plan = Self.plan("2026-10-07", in: Self.examWeek)
        #expect(plan.slots.count == 1)
        let block = plan.slots[0]
        // The "Hele dagen" exam note for 1i, 1j is the day; the reading day
        // is noted inside it.
        #expect(block.main.first?.headline == "NV-eksamen")
        #expect(block.main.first?.dayShape == "all")
        #expect(block.through?.number == 4)
        #expect(block.alongside.map(\.headline) == ["NV-læsedag"])
        // Optional things are listed, not blocks.
        let also = Set(plan.also.map(\.headline))
        #expect(also.isSuperset(of: ["Frivillig drama", "MUN", "Nørre Skriver"]))
        #expect(!plan.allDay.contains { $0.headline == "Læsedag" })
    }

    @Test func examRunsPastTheSchoolDay() {
        let plan = Self.plan("2026-10-08", in: Self.examWeek)
        #expect(plan.slots.count == 1)
        #expect(plan.slots[0].main.first?.headline == "NV-eksamen")
        #expect(plan.slots[0].through?.number == 4)
        // 16:00 is 45 minutes past module 4's end: the block grows by it.
        #expect(plan.slots[0].overrunAfter == 45)
        #expect(plan.slots[0].hours.end == "16:00")
    }

    @Test func holidayIsTheDay() {
        let plan = Self.plan("2026-10-10", in: Self.examWeek)
        #expect(plan.slots.isEmpty)
        #expect(plan.status.first?.headline == "Efterårsferie")
        #expect(plan.status.first?.kind == .noSchool)
    }

    // MARK: - Over several days (week 36)

    static let tripWeek = week([
        tile("Pre-IB intro trip\n2/9-2026 08:00 til 3/9-2026 16:00\nHold: Alle 1j-elever\nLærere: KB, AB, CD, EF"),
        tile("1g: Læsescreening\n4/9-2026 Hele dagen"),
    ])

    /// As Calendar shows it: the first day starts at 8:00 and runs on past
    /// the day — no end time today — and the second comes from yesterday
    /// and ends at 16:00, a little past the school day.
    @Test func tripOverTwoDays() {
        let first = Self.plan("2026-09-02", in: Self.tripWeek)
        #expect(first.slots.first?.main.first?.dayShape == "starts")
        #expect(first.slots.first?.hours.start == "08:00")
        #expect(first.slots.first?.main.first?.spanNote(on: "2026-09-02") == "Day 1 of 2 · ends tomorrow")

        let second = Self.plan("2026-09-03", in: Self.tripWeek)
        #expect(second.slots.first?.main.first?.dayShape == "ends")
        #expect(second.slots.first?.hours.end == "16:00")
        #expect(second.slots.first?.overrunAfter == 45)
        #expect(second.slots.first?.main.first?.spanNote(on: "2026-09-03") == "Day 2 of 2 · ends 16:00")
    }

    /// "1g" is Lectio's short for every first year: in a first year's own
    /// schedule it says nothing, so it isn't shown.
    @Test func ownYearIsntSpelledOut() {
        ClassNames.use("1j")
        #expect(Lesson(title: "1g: Læsescreening").audienceNote == nil)
        #expect(Lesson(title: "1i, 1j: NV-eksamen").audienceNote == nil)
        #expect(Lesson(title: "2g: Terminsprøver").audienceNote == "2nd years")
        #expect(Lesson(title: "3m, 1i: Tidying up the Foyer").audienceNote == "3m, 1i")
    }

    // MARK: - An ordinary day (Wednesday, week 38)

    static let ordinaryWeek = week([
        tile("Aflyst!\nSpansk\n16/9-2026 08:00 til 09:35\nHold: 1j SP 2\nLærer: Ana Garcia (AG)\nLokale: 062", cancelled: true),
        tile("Intro to history 5\n16/9-2026 09:50 til 11:25\nHold: 1j hi\nLærer: Christian Egholm Hattens (Chr)\nLokale: 064"),
        tile("Cells\n16/9-2026 11:55 til 13:30\nHold: 1j nv\nLærer: Jakob Damgaard (Ja)\nLokale: 012"),
        tile("Frivillig billedkunst &amp; design\n16/9-2026 13:40 til 15:15\nHold: Alle 1. STX-elever, Alle 2. STX-elever, Alle 2i-elever, Alle 3. STX-elever\nLokale: 002"),
        tile("Aflyst!\nFrivillig drama AFLYST\n16/9-2026 13:40 til 15:15\nHold: \(wholeSchool)", cancelled: true),
        tile("MUN\n16/9-2026 13:45 til 15:15\nHold: MUN 26/27, MUN leadership"),
        tile("1g og pre-IB: AP-stjerneløb\n16/9-2026 Hele dagen"),
    ])

    @Test func ordinaryDay() {
        let plan = Self.plan("2026-09-16", in: Self.ordinaryWeek)
        // Free (Spanish cancelled), History, Science; module 4 has only
        // optional things, so the day ends after 3.
        #expect(plan.slots.count == 3)
        #expect(plan.slots[0].isFree)
        #expect(plan.slots[0].cancelled.first?.headline == "Spanish")
        #expect(plan.slots[1].main.first?.headline == "History")
        #expect(plan.slots[2].main.first?.headline == "Science (NV)")

        let also = plan.also.map(\.headline)
        #expect(also.contains("Frivillig billedkunst & design"))   // "&amp;" decoded
        #expect(also.contains("MUN"))
        #expect(plan.allDay.map(\.headline) == ["AP-stjerneløb"])
    }

    // MARK: - The end of the school day

    @Test func lateModuleIsAfterSchool() {
        var tiles: [String] = []
        let days = ["21/9", "22/9", "23/9", "24/9", "25/9"]
        let modules = [("08:00", "09:35"), ("09:50", "11:25"), ("11:55", "13:30"), ("13:40", "15:15")]
        for day in days {
            for (n, m) in modules.enumerated() {
                tiles.append(Self.tile("Lesson \(n + 1)\n\(day)-2026 \(m.0) til \(m.1)\nHold: 1j ma"))
            }
        }
        // The maths study hall, once a week in the late module.
        tiles.append(Self.tile("Math Study Hall\n21/9-2026 15:20 til 16:10\nHold: 1j ma"))
        let week = Self.week(tiles)

        #expect(week.dayModules.map(\.number) == [1, 2, 3, 4])
        let day = week.days.first { $0.date == "2026-09-21" }!
        let plan = DayPlan.build(day, modules: week.dayModules, className: "1j")
        #expect(plan.slots.count == 4)
        #expect(plan.after.first?.topic == "Math Study Hall")
    }

    // MARK: - Words

    @Test func kindsOfThings() {
        #expect(Lesson(title: "AP-eksamen").kind == .exam)
        #expect(Lesson(title: "2g: Terminsprøver").kind == .exam)
        #expect(Lesson(title: "Mødetid AP prøve").kind != .exam)
        #expect(Lesson(title: "Test af brandalarm").kind != .exam)
        #expect(Lesson(title: "Delvis offentliggørelse af eksamensplan").kind != .exam)
        #expect(Lesson(title: "NV-læsedag").kind == .readingDay)
        #expect(Lesson(title: "Pre-IB intro trip").kind == .trip)
        #expect(Lesson(title: "Efterårsferie").kind == .noSchool)
        #expect(Lesson(title: "Autumn break").kind == .noSchool)
        #expect(Lesson(title: "Verdensdag for Vand").kind == .observance)
        #expect(Lesson(title: "Personalemøde").kind == .staffOnly)
        // A lesson's topic that says "test" is still a lesson.
        #expect(Lesson(code: "ap la", title: "Practice test", team: "1j ap la").isExam == false)
    }

    @Test func whoseItIs() {
        let readingDay = Lesson(title: "AP-læsedag", team: Self.firstYears)
        #expect(readingDay.isFor(className: "1j"))
        // 1x isn't named, but every year group named is theirs.
        #expect(readingDay.isFor(className: "1x"))
        #expect(!readingDay.isFor(className: "2b"))
        // Open to the whole school: optional.
        #expect(!Lesson(title: "Danseaudition", team: Self.wholeSchool).isFor(className: "1j"))
        #expect(!Lesson(title: "Frivillig drama", team: "Alle 1j-elever").isFor(className: "1j"))
        #expect(Lesson(title: "1i, 1j: NV-eksamen").isFor(className: "1j"))
        #expect(!Lesson(title: "1i, 1j: NV-eksamen").isFor(className: "1x"))
    }

    // MARK: - Over several days

    @Test func dayOfHowMany() {
        let trip = Lesson(title: "Pre-IB intro trip", team: "1i kl, 1j kl",
                          span: "2026-09-02 08:00|2026-09-03 16:00")
        // An end time only on the day it ends: on the first it read as
        // ending that day.
        #expect(trip.spanNote(on: "2026-09-02") == "Day 1 of 2 · ends tomorrow")
        #expect(trip.spanNote(on: "2026-09-03") == "Day 2 of 2 · ends 16:00")
        // Midnight to midnight: the last day is the day before.
        let holiday = Lesson(title: "Vinterferie", span: "2027-02-15 00:00|2027-02-20 00:00")
        #expect(holiday.spanNote(on: "2027-02-15") == "Day 1 of 5 · ends Fri")
        #expect(holiday.spanNote(on: "2027-02-19") == "Day 5 of 5")
        #expect(holiday.spanNote(on: "2027-02-20") == nil)
    }

    // MARK: - Other schools

    @Test func classNamesWrittenOtherWays() {
        defer { ClassNames.use("1j") }

        ClassNames.use("1.a")
        #expect(Lesson(code: "da", title: "x", team: "1.a da").isClassLesson)
        #expect(!Lesson(code: "", title: "MUN", team: "MUN leadership").isClassLesson)

        ClassNames.use("HF1b")
        #expect(Lesson(code: "en", title: "x", team: "HF1b en").isClassLesson)
        #expect(ClassNames.year(of: "HF1b") == "1")

        // The usual kind always counts.
        ClassNames.use("1j")
        #expect(Lesson(code: "ma", title: "x", team: "1j ma").isClassLesson)
        #expect(Lesson(code: "ap la", title: "x", team: "1i ap la, 1j ap la").isClassLesson)
    }

    @Test func subjectsBesideAnyClassName() {
        // A word with a digit is a class, wherever it is and however it's
        // written; the subject is the first word without one.
        #expect(SubjectPalette.subjectKey("HF1b en") == "en")
        #expect(SubjectPalette.subjectKey("2.a Ma A") == "ma")
        #expect(SubjectPalette.subjectKey("IB1 Math HL") == "ma")
        #expect(SubjectPalette.subjectKey("1j SP 2") == "sp")
        #expect(SubjectPalette.subjectKey("25a fy") == "fy")
    }

    @Test func yourClassLaterInTheTeam() {
        defer { ClassNames.use("1j") }

        ClassNames.use("3.b")
        // Written subject first, or with a year in front: still yours.
        #expect(Lesson(code: "Ma A", title: "x", team: "Ma A 3.b").isClassLesson)
        #expect(Lesson(code: "Ma A", title: "x", team: "Ma A 3.b").subjectName == "Maths")
        ClassNames.use("1a")
        #expect(Lesson(code: "MA", title: "x", team: "2021-1a MA").isClassLesson)
        // Only your own class, and only beside a subject: another class's
        // lesson, and a trip named after yours, stay what they were.
        #expect(!Lesson(code: "Ma A", title: "x", team: "Ma A 3.b").isClassLesson)
        #expect(!Lesson(code: "", title: "Studietur", team: "Studietur 1a").isClassLesson)
    }

    @Test func apLatinIsItsOwnSubject() {
        // AP's Latin part, not the whole of AP, wherever the name is shown.
        #expect(Lesson(code: "ap la", title: "x", team: "1i ap la, 1j ap la").subjectName == "AP Latin")
        #expect(SubjectPalette.subjectKey("1j ap la") == "ap la")
        #expect(SubjectPalette.subjectKey("ap la, 1j ap la") == "ap la")
        // AP on its own, as some schools teach it, stays AP.
        #expect(SubjectPalette.subjectKey("1a ap") == "ap")
        #expect(SubjectNames.name(forKey: "ap") == "General linguistics (AP)")
        // Latin itself is still Latin.
        #expect(SubjectPalette.subjectKey("3b la") == "la")
    }

    @Test func classesNamedByTheYearTheyStarted() throws {
        let autumn = try #require(ISO8601DateFormatter().date(from: "2026-09-18T10:00:00Z"))
        let spring = try #require(ISO8601DateFormatter().date(from: "2027-03-01T10:00:00Z"))
        // A year and letters: the first digit.
        #expect(ClassNames.year(of: "1j", now: autumn) == "1")
        #expect(ClassNames.year(of: "3.g", now: autumn) == "3")
        #expect(ClassNames.year(of: "HF2b", now: autumn) == "2")
        // Started in 2025: a 2nd year all through 2026/27.
        #expect(ClassNames.year(of: "25a", now: autumn) == "2")
        #expect(ClassNames.year(of: "25a", now: spring) == "2")
        #expect(ClassNames.year(of: "2026x", now: autumn) == "1")
        // Not a year anyone could have started in: the first digit again.
        #expect(ClassNames.year(of: "10b", now: autumn) == "1")
    }

    @Test func studentsWithoutAClass() {
        defer { ClassNames.use(Profile(className: "1j", isStudent: true)) }

        ClassNames.use(Profile(className: "", isStudent: true))
        #expect(ClassNames.isClassless)
        // Their teams are their subjects.
        #expect(Lesson(code: "da", title: "x", team: "Dansk C 2526-01").isClassLesson)
        // Not the whole school, and not something voluntary.
        #expect(!Lesson(code: "", title: "Temadag", team: "Alle kursister").isClassLesson)
        #expect(!Lesson(code: "", title: "Kor", team: "Frivillig kor").isClassLesson)

        // With a class, only its teams are lessons again.
        ClassNames.use(Profile(className: "1j", isStudent: true))
        #expect(!ClassNames.isClassless)
        #expect(!Lesson(code: "da", title: "x", team: "Dansk C 2526-01").isClassLesson)
        #expect(Lesson(code: "ma", title: "x", team: "1j ma").isClassLesson)

        // A teacher has no class either, but isn't a student.
        ClassNames.use(Profile(name: "Bo Berg", isStudent: false))
        #expect(!ClassNames.isClassless)
    }

    @Test func whoTheProfileIs() {
        func page(_ title: String) -> String {
            "<html><body><div id='s_m_HeaderContent_MainTitle'>\(title)</div></body></html>"
        }
        let pupil = LectioParser.parseProfile(page("Eleven Ivan Surov, 1j - Skema"))
        #expect(pupil.name == "Ivan Surov")
        #expect(pupil.className == "1j")
        #expect(pupil.isStudent == true)

        let adult = LectioParser.parseProfile(page("Kursisten Anna Hansen - Skema"))
        #expect(adult.name == "Anna Hansen")
        #expect(adult.className.isEmpty)
        #expect(adult.isStudent == true)

        let hf = LectioParser.parseProfile(page("Kursisten Anna Hansen, HF1b - Skema"))
        #expect(hf.className == "HF1b")

        let teacher = LectioParser.parseProfile(page("Læreren Bo Berg - Skema"))
        #expect(teacher.isStudent == false)
    }

    @Test func eachThingOnceBeforeAndAfterSchool() {
        // The same study café for two year groups: two tiles, one row.
        let first = Lesson(start: "15:30", end: "17:00", code: "", title: "Studiecafé", room: "Kantinen",
                           team: "Alle 1. STX-elever")
        var second = first
        second.team = "Alle 2. STX-elever"
        let day = ScheduleDay(date: "2026-09-29", label: "", lessons: [first, second])
        let modules = [ScheduleModule(number: 1, start: "08:00", end: "09:35")]
        let plan = DayPlan.build(day, modules: modules, className: "1j")
        #expect(plan.after.count == 1)
    }

    // MARK: - Danish time

    @Test func todayIsDanish() throws {
        // 23:30 in London on 5 October is already the 6th in Copenhagen.
        let late = try #require(ISO8601DateFormatter().date(from: "2026-10-05T23:30:00Z"))
        #expect(LectioDates.isoString(from: late) == "2026-10-06")
    }

    // MARK: - Parsing

    @Test func theReplyBoxIsntAMessage() {
        let html = """
        <html><body>
        <div class='message-thread-message-sender'>Ivan Surov (1j 12), 25-09-2026 20:54:13</div>
        <div class='message-thread-message'>
          <div class='message-thread-message-header'>Idk</div>
          <div class='message-thread-message-content'>Yo</div>
        </div>
        <div class='message-thread-message'>
          <textarea name='s$m$Content$Content$MessageThreadCtrl$MessagesGV$ctl03$EditModeContentBBTB$TbxNAME$tb'></textarea>
          <span>Vis</span><span>Hjælp</span><span>Teksten må maksimalt være 100000 tegn lang</span>
        </div>
        </body></html>
        """
        let thread = LectioParser.parseThread(html, id: "1", pageURL: "")
        #expect(thread.messages.count == 1)
        #expect(thread.messages.first?.body == "Yo")
        #expect(thread.messages.first?.sender == "Ivan Surov (1j 12)")
        // The reply box is still found, for replying.
        #expect(thread.canReply)
    }

    @Test func aLessonNoteKeepsItsLines() {
        let html = "<textarea name='s$m$Content$Content$ActNoteTB$tb' disabled>\r\nRead p. 12\r\nBring a calculator</textarea>"
        #expect(LectioParser.parseLessonDetail(html).note == "Read p. 12\r\nBring a calculator")
    }

    @Test func tooltipDetailByLabel() {
        let t = LectioParser.parseTooltip(
            "Estados Unidos\n30/9-2026 08:00 til 09:35\nHold: 1j SP 2\nLærer: KM\nLokale: 130\n\n"
            + "Lektier:\n- Practise the dialogue\nØvrigt indhold:\n- Quizlet\nNote:\nI am back this week")
        #expect(t.homework == "- Practise the dialogue")
        #expect(t.note == "I am back this week")
        // Other content on its own is neither homework nor a note.
        let other = LectioParser.parseTooltip(
            "Estados Unidos\n30/9-2026 08:00 til 09:35\nHold: 1j SP 2\n\nØvrigt indhold:\n- Quizlet")
        #expect(other.homework.isEmpty)
        #expect(other.note.isEmpty)
        // No label at all: the detail is the note, as before.
        let plain = LectioParser.parseTooltip(
            "Estados Unidos\n30/9-2026 08:00 til 09:35\nHold: 1j SP 2\n\nBring the book")
        #expect(plain.note == "Bring the book")
    }

    @Test func tooltip() {
        let t = LectioParser.parseTooltip(
            "Ændret!\nAp Eksamen\n6/10-2026 08:00 til 09:35\nHold: 1i ap la, 1j ap la\nLærere: AM, KF, LS\nLokaler: 062, 064")
        #expect(t.changed)
        #expect(t.title == "Ap Eksamen")
        #expect(t.date == "2026-10-06")
        #expect(t.start == "08:00" && t.end == "09:35")
        #expect(t.room == "062, 064")
        #expect(t.teacherInitials == "AM, KF, LS")

        let multi = LectioParser.parseTooltip("NV-læsedag\n6/10-2026 12:00 til 7/10-2026 15:15\nHold: 1j")
        #expect(multi.endDate == "2026-10-07")
        #expect(multi.start == "12:00" && multi.end == "15:15")
    }

    @Test func absenceTables() {
        let brik = { (date: String) in
            "<a class='s2skemabrik' data-tooltip='\(date) 08:00 til 09:35\nHold: 1j nv\nLærer: Jakob Damgaard (Ja)\nLokale: 012'>"
            + "<span class='ls-fonticon'>sms</span><span class='ls-fonticon'>bookmark</span>"
            + "<div class='OnlyDesktop'>ti 15/9 1. modul - 1j nv</div></a>"
        }
        let html = """
        <table id='s_m_Content_Content_FatabMissingAarsagerGV'>
          <tr><th class='OnlyDesktop'>Uge</th><th>Aktivitet</th><th class='OnlyDesktop'>Fravær</th>
              <th class='OnlyDesktop'>Bemærkning</th><th class='OnlyMobile'>Fravær</th><th class='OnlyDesktop'></th></tr>
          <tr><td class='OnlyDesktop'>38</td><td>\(brik("15/9-2026"))</td><td class='OnlyDesktop'>Fravær 50%</td>
              <td class='OnlyDesktop'></td><td class='OnlyMobile'>50%</td>
              <td class='OnlyDesktop'><a href='/lectio/21/fravaer_aarsag.aspx?id=1'><span class='ls-fonticon'>edit</span></a></td></tr>
        </table>
        <table id='s_m_Content_Content_FatabAbsenceFravaerGV'>
          <tr><th class='OnlyDesktop'>Uge</th><th>Aktivitet</th><th class='OnlyDesktop'>Fravær</th>
              <th class='OnlyDesktop'>Registreret</th><th class='OnlyDesktop'>Bemærkning</th>
              <th class='OnlyDesktop'>Fraværsårsag<br>Kommentar</th><th class='OnlyMobile'>Fravær</th><th class='OnlyDesktop'></th></tr>
          <tr><td class='OnlyDesktop'>38</td><td>\(brik("16/9-2026"))</td><td class='OnlyDesktop'>Fravær 100%</td>
              <td class='OnlyDesktop'><span>16/9-2026</span> Chr</td><td class='OnlyDesktop'></td>
              <td class='OnlyDesktop'> Andet<br> I was like 5 minutes late<br> </td>
              <td class='OnlyMobile'>100% Andet</td>
              <td class='OnlyDesktop'><a href='/lectio/21/fravaer_aarsag.aspx?id=2'>edit</a></td></tr>
        </table>
        """
        let records = LectioParser.parseAbsenceRecords(html)
        let missing = records.first { $0.needsReason }
        let registered = records.first { !$0.needsReason }
        #expect(missing?.percent == "50%")
        #expect(missing?.module == "Module 1")
        #expect(registered?.percent == "100%")
        #expect(registered?.reason == "Andet")
        #expect(registered?.comment == "I was like 5 minutes late")
        #expect(registered?.registered.hasPrefix("16/9-2026") == true)
    }

    /// Changing an absence's reason sends the comment box as it stands, so
    /// the form has to open with the comment already given.
    @Test func anAbsenceFormOpensWithWhatWasGiven() {
        let html = """
        <form id='aspnetForm'>
          <select name='s$m$Content$Content$StudentReasonDD$dd'>
            <option value=''></option><option value='Sygdom'>Sygdom</option>
            <option selected='selected' value='Andet'>Andet</option>
          </select>
          <textarea name='s$m$Content$Content$cancelStudentNote$tb'>\r\nI was like 5 minutes late</textarea>
        </form>
        """
        let form = LectioStudyService.parseReasonForm(HTMLDocument.parse(html))
        #expect(form.options == ["Sygdom", "Andet"])
        #expect(form.reason == "Andet")
        #expect(form.comment == "I was like 5 minutes late")
    }
}
