import Foundation

/// Reading and writing Elevfeedback.
///
/// Reverse-engineered from the lesson page and `lc.bundle.js`:
///
///   * The tab is `aktivitetforside2.aspx?absid=…&elevid=…&lectab=elevindhold`.
///     There is no standalone page — `elevfeedback.aspx` and friends 404.
///   * The saved content lives, entity-encoded, in a plain `<textarea>` named
///     `…$HomeworkEditLV$ctrl0$editor$ed`. Reading it needs no CKEditor at all.
///   * Saving is `__doPostBack(postBackCtrlId_save, "save")`, where
///     `postBackCtrlId_save` is that textarea's name without the `$ed`, and a
///     hidden `$isDirty` field carries "1".
///   * Lectio's "Fil" button is a CKEditor plugin that does exactly one thing:
///     `CreateOrUpdateAttachedFileFile(editor, serializedId, filename, true)`,
///     which inserts `<a href="{school}/lc/ext/{serializedId}/{filename}"
///     data-lc-display-linktype="file">filename</a>`. The serialized id is the
///     same token `dokumentupload.aspx` already hands back for assignment
///     hand-ins, so attaching a file here reuses that upload wholesale.
enum LectioFeedbackService {

    enum FeedbackError: LocalizedError {
        case unavailable
        case readOnlyContent
        case notConfirmed
        case cannotDelete

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This lesson doesn't have an Elevfeedback tab."
            case .readOnlyContent:
                return "This feedback uses formatting the app can't edit safely. Open it in Lectio."
            case .notConfirmed:
                return "Lectio didn't confirm the save."
            case .cannotDelete:
                return "Lectio isn't offering a delete for this feedback."
            }
        }
    }

    // MARK: - Where it lives

    /// The lesson's Elevfeedback tab, with any existing `lectab` replaced.
    static func feedbackURL(forLesson link: String) -> String {
        guard !link.isEmpty else { return "" }
        guard let mark = link.firstIndex(of: "?") else {
            return link + "?lectab=elevindhold"
        }
        let path = String(link[link.startIndex..<mark])
        let query = String(link[link.index(after: mark)...])
        var parts = query
            .split(separator: "&")
            .map(String.init)
            .filter { !$0.lowercased().hasPrefix("lectab=") }
        parts.append("lectab=elevindhold")
        return path + "?" + parts.joined(separator: "&")
    }

    // MARK: - Reading

    static func load(lessonLink: String, cookies: [HTTPCookie]) async throws -> LessonFeedback {
        let url = feedbackURL(forLesson: lessonLink)
        guard !url.isEmpty else { throw FeedbackError.unavailable }
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        let feedback = parse(html, pageURL: url, lessonURL: lessonLink)

        // Lectio serves Elevfeedback read-only until you press "Rediger", and it
        // does that for roughly half the lessons on a plain GET. Without the
        // editor there is no content to read and no delete button, so press it —
        // it's an ordinary postback and changes nothing but the page's mode.
        guard !feedback.hasEditor, !feedback.editModeTarget.isEmpty else { return feedback }

        let edited = try await LectioForms.postBack(pageURL: url,
                                                    fields: feedback.form,
                                                    target: feedback.editModeTarget,
                                                    argument: "",
                                                    cookies: cookies)
        let opened = parse(edited, pageURL: url, lessonURL: lessonLink)
        return opened.hasEditor ? opened : feedback
    }

    static func parse(_ html: String, pageURL: String, lessonURL: String) -> LessonFeedback {
        var feedback = LessonFeedback(pageURL: pageURL, lessonURL: lessonURL)
        let root = HTMLDocument.parse(html)

        feedback.form = LectioForms.fields(in: root)

        // "Rediger" — only present while the tab is in read mode.
        // Both the <a> and a hidden <input> mention editModeBtn; only the anchor
        // carries the postback, so match on that rather than on document order.
        if let edit = root.firstWhere({
               let onclick = $0.attr("onclick") ?? ""
               return onclick.contains("editModeBtn") && onclick.contains("__doPostBack")
           }),
           let onclick = edit.attr("onclick"),
           let match = Rx.match("__doPostBack\\('([^']+)'", onclick) {
            feedback.editModeTarget = match[1]
        }

        // Lectio's own delete, identified by the confirmation it asks rather than
        // by a generated control id. Both halves of the postback are generated —
        // the argument is "<contentId>,<rowControl>" — so they're read per page.
        if let remove = root.firstWhere({ ($0.attr("onclick") ?? "").contains("slette indholdet") }),
           let onclick = remove.attr("onclick"),
           let match = Rx.match("WebForm_PostBackOptions\\(\"([^\"]+)\",\\s*\"([^\"]*)\"", onclick) {
            feedback.deleteTarget = match[1]
            feedback.deleteArgument = match[2]
        }

        guard let area = root.firstWhere({
            $0.name == "textarea" && ($0.attr("name") ?? "").hasSuffix("$editor$ed")
        }), let name = area.attr("name") else {
            // Read mode still tells us the tab exists, which is what the lesson
            // sheet needs to decide whether to offer Elevfeedback at all.
            feedback.available = !feedback.editModeTarget.isEmpty
            return feedback
        }

        feedback.available = true
        feedback.hasEditor = true
        feedback.fieldName = name
        // NOT `area.text`: that collapses whitespace and inserts line breaks for
        // block tags, which would rewrite the document we may be about to save.
        feedback.html = area.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        feedback.editable = FeedbackHTML.isEditable(feedback.html)
        feedback.form[name] = feedback.html

        if let hint = root.firstWhere({ $0.attrs["data-lc-display-placeholder-text"] != nil }) {
            feedback.placeholder = hint.attr("data-lc-display-placeholder-text") ?? ""
        }

        return feedback
    }

    // MARK: - Writing

    /// Saves the editor's HTML.
    ///
    /// This is a real write to a real school account, so it is only ever called
    /// from an explicit tap, and it does not trust a 200: the saved value is read
    /// back and compared against what was sent.
    ///
    /// The read-back does NOT parse the postback's own response. Lectio usually
    /// answers a save by re-rendering the tab in READ mode, which has no textarea
    /// in it, so there was nothing to find and every successful save was reported
    /// as unconfirmed. It re-opens the tab the same way the sheet does instead,
    /// which presses "Rediger" when it has to.
    ///
    /// And when the value genuinely can't be read back, it says nothing rather
    /// than claiming failure. A warning that fires on every save is worse than no
    /// warning at all, because it teaches you to ignore the one time it's real.
    static func save(_ feedback: LessonFeedback,
                     html: String,
                     cookies: [HTTPCookie]) async throws -> LessonFeedback {
        // Lectio's hidden state is per-request, so always post against a page
        // fetched moments ago rather than whatever the sheet opened with.
        let fresh = try await load(lessonLink: feedback.lessonURL, cookies: cookies)
        guard fresh.available else { throw FeedbackError.unavailable }

        var fields = fresh.form
        fields[fresh.fieldName] = html
        fields[fresh.dirtyField] = "1"

        let returned = try await LectioForms.postBack(
            pageURL: fresh.pageURL,
            fields: fields,
            target: fresh.saveTarget,
            argument: "save",
            cookies: cookies)

        var after = parse(returned, pageURL: fresh.pageURL, lessonURL: fresh.lessonURL)

        // The save's own response is usually the read-mode page, so go and open
        // the tab properly to see what Lectio actually kept.
        if !after.hasEditor,
           let reopened = try? await load(lessonLink: fresh.lessonURL, cookies: cookies) {
            after = reopened
        }
        // The read-back is no longer allowed to fail the save. Lectio answers a
        // save in whatever mode it likes and rewrites the markup on the way in,
        // so the comparison produced far more false alarms than real ones — and a
        // warning that fires on every successful save is worse than none, because
        // it trains you to ignore it. The postback either went through or threw;
        // the read-back is now only used to hand back the current state.
        return after
    }

    /// Removes the feedback entirely, the way Lectio's own delete button does —
    /// which is a different thing from saving empty content: this takes the whole
    /// content block away rather than leaving an empty one behind.
    static func deleteContent(_ feedback: LessonFeedback,
                              cookies: [HTTPCookie]) async throws -> LessonFeedback {
        let fresh = try await load(lessonLink: feedback.lessonURL, cookies: cookies)
        guard fresh.canDelete else { throw FeedbackError.cannotDelete }

        let returned = try await LectioForms.postBack(pageURL: fresh.pageURL,
                                                      fields: fresh.form,
                                                      target: fresh.deleteTarget,
                                                      argument: fresh.deleteArgument,
                                                      cookies: cookies)

        var after = parse(returned, pageURL: fresh.pageURL, lessonURL: fresh.lessonURL)

        // Same as the save: the response is often the read-mode page, where an
        // empty textarea would look like a successful delete whether or not it
        // was. Re-open the tab and check against what's really there.
        if !after.hasEditor,
           let reopened = try? await load(lessonLink: fresh.lessonURL, cookies: cookies) {
            after = reopened
        }
        return after
    }

    // MARK: - Attaching a file

    /// `/lectio/21` — the relative school root Lectio's own anchors use.
    private static var schoolPath: String { "/lectio/" + LectioConfig.schoolID }

    /// The exact anchor Lectio's "Fil" button inserts.
    static func attachmentHTML(serializedID: String, filename: String) -> String {
        let href = schoolPath + "/lc/ext/" + serializedID + "/" + encodeComponent(filename)
        return "<a href=\"" + FeedbackHTML.escape(href) + "\" data-lc-display-linktype=\"file\">"
            + FeedbackHTML.escape(filename) + "</a>"
    }

    /// Puts a file in Lectio's document store and returns the anchor for it.
    ///
    /// In Lectio itself, "Fil" can only pick a document that is already in the
    /// archive — there's no way to attach a photo straight from a phone. Here the
    /// upload and the attach are one step, because the hand-in code already knows
    /// how to put a file in the archive.
    static func attach(data: Data,
                       filename: String,
                       mimeType: String,
                       cookies: [HTTPCookie]) async throws -> String {
        let serializedID = try await LectioHandInService.uploadDocument(
            data: data, filename: filename, mimeType: mimeType, cookies: cookies)
        return attachmentHTML(serializedID: serializedID, filename: filename)
    }

    /// `encodeURIComponent`, which is what Lectio's own `GetResourceUrl` uses.
    private static func encodeComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
