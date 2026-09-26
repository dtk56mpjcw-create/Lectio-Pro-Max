import Foundation

/// Reading and sending Lectio messages.
///
/// Nothing here is an API call. Opening a thread is a plain GET
/// (`beskeder2.aspx?type=visbesked&id=…`), but everything that *changes*
/// something — replying, sending, marking read, flagging — is the whole page
/// posted back to itself with `__EVENTTARGET` naming the control that was
/// "clicked". See LectioForms for that plumbing.
enum LectioMessagesService {

    enum MessageError: LocalizedError {
        case cannotReply
        case noRecipients
        case sendFailed
        case attachFailed(String)

        var errorDescription: String? {
            switch self {
            case .attachFailed(let name):
                return "Lectio didn't take “\(name)”. Nothing was sent."
            case .cannotReply:
                return "This thread can't be replied to directly."
            case .noRecipients:
                return "Add at least one recipient."
            case .sendFailed:
                return "Lectio didn't accept the message."
            }
        }
    }

    static var inboxURL: String { LectioConfig.base + "/beskeder2.aspx" }
    static var newMessageURL: String { LectioConfig.base + "/beskeder2.aspx?type=nybesked" }
    static func threadURL(_ id: String) -> String {
        return LectioConfig.base + "/beskeder2.aspx?type=visbesked&id=" + id
    }

    // MARK: - Reading

    /// Always asks for Nyeste by id. Plain beskeder2.aspx shows whichever
    /// folder you looked at last — Lectio remembers it — so after a visit to
    /// Deleted, the "inbox" came back as the deleted messages.
    static func loadInbox(cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        return try await loadFolder(.newest, cookies: cookies)
    }

    static func loadThread(id: String, cookies: [HTTPCookie]) async throws -> MessageThread {
        let url = threadURL(id)
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        return LectioParser.parseThread(html, id: id, pageURL: url)
    }

    // MARK: - Replying

    static func reply(to thread: MessageThread,
                      body: String,
                      attachments: [OutgoingAttachment] = [],
                      cookies: [HTTPCookie]) async throws -> MessageThread {
        // Re-read first: the page's hidden state is per-request.
        var current = try await loadThread(id: thread.id, cookies: cookies)

        // On some threads the composer only exists after "Besvar" is pressed.
        if current.composerPrefix.isEmpty {
            let html = try await LectioForms.postBack(
                pageURL: current.pageURL,
                fields: current.form,
                target: "s$m$Content$Content$MessageThreadCtrl$ReplyThreadBtn",
                argument: "",
                cookies: cookies)
            current = LectioParser.parseThread(html, id: thread.id, pageURL: current.pageURL)
        }
        guard !current.composerPrefix.isEmpty else { throw MessageError.cannotReply }

        // Each file goes on the way Lectio's "Vedhæft fil" puts it on: into
        // the document store, then a postback naming it. The reply's text
        // rides along each time so the page keeps it.
        for attachment in attachments {
            let prefix = current.composerPrefix
            var fields = current.form
            fields[prefix + "$EditModeContentBBTB$TbxNAME$tb"] = body
            let html = try await attach(attachment, composer: prefix, fields: fields,
                                        pageURL: current.pageURL, cookies: cookies)
            current = LectioParser.parseThread(html, id: thread.id, pageURL: current.pageURL)
            guard !current.composerPrefix.isEmpty else { throw MessageError.attachFailed(attachment.filename) }
        }

        var fields = current.form
        fields[current.composerPrefix + "$EditModeContentBBTB$TbxNAME$tb"] = body

        let html = try await LectioForms.postBack(
            pageURL: current.pageURL,
            fields: fields,
            target: current.composerPrefix + "$SendMessageBtn",
            argument: "",
            cookies: cookies)

        return LectioParser.parseThread(html, id: thread.id, pageURL: current.pageURL)
    }

    // MARK: - New thread

    static func createThread(to recipients: [Recipient],
                             subject: String,
                             body: String,
                             attachments: [OutgoingAttachment] = [],
                             cookies: [HTTPCookie]) async throws -> Bool {
        guard !recipients.isEmpty else { throw MessageError.noRecipients }

        var html = try await LectioService.fetchHTML(newMessageURL, cookies: cookies)
        var root = HTMLDocument.parse(html)

        // Recipients go on one at a time: fill the autocomplete's text and id
        // fields, then press "Tilføj modtager" — exactly what the page does.
        for recipient in recipients {
            guard let inputName = root.firstWhere({
                $0.name == "input" && ($0.attr("name") ?? "").hasSuffix("$addRecipientDD$inp")
            })?.attr("name") else { break }

            let prefix = String(inputName.dropLast("$inp".count))
            var fields = LectioForms.fields(in: root)
            fields[prefix + "$inp"] = recipient.name
            fields[prefix + "$inpid"] = recipient.id

            html = try await LectioForms.postBack(
                pageURL: newMessageURL,
                fields: fields,
                target: addRecipientTarget(in: root) ?? "s$m$Content$Content$MessageThreadCtrl$AddRecipientBtn",
                argument: "",
                cookies: cookies)
            root = HTMLDocument.parse(html)
        }

        guard var composer = composerPrefix(in: root) else { throw MessageError.sendFailed }

        for attachment in attachments {
            var fields = LectioForms.fields(in: root)
            fields[composer + "$EditModeHeaderTitleTB$tb"] = subject
            fields[composer + "$EditModeContentBBTB$TbxNAME$tb"] = body
            html = try await attach(attachment, composer: composer, fields: fields,
                                    pageURL: newMessageURL, cookies: cookies)
            root = HTMLDocument.parse(html)
            guard let next = composerPrefix(in: root) else {
                throw MessageError.attachFailed(attachment.filename)
            }
            composer = next
        }

        var fields = LectioForms.fields(in: root)
        fields[composer + "$EditModeHeaderTitleTB$tb"] = subject
        fields[composer + "$EditModeContentBBTB$TbxNAME$tb"] = body

        let result = try await LectioForms.postBack(
            pageURL: newMessageURL,
            fields: fields,
            target: composer + "$SendMessageBtn",
            argument: "",
            cookies: cookies)

        // Lectio leaves the compose form standing if it rejected the message.
        let after = HTMLDocument.parse(result)
        return composerPrefix(in: after) == nil || after.firstWhere {
            $0.hasClass("message-thread-message")
        } != nil
    }

    // MARK: - Attachments

    /// A file to send with a message.
    struct OutgoingAttachment: Identifiable, Hashable {
        let id = UUID()
        var data: Data
        var filename: String
        var mimeType: String
    }

    /// Lectio's "Vedhæft fil", done by hand: upload the file to
    /// dokumentupload.aspx (the same store hand-ins use), then post the
    /// composer back naming it —
    ///   selectedDocumentId = JSON.stringify(documentInfo)
    ///   __doPostBack('<composer>$AttachmentDocChooser', 'documentId')
    /// — which is exactly what the page's script does after its file dialog.
    private static func attach(_ attachment: OutgoingAttachment,
                               composer: String,
                               fields: [String: String],
                               pageURL: String,
                               cookies: [HTTPCookie]) async throws -> String {
        let serializedID = try await LectioHandInService.uploadDocument(
            data: attachment.data,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            cookies: cookies)

        let info = (try? JSONSerialization.data(withJSONObject: ["serializedId": serializedID]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"serializedId\":\"\(serializedID)\"}"

        var form = fields
        form[composer + "$AttachmentDocChooser$selectedDocumentId"] = info
        return try await LectioForms.postBack(
            pageURL: pageURL,
            fields: form,
            target: composer + "$AttachmentDocChooser",
            argument: "documentId",
            cookies: cookies)
    }

    // MARK: - Folders

    static func folderURL(_ folder: MessageFolder) -> String {
        return inboxURL + "?mappeid=" + String(folder.rawValue)
    }

    static func loadFolder(_ folder: MessageFolder, cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        let html = try await LectioService.fetchHTML(folderURL(folder), cookies: cookies)
        return LectioParser.parseInbox(html)
    }

    // MARK: - Read state, flags, deleting
    //
    // Each row's icons post `__Page` back with a command and the thread id.
    // Read state is two commands, not a toggle: a thread you haven't read
    // offers READMESSAGE_, one you have offers UNREADMESSAGE_ (always sending
    // READMESSAGE_ is why "Mark as unread" did nothing). Deleting is
    // HIDEMESSAGE_ — Lectio's "Slet": it moves the thread to Deleted, where
    // the row offers UNHIDEMESSAGE_ ("Gendan") to bring it back.
    //
    // The command is posted to the folder the thread is showing in: ASP.NET
    // only accepts a command the page it came from actually offered.

    static func setRead(threadID: String,
                        read: Bool,
                        in folder: MessageFolder,
                        cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        let command = (read ? "READMESSAGE_" : "UNREADMESSAGE_") + threadID
        return try await folderCommand(command, in: folder, cookies: cookies)
    }

    static func toggleFlag(threadID: String,
                           in folder: MessageFolder,
                           cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        return try await folderCommand("FLAGMESSAGE_" + threadID, in: folder, cookies: cookies)
    }

    /// Deletes a thread (HIDEMESSAGE_) or brings it back (UNHIDEMESSAGE_ —
    /// what a row in Alle slettede offers; it isn't the same command twice).
    /// Lectio has no way to delete for good: deleted threads leave that
    /// folder on their own after three months.
    static func setDeleted(threadID: String,
                           deleted: Bool,
                           in folder: MessageFolder,
                           cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        let command = (deleted ? "HIDEMESSAGE_" : "UNHIDEMESSAGE_") + threadID
        return try await folderCommand(command, in: folder, cookies: cookies)
    }

    private static func folderCommand(_ argument: String,
                                      in folder: MessageFolder,
                                      cookies: [HTTPCookie]) async throws -> [MessageThreadSummary] {
        let url = folderURL(folder)
        let html = try await LectioService.fetchHTML(url, cookies: cookies)
        let fields = LectioForms.fields(in: HTMLDocument.parse(html))
        let result = try await LectioForms.postBack(
            pageURL: url,
            fields: fields,
            target: "__Page",
            argument: argument,
            cookies: cookies)
        return LectioParser.parseInbox(result)
    }

    // MARK: - Who you can write to

    /// Lectio's recipient autocomplete is backed by cached JSON dropdowns whose
    /// URLs are registered inline on the compose page — one per kind of
    /// recipient. `&reduced=0` asks for the complete list rather than the
    /// shortened one the page loads first.
    static func recipientDirectory(cookies: [HTTPCookie]) async throws -> [Recipient] {
        let html = try await LectioService.fetchHTML(newMessageURL, cookies: cookies)

        var sources: [(key: String, url: String)] = []
        let pattern = "registerDataSetUrl\\('([^']+)',\\s*'([^']+)'\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            sources.append((ns.substring(with: match.range(at: 1)),
                            ns.substring(with: match.range(at: 2))))
        }

        var byID: [String: Recipient] = [:]
        for source in sources {
            let kind = kindFor(source.key)
            guard kind != nil else { continue }
            var path = source.url
            if !path.contains("&reduced=0") { path += "&reduced=0" }
            let full = path.hasPrefix("http") ? path : "https://www.lectio.dk" + path

            guard let url = URL(string: full) else { continue }
            var request = URLRequest(url: url)
            request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
            request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 45

            guard let (data, _) = try? await LectioForms.session.data(for: request),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[Any]] else { continue }

            for row in items {
                guard row.count >= 2,
                      let name = row[0] as? String,
                      let id = row[1] as? String,
                      !name.isEmpty, !id.isEmpty else { continue }
                byID[id] = Recipient(id: id, name: name, kind: kind!)
            }
        }

        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func kindFor(_ key: String) -> Recipient.RecipientKind? {
        if key.hasPrefix("bcteacher") { return .teacher }
        if key.hasPrefix("bcstudent") { return .student }
        if key.hasPrefix("bchold") { return .team }
        if key.hasPrefix("bcgroup") { return .group }
        return nil
    }

    private static func composerPrefix(in root: HTMLNode) -> String? {
        guard let name = root.firstWhere({
            $0.name == "textarea" && ($0.attr("name") ?? "").contains("EditModeContentBBTB")
        })?.attr("name"), let cut = name.range(of: "$EditModeContentBBTB") else { return nil }
        return String(name[..<cut.lowerBound])
    }

    private static func addRecipientTarget(in root: HTMLNode) -> String? {
        guard let id = root.firstWhere({ ($0.attrs["id"] ?? "").hasSuffix("AddRecipientBtn") })?.attrs["id"]
        else { return nil }
        return id.replacingOccurrences(of: "_", with: "$")
    }
}
