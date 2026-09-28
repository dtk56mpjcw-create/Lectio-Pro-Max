import Foundation
import UIKit

// MARK: - Models

/// Lectio's digital student card (digitaltStudiekort.aspx).
struct StudentCard: Hashable {
    var name: String = ""
    var school: String = ""
    /// "3/8-2009"
    var birthday: String = ""
    /// "17"
    var age: String = ""
    var photoURL: String?
    /// The QR image without its `time` parameter; a fresh one is asked for
    /// every `qrInterval` seconds, as Lectio's own page does.
    var qrURL: String?
    var qrInterval: TimeInterval = 36
    /// Lectio's own "© Lectio d. 25/9-2026 21:24" line.
    var stamp: String = ""
}

/// One grade in one column of Lectio's grade table.
struct GradeCell: Hashable {
    /// Lectio's column heading, e.g. "1. standpunkt".
    var column: String
    /// "7", "10", "-3", or whatever else Lectio wrote ("Bestået").
    var grade: String
    var weight: Double?

    /// The grade on the 7-point scale, if it is one.
    var value: Int? {
        let allowed = [-3, 0, 2, 4, 7, 10, 12]
        guard let number = Int(grade), allowed.contains(number) else { return nil }
        return number
    }
}

struct GradeRow: Identifiable, Hashable {
    var id: String { team + "|" + subject }
    /// The team, e.g. "1j ma".
    var team: String
    /// Lectio's subject name, e.g. "Matematik A".
    var subject: String
    var cells: [GradeCell]

    /// The newest grade given: the rightmost column that has one.
    var latest: GradeCell? {
        cells.last { !$0.grade.isEmpty }
    }
}

/// A note a teacher wrote with a grade.
struct GradeNote: Identifiable, Hashable {
    var id: String { fields.map { $0.value }.joined(separator: "|") }
    var fields: [(label: String, value: String)]

    static func == (lhs: GradeNote, rhs: GradeNote) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct GradeReport: Hashable {
    var columns: [String] = []
    var rows: [GradeRow] = []
    var notes: [GradeNote] = []

    /// Every subject's newest grade on the 7-point scale, weighted by Lectio's
    /// weight where it gives one.
    var average: Double? {
        var sum = 0.0
        var weights = 0.0
        for row in rows {
            guard let cell = row.cells.last(where: { $0.value != nil }),
                  let value = cell.value else { continue }
            let weight = cell.weight ?? 1
            sum += Double(value) * weight
            weights += weight
        }
        return weights > 0 ? sum / weights : nil
    }

    var gradedSubjects: Int {
        rows.filter { row in row.cells.contains { $0.value != nil } }.count
    }
}

// MARK: - Service

/// The "Me" pages: the student card and grades.
enum LectioMeService {
    static var studentCardURL: String { LectioConfig.base + "/digitaltStudiekort.aspx" }
    static var gradesURL: String { LectioConfig.base + "/grades/grade_report.aspx" }

    @concurrent static func loadStudentCard(cookies: [HTTPCookie]) async throws -> StudentCard {
        let html = try await LectioService.fetchHTML(studentCardURL, cookies: cookies)
        return parseStudentCard(html)
    }

    @concurrent static func loadGrades(cookies: [HTTPCookie]) async throws -> GradeReport {
        let html = try await LectioService.fetchHTML(gradesURL, cookies: cookies)
        return parseGrades(html)
    }

    @concurrent static func image(_ link: String, cookies: [HTTPCookie]) async -> UIImage? {
        guard let data = try? await LectioService.fetchData(link, cookies: cookies) else { return nil }
        return UIImage(data: data)
    }

    /// A fresh QR code. Lectio's page asks for a new one with the current
    /// time on the end every 36 seconds, so a screenshot of it goes stale.
    @concurrent static func qrImage(for card: StudentCard, cookies: [HTTPCookie]) async -> UIImage? {
        guard let base = card.qrURL else { return nil }
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let link = base + (base.contains("?") ? "&" : "?") + "time=" + stamp
        return await image(link, cookies: cookies)
    }

    // MARK: Parsing

    static func parseStudentCard(_ html: String) -> StudentCard {
        let root = HTMLDocument.parse(html)
        var card = StudentCard()

        func text(_ id: String) -> String {
            root.first(id: id)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        card.name = text("s_m_Content_Content_StudentName")
        card.school = text("s_m_Content_Content_SchoolName")
        card.stamp = text("s_m_Content_Content_LectioCR")

        // "Fødselsdag: 3/8-2009 (17 år)"
        let born = text("s_m_Content_Content_StudentBirthday")
        if let g = Rx.match("(\\d{1,2}/\\d{1,2}-\\d{4})", born) { card.birthday = g[1] }
        if let g = Rx.match("\\((\\d+)\\s*år", born) { card.age = g[1] }

        if let src = root.first(id: "s_m_Content_Content_StudPic")?.attr("src") {
            card.photoURL = LectioParser.absoluteURL(src)
        }
        // The QR <img> arrives without a src: Lectio's script fills it in,
        // from the address it's given here —
        //   LectioQRCode.Initialize('…theQrCode', 'https://…studiekortqr…', '', 36000);
        if let g = Rx.match("LectioQRCode\\.Initialize\\(\\s*'[^']*'\\s*,\\s*'([^']+)'", html) {
            let link = g[1].replacingOccurrences(of: "&amp;", with: "&")
            card.qrURL = LectioParser.absoluteURL(link).map { withoutTime($0) }
        } else if let src = root.first(id: "s_m_Content_Content_QRCode_theQrCode")?.attr("src"),
                  let absolute = LectioParser.absoluteURL(src) {
            card.qrURL = withoutTime(absolute)
        }
        if let g = Rx.match("LectioQRCode\\.Initialize\\([^)]*?,\\s*(\\d+)\\s*\\)", html),
           let ms = Double(g[1]), ms >= 5000 {
            card.qrInterval = ms / 1000
        }
        return card
    }

    private static func withoutTime(_ link: String) -> String {
        guard var parts = URLComponents(string: link) else { return link }
        parts.queryItems = parts.queryItems?.filter { $0.name.lowercased() != "time" }
        return parts.string ?? link
    }

    /// Lectio's grade page is two grids: KarakterGV (one row per team, one
    /// column per kind of grade) and KarakterNoterGrid (notes). Which grade
    /// columns there are depends on the school and the year, so the headings
    /// are read rather than assumed.
    static func parseGrades(_ html: String) -> GradeReport {
        let root = HTMLDocument.parse(html)
        var report = GradeReport()

        if let table = root.firstWhere({
            $0.name == "table" && ($0.attr("id") ?? "").hasSuffix("KarakterGV")
        }) {
            let (headers, rows) = grid(table)
            let lower = headers.map { $0.lowercased() }
            let teamIndex = lower.firstIndex { $0.contains("hold") } ?? 0
            let subjectIndex = lower.firstIndex { $0 == "fag" || $0.hasPrefix("fag") }
                ?? (headers.count > 2 ? 1 : nil)
            let gradeIndices = headers.indices.filter { $0 != teamIndex && $0 != subjectIndex }
            report.columns = gradeIndices.map { headers[$0] }

            for cells in rows where cells.count == headers.count {
                let team = clean(cells[teamIndex].text)
                let subject = subjectIndex.map { clean(cells[$0].text) } ?? ""
                guard !team.isEmpty || !subject.isEmpty else { continue }
                let grades = gradeIndices.map { index in
                    GradeCell(column: headers[index],
                              grade: gradeText(cells[index]),
                              weight: weight(in: cells[index]))
                }
                report.rows.append(GradeRow(team: team, subject: subject, cells: grades))
            }
        }

        if let table = root.firstWhere({
            $0.name == "table" && ($0.attr("id") ?? "").hasSuffix("KarakterNoterGrid")
        }) {
            let (headers, rows) = grid(table)
            for cells in rows where cells.count == headers.count {
                let fields = zip(headers, cells)
                    .map { (label: $0.0, value: clean($0.1.text)) }
                    .filter { !$0.value.isEmpty }
                if !fields.isEmpty { report.notes.append(GradeNote(fields: fields)) }
            }
        }
        return report
    }

    /// Headings and data rows of a Lectio grid, skipping its "no data" row.
    private static func grid(_ table: HTMLNode) -> (headers: [String], rows: [[HTMLNode]]) {
        var headers: [String] = []
        var rows: [[HTMLNode]] = []
        for tr in table.all("tr") {
            let cells = tr.children.filter { $0.name == "td" || $0.name == "th" }
            let isHeading = !cells.isEmpty && cells.allSatisfy { $0.name == "th" }
            if isHeading {
                if headers.isEmpty { headers = cells.map { clean($0.text) } }
                continue
            }
            if tr.firstWhere({ $0.hasClass("noRecord") }) != nil { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        return (headers, rows)
    }

    private static func gradeText(_ cell: HTMLNode) -> String {
        let text = clean(cell.text)
        if let g = Rx.match("(?:^|\\s)(-3|00|02|4|7|10|12)(?:\\s|$)", text) {
            // "00" and "02" are grades as written; Int() reads them fine.
            return g[1]
        }
        return text
    }

    /// Lectio puts the weight in a tooltip ("Vægt: 1,00").
    private static func weight(in cell: HTMLNode) -> Double? {
        var titles: [String] = []
        if let t = cell.attr("title") { titles.append(t) }
        titles += cell.allWhere { $0.attr("title") != nil }.compactMap { $0.attr("title") }
        for title in titles {
            if let g = Rx.match("[Vv]ægt\\D*(\\d+(?:[.,]\\d+)?)", title),
               let value = Double(g[1].replacingOccurrences(of: ",", with: ".")) {
                return value
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
