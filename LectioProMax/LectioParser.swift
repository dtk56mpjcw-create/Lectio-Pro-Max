import Foundation

/// Direct port of the old Node/Playwright scraper's parsing logic, working on
/// raw HTML fetched natively instead of a rendered browser page. Selectors and
/// tooltip formats were reverse-engineered from this account's real Lectio pages.
enum LectioParser {

    struct Tooltip {
        var title: String = ""
        var date: String? = nil
        var start: String = ""
        var end: String = ""
        var allDay: Bool = false
        /// For an item running over several days ("6/10-2026 12:00 til
        /// 7/10-2026 15:15"): the last day, ISO.
        var endDate: String? = nil
        var hold: String = ""
        var teacher: String = ""
        var teacherInitials: String = ""
        var room: String = ""
        var homework: String = ""
        var note: String = ""
        var cancelled: Bool = false
        var changed: Bool = false
    }

    /// Lectio packs each schedule tile's detail into a data-tooltip attribute:
    ///   "Aflyst!\nIntro to history 5\n21/9-2026 08:00 til 09:35\nHold: 1j hi\n
    ///    Lærer: Christian Egholm Hattens (Chr)\nLokale: 064\n\nLektier:\n- ..."
    static func parseTooltip(_ raw: String) -> Tooltip {
        var result = Tooltip()
        // Lectio escapes the tooltip twice: after the attribute's own
        // decoding, "Frivillig billedkunst & design" still reads "&amp;".
        let text = raw.contains("&") ? HTMLDocument.decodeEntities(raw) : raw
        let lines = text.components(separatedBy: "\n")
        var i = 0

        // Lectio prefixes a tooltip with status words: "Aflyst!" (cancelled)
        // and "Ændret!" (changed). Consume any number of them — missing
        // "Ændret!" previously ate the title line, which made the date line
        // unparseable and silently dropped the whole lesson.
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "Aflyst!" { result.cancelled = true; i += 1; continue }
            if line == "Ændret!" { result.changed = true; i += 1; continue }
            break
        }
        // Most tooltips lead with a title, but some start straight at the date
        // line. Only consume a title when this line isn't itself a date.
        let datePattern = "^(\\d{1,2})/(\\d{1,2})-(\\d{4})\\s+(.*)$"
        if i < lines.count {
            let candidate = lines[i].trimmingCharacters(in: .whitespaces)
            if Rx.match(datePattern, candidate) == nil {
                result.title = candidate
                i += 1
            }
        }

        var dateLine = ""
        if i < lines.count {
            dateLine = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
        }

        if let g = Rx.match(datePattern, dateLine),
           let day = Int(g[1]), let month = Int(g[2]), let year = Int(g[3]) {
            result.date = String(format: "%04d-%02d-%02d", year, month, day)
            let rest = g[4]
            if Rx.test("Hele dagen", rest) {
                result.allDay = true
            } else if let m = Rx.match("(\\d{1,2}:\\d{2})\\s+til\\s+(\\d{1,2})/(\\d{1,2})-(\\d{4})\\s+(\\d{1,2}:\\d{2})", rest),
                      let d2 = Int(m[2]), let m2 = Int(m[3]), let y2 = Int(m[4]) {
                result.start = m[1]
                result.end = m[5]
                result.endDate = String(format: "%04d-%02d-%02d", y2, m2, d2)
            } else if let t = Rx.match("(\\d{1,2}:\\d{2})\\s+til\\s+(\\d{1,2}:\\d{2})", rest) {
                result.start = t[1]
                result.end = t[2]
            }
        }

        let remainder = i < lines.count ? lines[i...].joined(separator: "\n") : ""

        if let h = Rx.match("Hold:\\s*([^\\n]+)", remainder) {
            result.hold = h[1].trimmingCharacters(in: .whitespaces)
        }
        // One teacher is "Lærer:", two or more "Lærere:"; one room is
        // "Lokale:", two or more "Lokaler:" — a joint lesson for two classes
        // lost its rooms and teachers when only the singular was read.
        if let l = Rx.match("L[æa]rere?:\\s*([^\\n]+)", remainder) {
            let full = l[1].trimmingCharacters(in: .whitespaces)
            // "Karen Madsen (KM), Ole Hansen (OH)" -> "KM, OH".
            let initials = Rx.all("\\(([^)]+)\\)", full)
            result.teacherInitials = initials.isEmpty ? full : initials.joined(separator: ", ")
            result.teacher = full.replacingOccurrences(
                of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
        }
        if let r = Rx.match("Lokaler?:\\s*([^\\n]+)", remainder) {
            result.room = r[1].trimmingCharacters(in: .whitespaces)
        }
        // Everything after the first blank line is detail; Lectio labels it
        // "Lektier:" (homework) and/or "Note:".
        if let n = Rx.match("\\n\\s*\\n([\\s\\S]+)$", remainder) {
            let detail = n[1]
            if let lektier = detail.range(of: "Lektier:") {
                let after = detail[lektier.upperBound...]
                if let noteMark = after.range(of: "Note:") {
                    result.homework = String(after[..<noteMark.lowerBound])
                    result.note = String(after[noteMark.upperBound...])
                } else {
                    result.homework = String(after)
                }
            } else if let noteMark = detail.range(of: "Note:") {
                result.note = String(detail[noteMark.upperBound...])
            } else {
                result.note = detail
            }
            result.homework = result.homework.trimmingCharacters(in: .whitespacesAndNewlines)
            result.note = result.note.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    /// "1j hi" -> "hi", "1ij enB" -> "enB" (the per-subject code used for colours).
    /// "8:00" -> "08:00", so times sort and compare as text.
    static func padTime(_ t: String) -> String {
        t.count == 4 ? "0" + t : t
    }

    static func holdToCode(_ hold: String) -> String {
        let parts = hold.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        if parts.isEmpty { return "" }
        if parts.count > 1 { return parts[1...].joined(separator: " ") }
        return parts[0]
    }

    // MARK: - Schedule (SkemaNy.aspx)

    struct ScheduleResult {
        var week = ScheduleWeek()
        var nextWeekHref: String? = nil
    }

    static func parseSchedule(_ html: String) -> ScheduleResult {
        return parseSchedule(root: HTMLDocument.parse(html))
    }

    /// Same parse over an already-tokenized document, so a page several
    /// parsers read (forside.aspx) is tokenized once instead of once each.
    static func parseSchedule(root: HTMLNode) -> ScheduleResult {
        var result = ScheduleResult()

        let tiles = root.allWhere { $0.name == "a" && $0.hasClass("s2skemabrik") }

        var byDate: [String: [Lesson]] = [:]
        // A multi-day or all-day item is drawn once per day column, each
        // copy with the same tooltip; keep one per day.
        var seenSpans: Set<String> = []
        for tile in tiles {
            let tooltip = tile.attr("data-tooltip") ?? ""
            let parsed = parseTooltip(tooltip)
            guard let date = parsed.date else { continue }

            if parsed.allDay || parsed.endDate != nil {
                let last = parsed.endDate ?? date
                var day = date
                var guardCount = 0
                while day <= last && guardCount < 14 {
                    let key = day + "|" + tooltip
                    if !seenSpans.contains(key) {
                        seenSpans.insert(key)
                        var label = ""
                        if parsed.endDate != nil {
                            if day == date { label = "from " + parsed.start }
                            else if day == last { label = "until " + parsed.end }
                            // The days between: the whole school day (see
                            // DayPlan.timedPart), not a note.
                            else { label = "all day" }
                        }
                        let item = Lesson(
                            code: holdToCode(parsed.hold),
                            title: parsed.title,
                            teacher: parsed.teacherInitials,
                            room: parsed.room,
                            homework: parsed.homework,
                            note: parsed.note,
                            cancelled: tile.hasClass("s2cancelled") || parsed.cancelled,
                            changed: parsed.changed,
                            link: absoluteURL(tile.attr("href")),
                            allDay: label,
                            team: parsed.hold)
                        byDate[day, default: []].append(item)
                    }
                    day = LectioDates.shift(iso: day, byDays: 1)
                    guardCount += 1
                }
                continue
            }

            let lesson = Lesson(
                start: parsed.start,
                end: parsed.end,
                code: holdToCode(parsed.hold),
                title: parsed.title,
                teacher: parsed.teacherInitials,
                room: parsed.room,
                homework: parsed.homework,
                note: parsed.note,
                cancelled: tile.hasClass("s2cancelled") || parsed.cancelled,
                changed: parsed.changed,
                link: absoluteURL(tile.attr("href")),
                team: parsed.hold
            )
            byDate[date, default: []].append(lesson)
        }

        // The school's modules, from the left column: "1. modul8:00 - 9:35".
        var modules: [ScheduleModule] = []
        for info in root.allWithClass("s2module-info") {
            guard let g = Rx.match("(\\d+)\\.\\s*modul\\s*(\\d{1,2}:\\d{2})\\s*-\\s*(\\d{1,2}:\\d{2})", info.text),
                  let number = Int(g[1]) else { continue }
            if modules.contains(where: { $0.number == number }) { continue }
            modules.append(ScheduleModule(number: number, start: padTime(g[2]), end: padTime(g[3])))
        }
        if !modules.isEmpty { result.week.modules = modules.sorted { $0.number < $1.number } }

        // Keep every day Lectio shows for the week, weekends included.
        result.week.days = byDate.keys.sorted().map { iso in
            let lessons = (byDate[iso] ?? []).sorted { $0.start < $1.start }
            return ScheduleDay(date: iso, label: LectioDates.dayLabel(iso: iso), lessons: lessons)
        }

        // Lectio's date-picker box reads "Uge 39 (21/9-27/9) 2026".
        if let picker = root.firstWhere({ node in
            node.name == "input" &&
            (node.hasClass("ls-datepickerbox") || (node.attr("id") ?? "").contains("datePicker_tb"))
        }) {
            let value = picker.attr("value") ?? ""
            if let g = Rx.match("Uge\\s+(\\d+)\\s*\\(([^)]*)\\)\\s*(\\d{4})", value) {
                result.week.label = "Week " + g[1]
                result.week.dateRange = g[2]
                if let w = Int(g[1]), let y = Int(g[3]) {
                    result.week.code = String(format: "%02d%04d", w, y)
                }
            } else if let g = Rx.match("Uge\\s+(\\d+)", value) {
                result.week.label = "Week " + g[1]
            }
        }

        if let nav = root.firstWhere({ $0.name == "a" && $0.attr("data-nav") == "next" }) {
            result.nextWeekHref = absoluteURL(nav.attr("href"))
        }

        return result
    }

    // MARK: - Homework (forside.aspx)

    static func parseHomework(_ html: String) -> [HomeworkItem] {
        return parseHomework(root: HTMLDocument.parse(html))
    }

    /// Same parse over an already-tokenized document, so a page several
    /// parsers read (forside.aspx) is tokenized once instead of once each.
    static func parseHomework(root: HTMLNode) -> [HomeworkItem] {
        guard let block = root.first(id: "s_m_Content_Content_LektierDashBoardBlock") else { return [] }

        var items: [HomeworkItem] = []
        for row in block.all("tr") {
            guard let anchor = row.all("a").first else { continue }
            let linkText = anchor.text
            if linkText.isEmpty { continue }

            var code = ""
            var title = linkText
            if let g = Rx.match("^([^:]+):\\s*(.*)$", linkText) {
                code = holdToCode(g[1].trimmingCharacters(in: .whitespaces))
                title = g[2].trimmingCharacters(in: .whitespaces)
            }

            var due: String? = nil
            if let timeCell = row.allWhere({ $0.name == "td" && $0.hasClass("timeCol") }).first,
               let rawDue = timeCell.attr("title"),
               let parsed = LectioDates.parseDanish(rawDue) {
                due = parsed.date
            }

            items.append(HomeworkItem(code: code, title: title, due: due))
        }
        return items
    }

    // MARK: - Messages (forside.aspx)

    struct MessagesResult {
        var unread: Int = 0
        var messages: [MessagePreview] = []
    }

    static func parseMessages(_ html: String) -> MessagesResult {
        return parseMessages(root: HTMLDocument.parse(html))
    }

    /// Same parse over an already-tokenized document, so a page several
    /// parsers read (forside.aspx) is tokenized once instead of once each.
    static func parseMessages(root: HTMLNode) -> MessagesResult {
        var result = MessagesResult()

        if let island = root.first(id: "s_m_Content_Content_kommIsland_pa"),
           let info = island.allWithClass("dashboardLinkHeaderInfoText").first,
           let g = Rx.match("\\d+", info.text) {
            result.unread = Int(g[0]) ?? 0
        }

        guard let block = root.first(id: "s_m_Content_Content_BeskederInfo") else { return result }

        for row in block.all("tr") {
            guard let anchor = row.allWhere({ node in
                node.name == "a" && (node.attr("href") ?? "").contains("type=visbesked")
            }).first else { continue }

            let sender = row.allWhere({ node in
                node.name == "span" &&
                node.attr("title") != nil &&
                (node.attr("class") ?? "").contains("prepend-fonticon")
            }).first

            let timeCell = row.allWhere({ $0.name == "td" && $0.hasClass("timeCol") }).first

            result.messages.append(MessagePreview(
                subject: anchor.text,
                sender: sender?.attr("title") ?? sender?.text ?? "",
                date: timeCell?.attr("title") ?? "",
                link: absoluteURL(anchor.attr("href"))
            ))
        }

        return result
    }

    // MARK: - Assignments (OpgaverElev.aspx)

    static func parseAssignments(_ html: String) -> [AssignmentItem] {
        return parseAssignments(root: HTMLDocument.parse(html))
    }

    /// Same parse over an already-tokenized document, so a page several
    /// parsers read (forside.aspx) is tokenized once instead of once each.
    static func parseAssignments(root: HTMLNode) -> [AssignmentItem] {
        var items: [AssignmentItem] = []

        for row in root.all("tr") {
            let cells = row.allWhere { $0.name == "td" && $0.hasClass("OnlyDesktop") }
            guard cells.count > 5 else { continue }

            guard let anchor = row.allWhere({ node in
                node.name == "a" && (node.attr("href") ?? "").contains("ElevAflevering.aspx")
            }).first else { continue }

            let hold = cells[1].text
            let statusText = cells[5].text

            var due: String? = nil
            var dueTime = ""
            if let dueSpan = cells[3].allWhere({ $0.name == "span" && $0.attr("title") != nil }).first,
               let raw = dueSpan.attr("title"),
               let parsed = LectioDates.parseDanish(raw) {
                due = parsed.date
                dueTime = parsed.time
            }

            // Order matters: "Ikke afleveret" contains "afleveret", so the
            // negative has to be tested first or a missing hand-in reads as done.
            var status = statusText.lowercased()
            if Rx.test("ikke\\s*aflev", statusText) { status = "pending" }
            else if Rx.test("venter", statusText) { status = "pending" }
            else if Rx.test("afleveret", statusText) { status = "done" }

            // Uge | Hold | Opgavetitel | Frist | Elevtid | Status | Fravær |
            // Afventer | Opgavenote | Karakter | Elevnote
            let note = cells.count > 8
                ? cells[8].text.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            items.append(AssignmentItem(
                code: holdToCode(hold),
                title: anchor.text,
                due: due,
                dueTime: dueTime,
                status: status,
                link: absoluteURL(anchor.attr("href")),
                note: note.isEmpty ? nil : note
            ))
        }

        return items
    }

    // MARK: - Profile (forside.aspx)

    static func parseProfile(_ html: String) -> Profile {
        return parseProfile(root: HTMLDocument.parse(html))
    }

    /// Same parse over an already-tokenized document, so a page several
    /// parsers read (forside.aspx) is tokenized once instead of once each.
    static func parseProfile(root: HTMLNode) -> Profile {
        var profile = Profile()

        if let title = root.first(id: "s_m_HeaderContent_MainTitle") {
            let text = title.text
            if let g = Rx.match("Eleven\\s+(.+?),\\s*([^\\s-]+)", text) {
                profile.name = g[1].trimmingCharacters(in: .whitespaces)
                profile.className = g[2].trimmingCharacters(in: .whitespaces)
            } else {
                profile.name = text
            }
        }

        // The school's own name, from the page header.
        if let header = root.firstWhere({ $0.hasClass("ls-master-header-institution-name") }) {
            let name = header.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { profile.schoolName = name }
        }

        return profile
    }

    // MARK: - Helpers

    static func absoluteURL(_ href: String?) -> String? {
        guard let href = href, !href.isEmpty else { return nil }
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("/") { return "https://www.lectio.dk" + href }
        return "https://www.lectio.dk/lectio/" + LectioConfig.schoolID + "/" + href
    }
}

// MARK: - Assignment hand-in (ElevAflevering.aspx)

extension LectioParser {

    static func parseHandIn(_ html: String, pageURL: String) -> HandIn {
        return parseHandIn(root: HTMLDocument.parse(html), pageURL: pageURL)
    }

    static func parseHandIn(root: HTMLNode, pageURL: String) -> HandIn {
        var result = HandIn()
        result.pageURL = pageURL
        result.canHandIn = root.first(id: "m_Content_ElectronicHandInPanel") != nil

        // --- the ASP.NET form, exactly as the browser would resubmit it ------
        result.form = LectioForms.fields(in: root)

        // --- what's already been handed in -----------------------------------
        if let table = root.first(id: "m_Content_RecipientGV") {
            for row in table.all("tr") {
                // Lectio ships a mobile summary cell and a desktop cell per
                // column; the desktop ones are the clean, single-value cells.
                let cells = row.allWhere { $0.name == "td" && $0.hasClass("OnlyDesktop") }
                guard cells.count >= 4 else { continue }

                var entry = HandInEntry()
                entry.time = cells[0].text
                entry.user = cells[1].text
                entry.comment = cells[2].text
                entry.document = cells[3].text
                if let anchor = cells[3].all("a").first {
                    entry.documentLink = absoluteURL(anchor.attr("href"))
                }
                if entry.time.isEmpty && entry.document.isEmpty && entry.comment.isEmpty { continue }
                result.entries.append(entry)
            }
        }

        // --- where the assignment stands -------------------------------------
        //
        // Read by the COLUMN HEADING, not by counting the marker spans. Lectio
        // only puts `ls-elevaflevering-field-value` on a cell that has something
        // in it, so the span count changes with how much the teacher has filled
        // in — an assignment with no grade note and no student note has four
        // spans, not six. The old `values.count >= 6` guard therefore skipped the
        // row entirely on a freshly handed-in assignment, leaving the status
        // blank, which the sheet then showed as "Not handed in" on work that had
        // in fact been delivered. Headings survive that; the photo column and any
        // column Lectio adds later just shift the indices, which is what the map
        // is for.
        if let table = root.first(id: "m_Content_StudentGV") {
            let rows = table.all("tr")

            var headings: [(name: String, index: Int)] = []
            if let header = rows.first {
                for (index, cell) in header.all("th").enumerated() {
                    let name = cell.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { headings.append((name, index)) }
                }
            }

            func column(_ exact: String, or contains: String? = nil) -> Int? {
                if let hit = headings.first(where: { $0.name == exact }) { return hit.index }
                if let contains = contains,
                   let hit = headings.first(where: { $0.name.contains(contains) }) { return hit.index }
                return nil
            }

            func value(_ cells: [HTMLNode], _ index: Int?) -> String {
                guard let index = index, index >= 0, index < cells.count else { return "" }
                return cells[index].text
            }

            for row in rows {
                let cells = row.all("td")
                guard cells.count >= 4 else { continue }        // skips the header row
                result.status.waitingFor = value(cells, column("afventer"))
                result.status.delivery = value(cells, column("status - fravær", or: "status"))
                result.status.grade = value(cells, column("karakter"))
                result.status.gradeNote = value(cells, column("karakternote"))
                result.status.studentNote = value(cells, column("elevnote"))
                if let box = row.allWhere({ $0.name == "input" && ($0.attr("type") ?? "") == "checkbox" }).first {
                    result.status.finished = box.attrs["checked"] != nil
                }
                break
            }
        }

        // --- a group hand-in ---------------------------------------------------
        //
        // "Gruppeaflevering": the members sit in m_Content_groupMembersGV as
        // `<span data-lectiocontextcard="S<elevid>">Ivan Surov, 1j 12</span>`,
        // and while you can still add people there's a <select> of the rest of
        // the class (`m$Content$groupStudentAddDD`, option value = elevid) with
        // a Tilføj button that posts back `m$Content$groupStudentAddBtn`.
        if let table = root.first(id: "m_Content_groupMembersGV") {
            result.isGroup = true
            for row in table.all("tr") {
                let cells = row.all("td")
                guard let first = cells.first else { continue }
                let people = first.allWhere { ($0.attrs["data-lectiocontextcard"] ?? "").hasPrefix("S") }

                // A remove link, if Lectio offers one, would sit in the row's
                // last cell. Only trusted when the row holds one person — a
                // single link for several people would be ambiguous.
                var removeTarget: String? = nil
                var removeArgument = ""
                if people.count == 1, cells.count > 1, let last = cells.last {
                    for anchor in last.all("a") {
                        let script = (anchor.attr("onclick") ?? "") + " " + (anchor.attr("href") ?? "")
                        if let g = Rx.match("__doPostBack\\('([^']*)','([^']*)'\\)", script) {
                            removeTarget = g[1]
                            removeArgument = g[2]
                            break
                        }
                    }
                }

                for span in people {
                    let id = String((span.attrs["data-lectiocontextcard"] ?? "").dropFirst())
                    guard !id.isEmpty else { continue }
                    let (name, klass) = splitPerson(span.text, separator: ", ")
                    result.groupMembers.append(GroupPerson(id: id, name: name, className: klass,
                                                           removeTarget: removeTarget,
                                                           removeArgument: removeArgument))
                }
            }
        }
        if let select = root.first(id: "m_Content_groupStudentAddDD") {
            for option in select.all("option") {
                let id = option.attr("value") ?? ""
                guard !id.isEmpty else { continue }
                // "Abdul Raffay Hussain (1j 01)"
                var text = option.text.trimmingCharacters(in: .whitespaces)
                var klass = ""
                if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
                    klass = String(text[open.upperBound..<text.index(before: text.endIndex)])
                    text = String(text[..<open.lowerBound])
                }
                result.groupCandidates.append(GroupPerson(id: id, name: text, className: klass))
            }
        }

        return result
    }

    /// "Ivan Surov, 1j 12" → ("Ivan Surov", "1j 12").
    private static func splitPerson(_ raw: String, separator: String) -> (String, String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = text.range(of: separator, options: .backwards) else { return (text, "") }
        return (String(text[..<cut.lowerBound]),
                String(text[cut.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}

/// The study plan (`studieplan.aspx?displaytype=ugeteksttabel`).
///
/// Lectio draws this as a wall chart: one enormous row, with each subject's
/// units stacked inside its column and positioned by CSS `top`/`height` against
/// a week ruler down the side. The pixel offsets are not worth reading — every
/// unit's own `data-tooltip` carries its title, estimate and period in text.
///
/// The one structural thing that does matter is the header's COLSPANS. A subject
/// whose units overlap in time gets extra columns to lay them out in, so `1j ma`
/// with three parallel units spans three cells while everything else spans one.
/// Walking those colspans is what keeps units attached to the right subject.
extension LectioParser {
    static func parseStudyPlan(_ html: String) -> [StudyPlanSubject] {
        let root = HTMLDocument.parse(html)
        guard let table = root.firstWhere({
            ($0.attrs["id"] ?? "").hasSuffix("spUge_theTable")
        }) else { return [] }

        let rows = table.all("tr")
        guard let header = rows.first, rows.count >= 2 else { return [] }

        // Subject headers are the ones carrying a colspan; "Måned", "Uge" and
        // "Elevtid" are plain.
        var subjects: [(name: String, span: Int)] = []
        for cell in header.all("th") {
            guard let span = cell.attr("colspan"), let width = Int(span) else { continue }
            let name = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            subjects.append((name, max(width, 1)))
        }
        guard !subjects.isEmpty else { return [] }

        // The content row: every cell that belongs to a subject column.
        var columns: [HTMLNode] = []
        for row in rows where row.allWhere({ $0.hasClass("phaseCol") || $0.hasClass("exerciseCol") }).isEmpty == false {
            columns = row.all("td").filter { $0.hasClass("phaseCol") || $0.hasClass("exerciseCol") }
            break
        }

        // The Elevtid row is the last one, and its subject cells line up with the
        // headers one for one. They are `th`, not `td` — Lectio marks the totals
        // row up as a header — and the two label cells carry no colspan, so the
        // colspan filter picks out exactly the subjects.
        var hours: [String] = []
        if let last = rows.last {
            hours = last.all("th")
                .filter { $0.attr("colspan") != nil }
                .map { $0.text }
        }

        var out: [StudyPlanSubject] = []
        var cursor = 0
        for (index, subject) in subjects.enumerated() {
            var entry = StudyPlanSubject(name: subject.name)

            let end = min(cursor + subject.span, columns.count)
            if cursor < end {
                for column in columns[cursor..<end] {
                    entry.phases.append(contentsOf: phases(in: column))
                }
            }
            cursor += subject.span

            if index < hours.count {
                let text = hours[index]
                if let g = Rx.match("total:\\s*([0-9]+(?:[.,][0-9]+)?)", text) {
                    entry.hours = number(g[1])
                }
                if let g = Rx.match("norm:\\s*([0-9]+(?:[.,][0-9]+)?)", text) {
                    entry.norm = number(g[1])
                }
            }

            if !entry.phases.isEmpty || entry.hours > 0 || entry.norm > 0 {
                out.append(entry)
            }
        }
        return out
    }

    private static func phases(in column: HTMLNode) -> [StudyPhase] {
        var found: [StudyPhase] = []
        for block in column.allWithClass("phase") {
            guard let anchor = block.all("a").first,
                  let href = anchor.attr("href"), href.contains("forloeb_vis") else { continue }

            var phase = StudyPhase()
            phase.title = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            phase.link = absoluteURL(href) ?? href

            let tooltip = anchor.attr("data-tooltip") ?? block.attr("data-tooltip") ?? ""
            if let g = Rx.match("estimat:\\s*([0-9]+(?:[.,][0-9]+)?)", tooltip) {
                phase.estimate = g[1]
            }
            // Matched by the date shape rather than by "up to the line end":
            // Lectio's tooltips run the description straight on after the period.
            let datePattern = "[a-zæøå]{2}\\s+[0-9]{1,2}/[0-9]{1,2}-[0-9]{2,4}"
            if let g = Rx.match("periode:\\s*(" + datePattern + "\\s*-\\s*" + datePattern + ")", tooltip) {
                phase.period = g[1].replacingOccurrences(of: "\n", with: " ")
                if let tail = tooltip.range(of: g[0]) {
                    phase.summary = String(tooltip[tail.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if phase.title.isEmpty { continue }
            found.append(phase)
        }
        return found
    }

    private static func number(_ text: String) -> Double {
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

/// Your own subject teams, read off your timetable.
///
/// Lectio's FindSkema has a `hold` page, but it serves no list — so there is no
/// directory of the school's 600 teams to search. Your own timetable does link
/// every team you're on (`SkemaNy.aspx?type=holdelement&holdelementid=…`), which
/// is the set you'd actually want to look up anyway.
extension LectioParser {
    static func parseSubjectTargets(_ html: String) -> [ScheduleTarget] {
        let root = HTMLDocument.parse(html)
        var byID: [String: ScheduleTarget] = [:]

        for anchor in root.all("a") {
            guard let href = anchor.attr("href"),
                  href.contains("type=holdelement"),
                  let group = Rx.match("holdelementid=(\\d+)", href) else { continue }
            let id = group[1]
            if byID[id] != nil { continue }

            let name = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 40 else { continue }

            byID[id] = ScheduleTarget(
                name: name,
                url: LectioConfig.skemaURL + "?type=holdelement&holdelementid=" + id,
                kind: .subject)
        }

        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Messages (beskeder2.aspx)

extension LectioParser {

    /// The inbox list. Unlike the dashboard preview, this has real per-thread
    /// unread state, flags and attachment markers.
    static func parseInbox(_ html: String) -> [MessageThreadSummary] {
        return parseInbox(root: HTMLDocument.parse(html))
    }

    static func parseInbox(root: HTMLNode) -> [MessageThreadSummary] {
        guard let table = root.firstWhere({ ($0.attrs["id"] ?? "").contains("threadGV") && $0.name == "table" })
        else { return [] }

        var threads: [MessageThreadSummary] = []
        for row in table.all("tr") {
            let cells = row.allWhere { $0.name == "td" && $0.hasClass("OnlyDesktop") }
            guard cells.count >= 8 else { continue }

            var thread = MessageThreadSummary()
            thread.id = threadID(in: row)
            if thread.id.isEmpty { continue }

            thread.unread = row.hasClass("unread")
            thread.hasAttachment = row.firstWhere { $0.hasClass("prepend-fonticon-dokumenter") } != nil

            if let flag = row.firstWhere({ ($0.attrs["id"] ?? "").hasSuffix("flagId") }) {
                // flagoff.gif when clear, something else when set.
                thread.flagged = !((flag.attr("src") ?? "").contains("flagoff"))
            }

            if let subject = row.firstWhere({ ($0.attrs["id"] ?? "").hasSuffix("_ch") }) {
                thread.subject = subject.text
            } else {
                thread.subject = cells[3].text
            }

            thread.latestSender = personName(in: cells[4])
            thread.firstSender = personName(in: cells[5])
            thread.recipients = personName(in: cells[6])
            thread.changed = cells[7].text

            threads.append(thread)
        }
        return threads
    }

    /// A full thread, plus the fields needed to reply to it.
    static func parseThread(_ html: String, id: String, pageURL: String) -> MessageThread {
        return parseThread(root: HTMLDocument.parse(html), id: id, pageURL: pageURL)
    }

    static func parseThread(root: HTMLNode, id: String, pageURL: String) -> MessageThread {
        var result = MessageThread()
        result.id = id
        result.pageURL = pageURL
        result.form = LectioForms.fields(in: root)

        // The sender line is a SIBLING that precedes each message block rather
        // than living inside it, so walk in document order and carry it along.
        var pendingSender = ""
        func walk(_ node: HTMLNode) {
            for item in node.content {
                guard case .element(let element) = item else { continue }

                if element.hasClass("message-thread-message-sender") {
                    pendingSender = element.text
                    continue
                }
                if element.hasClass("message-thread-message") {
                    result.messages.append(message(from: element, senderLine: pendingSender))
                    pendingSender = ""
                    continue        // its header and content are read above
                }
                walk(element)
            }
        }
        walk(root)

        result.subject = result.messages.first?.title ?? ""

        if let header = root.firstWhere({ ($0.attrs["id"] ?? "").hasSuffix("messageThreadHeaderDiv") }) {
            result.recipients = stripIconWords(header.text)
        }

        // The composer's control prefix is an index into the messages grid, so
        // it moves as the thread grows. Always read it off the page.
        if let box = root.firstWhere({ $0.name == "textarea" && ($0.attr("name") ?? "").contains("EditModeContentBBTB") }),
           let name = box.attr("name"),
           let cut = name.range(of: "$EditModeContentBBTB") {
            result.composerPrefix = String(name[..<cut.lowerBound])
            result.canReply = true
        }

        return result
    }

    // MARK: Helpers

    private static func message(from block: HTMLNode, senderLine: String) -> ThreadMessage {
        var message = ThreadMessage()

        // "Julie Skov Nikolajsen (JN), 01-09-2026 12:54:01"
        if let split = Rx.match("^(.*?),\\s*(\\d{1,2}-\\d{1,2}-\\d{4}.*)$", senderLine) {
            message.sender = split[1].trimmingCharacters(in: .whitespaces)
            message.date = split[2].trimmingCharacters(in: .whitespaces)
        } else {
            message.sender = senderLine
        }

        if let header = block.firstWhere({ $0.hasClass("message-thread-message-header") }) {
            message.title = header.text
        }
        if let content = block.firstWhere({ $0.hasClass("message-thread-message-content") }) {
            message.body = content.text
        }

        for anchor in block.all("a") {
            let href = anchor.attr("href") ?? ""
            guard href.lowercased().contains("dokumenthent.aspx") else { continue }
            let name = anchor.text
            guard !name.isEmpty, let link = absoluteURL(href) else { continue }
            message.attachments.append(MessageAttachment(name: name, link: link))
        }

        return message
    }

    /// Lectio puts the full name in a title attribute and the initials in the
    /// text, so prefer the attribute where there is one.
    private static func personName(in cell: HTMLNode) -> String {
        if let titled = cell.firstWhere({ ($0.attr("title") ?? "").isEmpty == false }) {
            let title = titled.attr("title") ?? ""
            return title.replacingOccurrences(of: "\n", with: ", ")
        }
        return cell.text
    }

    private static func threadID(in row: HTMLNode) -> String {
        for node in row.allWhere({ $0.attrs["onclick"] != nil }) {
            let onclick = node.attrs["onclick"] ?? ""
            if let g = Rx.match("(?:VIEWTHREAD|FLAGMESSAGE|READMESSAGE|HIDEMESSAGE)_(\\d+)", onclick) {
                return g[1]
            }
            if let g = Rx.match("_MC_\\$_(\\d+)", onclick) { return g[1] }
        }
        return ""
    }

    /// The header div's text picks up the icon-font words of the buttons beside it.
    private static func stripIconWords(_ text: String) -> String {
        var out = text
        for word in ["reply", "flag", "edit", "delete", "more_vert", "mail", "print"] {
            out = out.replacingOccurrences(of: " " + word, with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Lektier overview (material_lektieoversigt.aspx)

extension LectioParser {

    /// Every upcoming lesson that carries homework or a note. The tiles here
    /// use exactly the same `data-tooltip` format as the schedule, so the same
    /// tooltip parser does the work.
    static func parseLessonNotes(_ html: String) -> [LessonNote] {
        return parseLessonNotes(root: HTMLDocument.parse(html))
    }

    static func parseLessonNotes(root: HTMLNode) -> [LessonNote] {
        let tiles = root.allWhere { $0.name == "a" && $0.hasClass("s2skemabrik") }

        var seen: Set<String> = []
        var notes: [LessonNote] = []
        for tile in tiles {
            let parsed = parseTooltip(tile.attr("data-tooltip") ?? "")
            guard let date = parsed.date, !parsed.allDay else { continue }
            if parsed.homework.isEmpty && parsed.note.isEmpty { continue }

            var entry = LessonNote()
            entry.date = date
            entry.start = parsed.start
            entry.end = parsed.end
            entry.code = holdToCode(parsed.hold)
            entry.title = parsed.title
            entry.teacher = parsed.teacherInitials
            entry.room = parsed.room
            entry.homework = parsed.homework
            entry.note = parsed.note
            entry.link = absoluteURL(tile.attr("href"))

            // Lectio renders each row twice — a desktop cell and a mobile one.
            if seen.contains(entry.id) { continue }
            seen.insert(entry.id)
            notes.append(entry)
        }
        return notes.sorted { ($0.date + $0.start) < ($1.date + $1.start) }
    }
}

// MARK: - Absence (fravaerelev*.aspx)

extension LectioParser {

    /// The per-subject summary from `subnav/fravaerelev.aspx`.
    static func parseAbsenceSubjects(_ html: String) -> [AbsenceSubject] {
        let root = HTMLDocument.parse(html)
        guard let table = root.firstWhere({ ($0.attrs["id"] ?? "").contains("StudentAbsenceDataTable") })
        else { return [] }

        var rows: [AbsenceSubject] = []
        for row in table.all("tr") {
            let cells = row.all("td")
            guard cells.count >= 3 else { continue }
            let code = cells[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty { continue }

            var subject = AbsenceSubject()
            subject.code = code
            subject.isTotal = code.lowercased().contains("samlet")
            subject.modules = cells.count > 1 ? cells[1].text : ""
            subject.percent = cells.count > 2 ? cells[2].text : ""
            subject.writtenModules = cells.count > 3 ? cells[3].text : ""
            subject.writtenPercent = cells.count > 4 ? cells[4].text : ""
            rows.append(subject)
        }
        return rows
    }

    /// Both tables on `subnav/fravaerelev_fravaersaarsager.aspx`: the ones still
    /// waiting for a reason, and the full log.
    ///
    /// The two tables have different columns, so each is read against its own
    /// header rather than by guessing at cell shapes:
    ///   missing:    Uge | Aktivitet | Fravær | Bemærkning
    ///   registered: Uge | Aktivitet | Fravær | Registreret | Bemærkning | Fraværsårsag | Kommentar
    static func parseAbsenceRecords(_ html: String) -> [AbsenceRecord] {
        let root = HTMLDocument.parse(html)
        var records: [AbsenceRecord] = []
        var seen: Set<String> = []

        func collect(_ tableID: String, needsReason: Bool) {
            guard let table = root.firstWhere({ ($0.attrs["id"] ?? "").contains(tableID) }) else { return }

            for row in table.all("tr") {
                guard let tile = row.firstWhere({ $0.name == "a" && $0.hasClass("s2skemabrik") }) else { continue }
                let parsed = parseTooltip(tile.attr("data-tooltip") ?? "")

                var record = AbsenceRecord()
                record.needsReason = needsReason
                record.date = parsed.date ?? ""
                record.start = parsed.start
                record.end = parsed.end
                record.code = holdToCode(parsed.hold)
                record.teacher = parsed.teacherInitials
                record.room = parsed.room

                // "ti 15/9 1. modul - 1j nv • Ja • 012" -> "1. modul"
                if let g = Rx.match("(\\d+)\\.\\s*modul", tile.text) {
                    record.module = "Module " + g[1]
                }

                let cells = row.allWhere { $0.name == "td" && $0.hasClass("OnlyDesktop") }
                if cells.count > 0 { record.week = cells[0].text }
                if cells.count > 2 {
                    record.percent = cells[2].text
                        .replacingOccurrences(of: "Fravær", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !needsReason {
                    if cells.count > 3 { record.registered = cells[3].text }
                    if cells.count > 5 { record.reason = cells[5].text }
                    if cells.count > 6 { record.comment = cells[6].text }
                } else if cells.count > 3 {
                    record.comment = cells[3].text
                }

                if let link = row.firstWhere({ ($0.attr("href") ?? "").contains("fravaer_aarsag.aspx") }) {
                    record.reasonLink = absoluteURL(link.attr("href"))
                }

                if seen.contains(record.id) { continue }
                seen.insert(record.id)
                records.append(record)
            }
        }

        collect("FatabMissingAarsagerGV", needsReason: true)
        collect("FatabAbsenceFravaerGV", needsReason: false)
        return records.sorted { $0.date > $1.date }
    }
}

// MARK: - FindSkema

extension LectioParser {

    /// Lectio's own "find a schedule" listings: a flat list of links straight to
    /// each person's, class's or room's timetable.
    static func parseScheduleTargets(_ html: String, kind: ScheduleTarget.Kind) -> [ScheduleTarget] {
        let root = HTMLDocument.parse(html)
        var targets: [ScheduleTarget] = []
        var seen: Set<String> = []

        for anchor in root.all("a") {
            let href = anchor.attr("href") ?? ""
            guard href.contains("SkemaNy.aspx?") else { continue }
            let name = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let url = absoluteURL(href) else { continue }
            if seen.contains(url) { continue }
            seen.insert(url)
            targets.append(ScheduleTarget(name: name, url: url, kind: kind))
        }
        return targets
    }
}

// MARK: - A lesson's own page (aktivitet/aktivitetforside2.aspx)

extension LectioParser {

    /// Lectio's lesson page: an activity note in a (disabled) textarea, then
    /// content grouped under section headings. Files hang off anchors marked
    /// `data-lc-display-linktype="file"`, pointing at `/lectio/<school>/lc/…`.
    static func parseLessonDetail(_ html: String) -> LessonDetail {
        return parseLessonDetail(root: HTMLDocument.parse(html))
    }

    static func parseLessonDetail(root: HTMLNode) -> LessonDetail {
        var detail = LessonDetail()

        if let note = root.firstWhere({
            $0.name == "textarea" && ($0.attr("name") ?? "").contains("ActNoteTB")
        }) {
            detail.note = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let paper = root.firstWhere({ $0.attrs["id"] == "homeworkContentContainer" })
                ?? root.firstWhere({ $0.hasClass("ls-paper") }) else { return detail }

        var sections: [LessonSection] = []
        var current = LessonSection(title: "Content")
        var counter = 0

        func flush() {
            if !current.entries.isEmpty { sections.append(current) }
        }

        func walk(_ node: HTMLNode) {
            for item in node.content {
                guard case .element(let element) = item else { continue }

                if element.hasClass("ls-paper-section-heading") {
                    flush()
                    current = LessonSection(title: element.text)
                    continue
                }

                if element.hasClass("lc-display-fragment") {
                    counter += 1
                    var entry = LessonEntry(id: "entry-\(counter)")
                    for anchor in element.all("a") {
                        guard (anchor.attr("data-lc-display-linktype") ?? "") == "file"
                                || (anchor.attr("href") ?? "").contains("/lc/") else { continue }
                        guard let link = absoluteURL(anchor.attr("href")) else { continue }
                        let name = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.files.append(LessonFile(name: name.isEmpty ? "File" : name, link: link))
                    }
                    // The text, minus the file names we've already listed.
                    var text = element.text
                    for file in entry.files {
                        text = text.replacingOccurrences(of: file.name, with: "")
                    }
                    entry.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !entry.isEmpty { current.entries.append(entry) }
                    continue
                }

                walk(element)
            }
        }

        walk(paper)
        flush()
        detail.sections = sections
        return detail
    }
}
