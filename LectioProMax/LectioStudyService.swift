import Foundation

/// Lektier overview, absence, and looking up other people's timetables.
enum LectioStudyService {

    // MARK: - Lektier

    @concurrent static func loadLessonNotes(cookies: [HTTPCookie]) async throws -> [LessonNote] {
        let html = try await LectioService.fetchHTML(
            LectioConfig.base + "/material_lektieoversigt.aspx", cookies: cookies)
        return LectioParser.parseLessonNotes(html)
    }

    /// Everything on a lesson's own page, including any pinned files.
    @concurrent static func loadLessonDetail(link: String, cookies: [HTTPCookie]) async throws -> LessonDetail {
        let html = try await LectioService.fetchHTML(link, cookies: cookies)
        // The page's own address, for the addresses in it that are relative.
        return LectioParser.parseLessonDetail(html, pageURL: link)
    }

    /// The year's plan: every subject's units and the hours it expects of you.
    @concurrent static func loadStudyPlan(cookies: [HTTPCookie]) async throws -> [StudyPlanSubject] {
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

    @concurrent static func loadAbsence(cookies: [HTTPCookie]) async throws -> Absence {
        async let overview = LectioService.fetchHTML(
            LectioConfig.base + "/subnav/fravaerelev.aspx", cookies: cookies)
        async let reasons = LectioService.fetchHTML(
            LectioConfig.base + "/subnav/fravaerelev_fravaersaarsager.aspx", cookies: cookies)

        var absence = Absence()
        absence.subjects = LectioParser.parseAbsenceSubjects(try await overview)
        absence.records = LectioParser.parseAbsenceRecords(try await reasons)
        return absence
    }

    /// Lectio's form for one absence: the reasons it offers (read off the
    /// form rather than hard-coded, since a school can configure them), and
    /// the reason and comment already given.
    struct ReasonForm {
        var options: [String] = []
        var reason: String = ""
        var comment: String = ""
    }

    static let reasonField = "s$m$Content$Content$StudentReasonDD$dd"
    static let commentField = "s$m$Content$Content$cancelStudentNote$tb"

    @concurrent static func reasonForm(at pageURL: String, cookies: [HTTPCookie]) async throws -> ReasonForm {
        let html = try await LectioService.fetchHTML(pageURL, cookies: cookies)
        return parseReasonForm(HTMLDocument.parse(html))
    }

    static func parseReasonForm(_ root: HTMLNode) -> ReasonForm {
        var form = ReasonForm()
        if let select = root.firstWhere({
            $0.name == "select" && ($0.attr("name") ?? "").contains("StudentReasonDD")
        }) {
            let options = select.all("option")
            form.options = options.compactMap { $0.attr("value") }.filter { !$0.isEmpty }
            // The one Lectio marks as chosen, if any. An absence without a
            // reason shows the first on the list, which isn't a choice.
            form.reason = options.first { $0.attrs["selected"] != nil }?.attr("value") ?? ""
        }
        form.comment = (LectioForms.fields(in: root)[commentField] ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        return form
    }

    /// Explains an absence: Lectio's own dropdown plus a free-text note.
    @concurrent static func submitReason(pageURL: String,
                             reason: String,
                             comment: String,
                             cookies: [HTTPCookie]) async throws {
        let html = try await LectioService.fetchHTML(pageURL, cookies: cookies)
        var fields = LectioForms.fields(in: HTMLDocument.parse(html))
        fields[reasonField] = reason
        fields[commentField] = comment

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
    @concurrent static func loadScheduleTargets(cookies: [HTTPCookie]) async throws -> [ScheduleTarget] {
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
    @concurrent static func loadWeek(for target: ScheduleTarget,
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
