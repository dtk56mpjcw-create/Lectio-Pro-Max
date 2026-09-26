import Foundation
import Testing
@testable import LectioProMax

/// What the background check announces, what the widgets show, and when
/// iOS is asked to wake the app. Run with ⌘U.
///
/// Serialized: the class-name rules are shared state (see ClassNames).
@Suite(.serialized)
struct NotificationRulesTests {

    /// Tuesday 29 September 2026, 10:00 in Denmark.
    static let now = LectioDates.moment(iso: "2026-09-29", time: "10:00")!

    static func lesson(_ id: Int, _ start: String, _ end: String, code: String = "ma",
                       room: String = "062", teacher: String = "AM", cancelled: Bool = false) -> Lesson {
        Lesson(start: start, end: end, code: code, title: "Topic \(id)", teacher: teacher, room: room,
               cancelled: cancelled,
               link: "https://www.lectio.dk/lectio/21/aktivitet/aktivitetforside2.aspx?absid=\(id)&prevurl=SkemaNy.aspx",
               team: "1j \(code)")
    }

    static func snapshot(_ days: [String: [Lesson]]) -> LectioSnapshot {
        var snapshot = LectioSnapshot()
        snapshot.profile.className = "1j"
        snapshot.profile.name = "Ivan Surov"
        for (iso, lessons) in days {
            let code = LectioDates.weekCode(iso: iso)
            var week = snapshot.weeks[code] ?? ScheduleWeek(code: code)
            week.days.append(ScheduleDay(date: iso, lessons: lessons))
            snapshot.weeks[code] = week
        }
        return snapshot
    }

    // MARK: - Schedule changes

    @Test func scheduleChanges() {
        let before = Self.snapshot([
            "2026-09-29": [Self.lesson(1, "08:00", "09:35"),
                           Self.lesson(2, "09:50", "11:25", code: "da"),
                           Self.lesson(3, "11:55", "13:30", code: "en")],
            "2026-09-30": [Self.lesson(4, "08:00", "09:35")],
        ])
        // The first look only takes note.
        let first = ScheduleWatch.review(before, against: .init(), now: Self.now)
        #expect(first.alerts.isEmpty)
        #expect(first.record.days.keys.sorted() == ["2026-09-29", "2026-09-30"])

        let after = Self.snapshot([
            // Lesson 1 is over: its new room is old news.
            "2026-09-29": [Self.lesson(1, "08:00", "09:35", room: "114"),
                           Self.lesson(2, "09:50", "11:25", code: "da", room: "114"),
                           Self.lesson(3, "11:55", "13:30", code: "en", cancelled: true)],
            "2026-09-30": [Self.lesson(4, "12:00", "13:30"),
                           Self.lesson(5, "13:40", "15:15", code: "hi")],
        ])
        let second = ScheduleWatch.review(after, against: first.record, now: Self.now)
        #expect(second.alerts.map(\.title) == ["Room change: Danish", "English cancelled",
                                               "Maths moved", "Added: History"])
        #expect(second.alerts[0].body == "Today, 9:50–11:25 · now 114 (was 062)")
        #expect(second.alerts[2].body == "Tomorrow, now 12:00–13:30 (was 8:00–9:35)")

        // Seen now: nothing more to say.
        let third = ScheduleWatch.review(after, against: second.record, now: Self.now)
        #expect(third.alerts.isEmpty)
    }

    @Test func aWeekNotLoadedKeepsWhatWasSeen() {
        // Friday: the next school day is Monday, in next week.
        let friday = LectioDates.moment(iso: "2026-10-02", time: "12:00")!
        #expect(ScheduleWatch.watchedDays(now: friday) == ["2026-10-02", "2026-10-05"])

        let seen = ScheduleWatch.review(
            Self.snapshot(["2026-10-02": [], "2026-10-05": [Self.lesson(7, "08:00", "09:35")]]),
            against: .init(), now: friday).record
        // A check that only got this week: Monday isn't taken to be empty.
        let later = ScheduleWatch.review(Self.snapshot(["2026-10-02": []]), against: seen, now: friday)
        #expect(later.alerts.isEmpty)
        #expect(later.record.days["2026-10-05"] == seen.days["2026-10-05"])
    }

    // MARK: - Messages and homework

    @Test func newMessagesAndHomework() {
        var snapshot = Self.snapshot([:])
        snapshot.messages = [MessagePreview(subject: "Tur", sender: "Anna Holm",
                                            link: "https://www.lectio.dk/lectio/21/beskeder2.aspx?type=visbesked&id=100")]
        snapshot.homework = [HomeworkItem(code: "ma", title: "Read p. 4", due: "2026-09-30")]
        let first = ScheduleWatch.review(snapshot, against: .init(), now: Self.now)
        #expect(first.alerts.isEmpty)

        snapshot.messages.insert(MessagePreview(subject: "Re: Tur", sender: "Ivan Surov (1j 12)",
                                                link: "https://www.lectio.dk/lectio/21/beskeder2.aspx?type=visbesked&id=101"), at: 0)
        snapshot.messages.insert(MessagePreview(subject: "Kantinen", sender: "Kontoret",
                                                link: "https://www.lectio.dk/lectio/21/beskeder2.aspx?type=visbesked&id=102"), at: 0)
        snapshot.assignments = [AssignmentItem(code: "en", title: "Essay", due: "2026-10-05", dueTime: "23:59")]
        snapshot.homework.append(HomeworkItem(code: "da", title: "Old", due: "2026-09-20"))

        let second = ScheduleWatch.review(snapshot, against: first.record, now: Self.now)
        // Your own reply isn't news; nor is homework that's already past.
        #expect(second.alerts.map(\.title) == ["Kontoret", "New assignment"])
        #expect(second.alerts[1].subtitle == "English")
        #expect(second.alerts[1].body == "Essay · due Mon 5 Oct at 23:59")
    }

    // MARK: - Widgets

    @MainActor @Test func widgetFeed() {
        var tiles: [String] = []
        let modules = [("08:00", "09:35"), ("09:50", "11:25"), ("11:55", "13:30"), ("13:40", "15:15")]
        for day in ["28/9", "29/9", "30/9", "1/10", "2/10"] {
            for (n, m) in modules.enumerated() {
                tiles.append(ScheduleRulesTests.tile("Lesson \(n + 1)\n\(day)-2026 \(m.0) til \(m.1)\nHold: 1j ma\nLokale: 06\(n)"))
            }
        }
        tiles.append(ScheduleRulesTests.tile("Math Study Hall\n29/9-2026 15:20 til 16:10\nHold: 1j ma"))
        var snapshot = LectioSnapshot()
        snapshot.profile.className = "1j"
        snapshot.weeks[LectioDates.weekCode(iso: "2026-09-29")] = ScheduleRulesTests.week(tiles)

        let feed = WidgetFeedBuilder.build(from: snapshot, now: Self.now)
        // Today to Friday; Monday's week isn't loaded, so it isn't guessed.
        #expect(feed.days.map(\.date) == ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"])
        let today = feed.days[0]
        #expect(today.items.count == 5)
        #expect(today.items.last?.optional == true)
        #expect(today.items[0].title == "Maths")
        #expect(today.items[0].room == "060")
        #expect(today.items[0].colour == SubjectPalette.choice(forKey: "ma").rawValue)

        #expect(feed.current(at: Self.now)?.topic == "Lesson 2")
        #expect(feed.next(after: Self.now)?.topic == "Lesson 3")
        #expect(feed.next(after: Self.now)?.start == LectioDates.moment(iso: "2026-09-29", time: "11:55"))

        // After the last lesson the study hall doesn't hold the day:
        // tomorrow is next.
        let afterSchool = LectioDates.moment(iso: "2026-09-29", time: "15:30")!
        #expect(feed.day(at: afterSchool)?.date == "2026-09-30")
        #expect(feed.next(after: afterSchool)?.start == LectioDates.moment(iso: "2026-09-30", time: "08:00"))
        #expect(feed.moments(after: Self.now).first == LectioDates.moment(iso: "2026-09-29", time: "11:25"))
    }

    // MARK: - Waking up

    @MainActor @Test func backgroundTiming() {
        #expect(BackgroundCheck.nextRun(after: Self.now) == Self.now.addingTimeInterval(20 * 60))
        let evening = LectioDates.moment(iso: "2026-09-29", time: "19:00")!
        #expect(BackgroundCheck.nextRun(after: evening) == evening.addingTimeInterval(60 * 60))
        let late = LectioDates.moment(iso: "2026-09-29", time: "23:10")!
        #expect(BackgroundCheck.nextRun(after: late) == LectioDates.moment(iso: "2026-09-30", time: "06:30"))
        let early = LectioDates.moment(iso: "2026-09-30", time: "04:00")!
        #expect(BackgroundCheck.nextRun(after: early) == LectioDates.moment(iso: "2026-09-30", time: "06:30"))
    }
}
