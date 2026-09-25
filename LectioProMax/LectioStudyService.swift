import Foundation

/// Lektier overview, absence, and looking up other people's timetables.
enum LectioStudyService {

    // MARK: - Lektier

    static func loadLessonNotes(cookies: [HTTPCookie]) async throws -> [LessonNote] {
        let html = try await LectioService.fetchHTML(
            LectioConfig.base + "/material_lektieoversigt.aspx", cookies: cookies)
        return LectioParser.parseLessonNotes(html)
    }

    /// Everything on a lesson's own page, including any pinned files.
    static func loadLessonDetail(link: String, cookies: [HTTPCookie]) async throws -> LessonDetail {
        let html = try await LectioService.fetchHTML(link, cookies: cookies)
        return LectioParser.parseLessonDetail(html)
    }

    /// The year's plan: every subject's units and the hours it expects of you.
    static func loadStudyPlan(cookies: [HTTPCookie]) async throws -> [StudyPlanSubject] {
        let html = try await LectioService.fetchHTML(
            LectioConfig.base + "/studieplan.aspx?displaytype=ugeteksttabel", cookies: cookies)
        return LectioParser.parseStudyPlan(html)
    }

    // MARK: - Absence

    struct Absence {
        var subjects: [AbsenceSubject] = []
        var records: [AbsenceRecord] = []

        var unexplained: [AbsenceRecord] { records.filter { $0.needsReason } }
        var total: AbsenceSubject? { subjects.first { $0.isTotal } }
    }

    static func loadAbsence(cookies: [HTTPCookie]) async throws -> Absence {
        async let overview = LectioService.fetchHTML(
            LectioConfig.base + "/subnav/fravaerelev.aspx", cookies: cookies)
        async let reasons = LectioService.fetchHTML(
            LectioConfig.base + "/subnav/fravaerelev_fravaersaarsager.aspx", cookies: cookies)

        var absence = Absence()
        absence.subjects = LectioParser.parseAbsenceSubjects(try await overview)
        absence.records = LectioParser.parseAbsenceRecords(try await reasons)
        return absence
    }

    /// The reasons Lectio offers a student. Read off the form rather than
    /// hard-coded, since a school can configure them.
    static func reasonOptions(at pageURL: String, cookies: [HTTPCookie]) async throws -> [String] {
        let html = try await LectioService.fetchHTML(pageURL, cookies: cookies)
        let root = HTMLDocument.parse(html)
        guard let select = root.firstWhere({
            $0.name == "select" && ($0.attr("name") ?? "").contains("StudentReasonDD")
        }) else { return [] }

        return select.all("option")
            .compactMap { $0.attr("value") }
            .filter { !$0.isEmpty }
    }

    /// Explains an absence: Lectio's own dropdown plus a free-text note.
    static func submitReason(pageURL: String,
                             reason: String,
                             comment: String,
                             cookies: [HTTPCookie]) async throws {
        let html = try await LectioService.fetchHTML(pageURL, cookies: cookies)
        var fields = LectioForms.fields(in: HTMLDocument.parse(html))
        fields["s$m$Content$Content$StudentReasonDD$dd"] = reason
        fields["s$m$Content$Content$cancelStudentNote$tb"] = comment

        _ = try await LectioForms.postBack(
            pageURL: pageURL,
            fields: fields,
            target: "s$m$Content$Content$savecancelapplyBtn$svbtn",
            argument: "",
            cookies: cookies)
    }

    // MARK: - Other people's schedules

    /// Everyone whose timetable can be looked up.
    ///
    /// People do NOT come from FindSkema: that page caps its listing at 200
    /// names, and the school has 1311 students. Lectio's own cached dropdowns —
    /// the ones behind the message composer's recipient search — carry the full
    /// list, and their keys ("S80637481515") are the schedule ids with a letter
    /// in front. Classes and rooms aren't in those dropdowns, and their
    /// FindSkema listings are complete, so those still come from there.
    static func loadScheduleTargets(cookies: [HTTPCookie]) async throws -> [ScheduleTarget] {
        var all: [ScheduleTarget] = []

        if let people = try? await LectioMessagesService.recipientDirectory(cookies: cookies) {
            for person in people {
                let numeric = String(person.id.dropFirst())
                guard !numeric.isEmpty, numeric.allSatisfy({ $0.isNumber }) else { continue }
                switch person.kind {
                case .student:
                    all.append(ScheduleTarget(name: person.name,
                                              url: LectioConfig.skemaURL + "?elevid=" + numeric,
                                              kind: .student))
                case .teacher:
                    all.append(ScheduleTarget(name: person.name,
                                              url: LectioConfig.skemaURL + "?laererid=" + numeric,
                                              kind: .teacher))
                default:
                    break   // hold and groups have no schedule URL of their own
                }
            }
        }

        // Your own subject teams, off your timetable — see parseSubjectTargets.
        if let schedule = try? await LectioService.fetchHTML(LectioConfig.skemaURL, cookies: cookies) {
            all.append(contentsOf: LectioParser.parseSubjectTargets(schedule))
        }

        for kind in [ScheduleTarget.Kind.klasse, ScheduleTarget.Kind.room] {
            let url = LectioConfig.base + "/FindSkema.aspx?type=" + kind.findSkemaType
            guard let html = try? await LectioService.fetchHTML(url, cookies: cookies) else { continue }
            all.append(contentsOf: LectioParser.parseScheduleTargets(html, kind: kind))
        }

        return all
    }

    /// One week of somebody else's timetable.
    static func loadWeek(for target: ScheduleTarget,
                         weekCode: String,
                         cookies: [HTTPCookie]) async throws -> ScheduleWeek {
        var url = target.url
        if !weekCode.isEmpty {
            url += (url.contains("?") ? "&" : "?") + "week=" + weekCode
        }
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        var week = LectioParser.parseSchedule(html).week
        if week.code.isEmpty { week.code = weekCode }
        return week
    }
}
