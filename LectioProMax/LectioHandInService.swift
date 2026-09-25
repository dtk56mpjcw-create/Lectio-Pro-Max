import Foundation

/// Handing in an assignment, the way Lectio's own page does it.
///
/// Reverse-engineered from `lectio.bundle.js`: there is no single "upload"
/// endpoint. It's two steps.
///
///   1. POST the file as multipart/form-data to `{school}/dokumentupload.aspx`
///      under the field name `file`. Lectio answers with JSON: {"serializedId": …}.
///      That only puts the file in Lectio's document store — it is NOT attached
///      to anything yet.
///   2. Post the assignment's own ASP.NET form back to itself with
///      `__EVENTTARGET = m$Content$choosedocument`, `__EVENTARGUMENT = documentId`
///      and the serialized id in the hidden `selectedDocumentId` field. That is
///      what actually attaches the document to the assignment.
///
/// Step 2 has to carry Lectio's `__VIEWSTATEX` and `__EVENTVALIDATION` back
/// verbatim, and those are per-request, so the page is always re-fetched first.
enum LectioHandInService {

    /// Its own session: uploads need a far longer timeout than page loads, and
    /// like the rest of the app it manages cookies by hand rather than letting
    /// URLSession keep a store of its own.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    enum UploadError: LocalizedError {
        case notAcceptingHandIns
        case uploadRejected(Int)
        case noDocumentID
        case fileTooLarge
        case postbackRejected(Int)

        var errorDescription: String? {
            switch self {
            case .notAcceptingHandIns:
                return "Lectio isn't accepting hand-ins for this assignment."
            case .uploadRejected(let code):
                return "Lectio refused the upload (\(code))."
            case .noDocumentID:
                return "Lectio accepted the file but didn't return a document id."
            case .fileTooLarge:
                return "That file is too large for Lectio."
            case .postbackRejected(let code):
                return "The file uploaded, but attaching it failed (\(code))."
            }
        }
    }

    // MARK: - Reading

    static func load(pageURL: String, cookies: [HTTPCookie]) async throws -> HandIn {
        let html = try await LectioService.fetchHTML(pageURL, cookies: cookies)
        return LectioParser.parseHandIn(html, pageURL: pageURL)
    }

    // MARK: - Downloading a hand-in

    /// Fetches a document with the session's cookies and drops it in a temp
    /// file. Handing the URL to Safari instead looks like it works, but Safari
    /// has its own cookie jar and may well be met with the login page.
    static func downloadDocument(link: String,
                                 suggestedName: String,
                                 cookies: [HTTPCookie]) async throws -> URL {
        guard let url = URL(string: link) else { throw LectioError.badURL }

        var request = URLRequest(url: url)
        request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        await absorbCookies(from: response)

        let http = response as? HTTPURLResponse
        if LectioService.isLoginWall(http?.url) { throw LectioError.needsLogin }
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UploadError.uploadRejected(status) }
        guard !data.isEmpty else { throw LectioError.emptyBody }

        let name = filename(from: http, fallback: suggestedName)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectioDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = folder.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Lectio names the file in Content-Disposition; the table's text is the
    /// fallback. Either way it has to be safe to use as a path component.
    private static func filename(from response: HTTPURLResponse?, fallback: String) -> String {
        var name = fallback.trimmingCharacters(in: .whitespacesAndNewlines)

        if let header = response?.value(forHTTPHeaderField: "Content-Disposition") {
            if let match = Rx.match("filename\\*=UTF-8''([^;]+)", header),
               let decoded = match[1].removingPercentEncoding, !decoded.isEmpty {
                name = decoded
            } else if let match = Rx.match("filename=\"([^\"]+)\"", header), !match[1].isEmpty {
                name = match[1]
            } else if let match = Rx.match("filename=([^;]+)", header) {
                name = match[1].trimmingCharacters(in: .whitespaces)
            }
        }

        name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Document" : name
    }

    // MARK: - Step 1: put the file in Lectio's document store

    static func uploadDocument(data: Data,
                               filename: String,
                               mimeType: String,
                               cookies: [HTTPCookie]) async throws -> String {
        guard let url = URL(string: LectioConfig.base + "/dokumentupload.aspx") else {
            throw LectioError.badURL
        }

        let boundary = "----LectioProMax" + UUID().uuidString
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(LectioConfig.base + "/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 120        // uploads are not 15-second affairs
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        await absorbCookies(from: response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if LectioService.isLoginWall((response as? HTTPURLResponse)?.url) { throw LectioError.needsLogin }
        if status == 413 { throw UploadError.fileTooLarge }
        guard (200..<300).contains(status) else { throw UploadError.uploadRejected(status) }

        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw UploadError.noDocumentID
        }
        if let id = object["serializedId"] as? String, !id.isEmpty { return id }
        if let number = object["serializedId"] as? NSNumber { return number.stringValue }
        throw UploadError.noDocumentID
    }

    // MARK: - Step 2: attach it to the assignment

    static func attachDocument(serializedID: String,
                               comment: String,
                               to handIn: HandIn,
                               cookies: [HTTPCookie]) async throws -> HandIn {
        // Lectio's own page sends JSON.stringify(documentInfo) here.
        let payload = "{\"serializedId\":\"" + escapeForJSON(serializedID) + "\"}"
        var fields = handIn.form
        fields["m$Content$choosedocument$selectedDocumentId"] = payload
        fields["m$Content$CommentsTB$tb"] = comment
        return try await postBack(fields,
                                  eventTarget: "m$Content$choosedocument",
                                  eventArgument: "documentId",
                                  to: handIn,
                                  cookies: cookies)
    }

    static func sendComment(_ comment: String,
                            to handIn: HandIn,
                            cookies: [HTTPCookie]) async throws -> HandIn {
        var fields = handIn.form
        fields["m$Content$CommentsTB$tb"] = comment
        return try await postBack(fields,
                                  eventTarget: "m$Content$AddEntryBtn",
                                  eventArgument: "",
                                  to: handIn,
                                  cookies: cookies)
    }

    // MARK: - Group hand-in

    /// Adds a classmate to a group hand-in: Lectio's Tilføj button, with them
    /// picked in its dropdown. Returns the page as it stands afterwards.
    static func addGroupMember(_ studentID: String,
                               to handIn: HandIn,
                               cookies: [HTTPCookie]) async throws -> HandIn {
        var fields = handIn.form
        fields["m$Content$groupStudentAddDD"] = studentID
        return try await postBack(fields,
                                  eventTarget: "m$Content$groupStudentAddBtn",
                                  eventArgument: "",
                                  to: handIn,
                                  cookies: cookies)
    }

    /// Takes someone off a group hand-in, with the page's own remove link.
    static func removeGroupMember(_ person: GroupPerson,
                                  from handIn: HandIn,
                                  cookies: [HTTPCookie]) async throws -> HandIn {
        guard let target = person.removeTarget else { return handIn }
        return try await postBack(handIn.form,
                                  eventTarget: target,
                                  eventArgument: person.removeArgument,
                                  to: handIn,
                                  cookies: cookies)
    }

    private static func postBack(_ fields: [String: String],
                                 eventTarget: String,
                                 eventArgument: String,
                                 to handIn: HandIn,
                                 cookies: [HTTPCookie]) async throws -> HandIn {
        guard let url = URL(string: handIn.pageURL) else { throw LectioError.badURL }

        var form = fields
        form["__EVENTTARGET"] = eventTarget
        form["__EVENTARGUMENT"] = eventArgument

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(handIn.pageURL, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 60
        request.httpBody = urlEncoded(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        await absorbCookies(from: response)
        let http = response as? HTTPURLResponse
        if LectioService.isLoginWall(http?.url) { throw LectioError.needsLogin }
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UploadError.postbackRejected(status) }

        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return LectioParser.parseHandIn(html, pageURL: handIn.pageURL)
    }

    /// Keep the session rolling forward, same as the read-only fetches do.
    private static func absorbCookies(from response: URLResponse) async {
        guard let http = response as? HTTPURLResponse,
              let fields = http.allHeaderFields as? [String: String],
              let from = http.url else { return }
        let renewed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: from)
        if !renewed.isEmpty { await CookieCollector.shared.absorb(renewed) }
    }

    // MARK: - Encoding

    /// ASP.NET reads the body as UTF-8 percent-encoding. Lectio even ships a
    /// canary field (`masterfootervalue` = "X1!ÆØÅ") to check the encoding
    /// survived, so this has to be exact.
    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func urlEncoded(_ fields: [String: String]) -> String {
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
            return k + "=" + v
        }.joined(separator: "&")
    }

    private static func escapeForJSON(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
