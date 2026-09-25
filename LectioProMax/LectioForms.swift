import Foundation

/// Lectio is a classic ASP.NET WebForms app: nothing is a REST call. Every
/// action is the whole page posted back to itself with `__EVENTTARGET` naming
/// the control you "clicked", and the server refuses anything that doesn't
/// return its own hidden state (`__VIEWSTATEX`, `__VIEWSTATEY_KEY`,
/// `__EVENTVALIDATION`) untouched. This is the shared plumbing for that.
enum LectioForms {

    /// Every field the browser would resubmit, read out of a parsed page.
    static func fields(in root: HTMLNode, formID: String = "aspnetForm") -> [String: String] {
        guard let form = root.firstWhere({ $0.attrs["id"] == formID }) else { return [:] }
        var fields: [String: String] = [:]

        for input in form.all("input") {
            guard let name = input.attr("name"), !name.isEmpty else { continue }
            if input.attrs["disabled"] != nil { continue }
            let type = (input.attr("type") ?? "text").lowercased()
            // Buttons are only submitted when they're the one you clicked, and
            // we say which that was via __EVENTTARGET instead.
            if type == "submit" || type == "button" || type == "image" || type == "reset" { continue }
            if type == "checkbox" || type == "radio" {
                if input.attrs["checked"] == nil { continue }
                fields[name] = input.attr("value") ?? "on"
                continue
            }
            fields[name] = input.attr("value") ?? ""
        }

        for area in form.all("textarea") {
            guard let name = area.attr("name"), !name.isEmpty else { continue }
            if area.attrs["disabled"] != nil { continue }
            fields[name] = area.text
        }

        for select in form.all("select") {
            guard let name = select.attr("name"), !name.isEmpty else { continue }
            if select.attrs["disabled"] != nil { continue }
            let options = select.all("option")
            let chosen = options.first { $0.attrs["selected"] != nil } ?? options.first
            fields[name] = chosen?.attr("value") ?? ""
        }

        return fields
    }

    /// Posts a page back to itself as if a control had been activated, and
    /// returns the HTML that comes back.
    static func postBack(pageURL: String,
                         fields: [String: String],
                         target: String,
                         argument: String,
                         cookies: [HTTPCookie]) async throws -> String {
        guard let url = URL(string: pageURL) else { throw LectioError.badURL }

        var form = fields
        form["__EVENTTARGET"] = target
        form["__EVENTARGUMENT"] = argument

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(pageURL, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 60
        request.httpBody = encoded(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        await absorbCookies(from: response)

        let http = response as? HTTPURLResponse
        if LectioService.isLoginWall(http?.url) { throw LectioError.needsLogin }
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LectioError.badResponse(status) }

        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func absorbCookies(from response: URLResponse) async {
        guard let http = response as? HTTPURLResponse,
              let headers = http.allHeaderFields as? [String: String],
              let from = http.url else { return }
        let renewed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: from)
        if !renewed.isEmpty { await CookieCollector.shared.absorb(renewed) }
    }

    /// ASP.NET reads the body as UTF-8 percent-encoding, and Lectio ships a
    /// canary field (`masterfootervalue` = "X1!ÆØÅ") to check it survived.
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encoded(_ fields: [String: String]) -> String {
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return k + "=" + v
        }.joined(separator: "&")
    }
}
