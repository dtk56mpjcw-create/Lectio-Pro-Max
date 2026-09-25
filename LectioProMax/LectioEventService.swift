import Foundation

/// Private appointments — Lectio's "Privat aftale". They show up in your own
/// schedule alongside lessons, and, as the page itself says, nobody else can
/// see them.
///
/// The form lives at `privat_aftale.aspx` and saves through the usual ASP.NET
/// postback, with `m$Content$savebuttonsCtrl$svbtn` as the "Gem" button.
enum LectioEventService {

    struct Draft {
        /// Lectio's `aftaleid`. Nil for something not saved yet.
        var id: String? = nil
        var title: String = ""
        var startISO: String = ""     // yyyy-MM-dd
        var startTime: String = ""    // HH:mm
        var endISO: String = ""
        var endTime: String = ""
        var note: String = ""
    }

    enum EventError: LocalizedError {
        case titleMissing
        case titleTooLong
        case endBeforeStart
        case rejected(String?)

        var errorDescription: String? {
            switch self {
            case .titleMissing: return "Give the event a title."
            case .titleTooLong: return "Lectio only allows 20 characters in the title."
            case .endBeforeStart: return "The end has to come after the start."
            case .rejected(let why):
                return why ?? "Lectio didn't accept the event."
            }
        }
    }

    /// Lectio caps the title at 20 characters — enforced only by an onkeydown
    /// handler on the web page, so the app has to do it itself.
    static let titleLimit = 20

    static func formURL(eventID: String? = nil) -> String {
        let base = LectioConfig.base + "/privat_aftale.aspx?"
        guard let eventID = eventID, !eventID.isEmpty else { return base + "prevurl=SkemaNy.aspx" }
        return base + "aftaleid=" + eventID + "&prevurl=SkemaNy.aspx"
    }

    /// Reads an existing appointment back out of its own edit form.
    static func load(eventID: String, cookies: [HTTPCookie]) async throws -> Draft {
        let html = try await LectioService.fetchHTML(formURL(eventID: eventID), cookies: cookies)
        let fields = LectioForms.fields(in: HTMLDocument.parse(html))

        var draft = Draft()
        draft.id = eventID
        draft.title = fields["m$Content$titelTextBox$tb"] ?? ""
        draft.startISO = iso(fields["m$Content$startdateCtrl$_date$tb"])
        draft.startTime = fields["m$Content$startdateCtrl$startdateCtrl_time$tb"] ?? ""
        draft.endISO = iso(fields["m$Content$enddateCtrl$_date$tb"])
        draft.endTime = fields["m$Content$enddateCtrl$enddateCtrl_time$tb"] ?? ""
        draft.note = fields["m$Content$commentTextBox$tb"] ?? ""
        return draft
    }

    /// Removes it for good — Lectio's "Slet" button, which is a postback with
    /// the argument "Delete".
    static func delete(eventID: String, cookies: [HTTPCookie]) async throws {
        let url = formURL(eventID: eventID)
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        let fields = LectioForms.fields(in: HTMLDocument.parse(html))
        _ = try await LectioForms.postBack(
            pageURL: url,
            fields: fields,
            target: "m$Content$savebuttonsCtrl$db",
            argument: "Delete",
            cookies: cookies)
    }

    private static func iso(_ danish: String?) -> String {
        guard let danish = danish, let parsed = LectioDates.parseDanish(danish) else { return "" }
        return parsed.date
    }

    /// Creates a new appointment, or saves an existing one when the draft
    /// carries an id — Lectio uses the same page and the same Gem button.
    static func save(_ draft: Draft, cookies: [HTTPCookie]) async throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw EventError.titleMissing }
        guard title.count <= titleLimit else { throw EventError.titleTooLong }
        guard isOrdered(draft) else { throw EventError.endBeforeStart }

        let url = formURL(eventID: draft.id)
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        var fields = LectioForms.fields(in: HTMLDocument.parse(html))

        // Lectio's own date format is d/m-yyyy — "24/9-2026".
        fields["m$Content$titelTextBox$tb"] = title
        fields["m$Content$startdateCtrl$_date$tb"] = LectioDates.danishDate(iso: draft.startISO)
        fields["m$Content$startdateCtrl$startdateCtrl_time$tb"] = draft.startTime
        fields["m$Content$enddateCtrl$_date$tb"] = LectioDates.danishDate(iso: draft.endISO)
        fields["m$Content$enddateCtrl$enddateCtrl_time$tb"] = draft.endTime
        fields["m$Content$commentTextBox$tb"] = draft.note

        let result = try await LectioForms.postBack(
            pageURL: url,
            fields: fields,
            target: "m$Content$savebuttonsCtrl$svbtn",
            argument: "",
            cookies: cookies)

        // On success Lectio sends you back to the schedule. If the form is
        // still standing, it refused — and usually says why in a validator.
        let after = HTMLDocument.parse(result)
        let stillOnForm = after.firstWhere { $0.attrs["id"] == "m_Content_titelTextBox_tb" } != nil
        if stillOnForm {
            throw EventError.rejected(validationMessage(in: after))
        }
    }

    /// The first validator that actually has something to say.
    private static func validationMessage(in root: HTMLNode) -> String? {
        for node in root.allWhere({ $0.hasClass("alert") }) {
            let style = (node.attr("style") ?? "").replacingOccurrences(of: " ", with: "")
            if style.contains("display:none") { continue }
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "★" { continue }
            return text
        }
        return nil
    }

    private static func isOrdered(_ draft: Draft) -> Bool {
        let start = draft.startISO + " " + draft.startTime
        let end = draft.endISO + " " + draft.endTime
        return end > start
    }
}
