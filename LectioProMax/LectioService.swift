import Foundation

enum LectioConfig {
    static let schoolIDKey = "lectio.schoolID"
    static let schoolNameKey = "lectio.schoolName"
    /// Nørre Gymnasium. Only a fallback now: installs from before the school
    /// picker never stored a school, and they ran against this one.
    static let defaultSchoolID = "21"

    /// The number in every Lectio address for the school you signed in to.
    static var schoolID: String {
        get { UserDefaults.standard.string(forKey: schoolIDKey) ?? defaultSchoolID }
        set { UserDefaults.standard.set(newValue, forKey: schoolIDKey) }
    }

    /// Whether a school has been picked, so sign-in knows to ask first.
    static var hasChosenSchool: Bool {
        UserDefaults.standard.string(forKey: schoolIDKey) != nil
    }

    /// The school's name as Lectio writes it — from the picker, then kept up
    /// to date from the header of every Lectio page the app reads.
    static var schoolName: String {
        get {
            UserDefaults.standard.string(forKey: schoolNameKey)
                ?? (schoolID == defaultSchoolID ? "Nørre Gymnasium" : "")
        }
        set { UserDefaults.standard.set(newValue, forKey: schoolNameKey) }
    }

    static func choose(_ school: LectioSchool) {
        schoolID = school.id
        schoolName = school.name
    }

    static var base: String { "https://www.lectio.dk/lectio/" + schoolID }
    static var forsideURL: String { base + "/forside.aspx" }
    static var skemaURL: String { base + "/SkemaNy.aspx" }
    static func skemaURL(weekCode: String) -> String {
        return weekCode.isEmpty ? skemaURL : base + "/SkemaNy.aspx?week=" + weekCode
    }
    static var opgaverURL: String { base + "/OpgaverElev.aspx" }
    static var beskederURL: String { base + "/beskeder2.aspx" }
    static var loginURL: String { base + "/login.aspx" }

    /// Deliberately a DESKTOP Safari user-agent. Lectio serves different markup to
    /// mobile clients (note the `OnlyDesktop` cell class the assignments parser
    /// depends on), and the selectors here were reverse-engineered against the
    /// desktop layout — a mobile UA would hide exactly the cells we read.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

enum LectioError: LocalizedError {
    case needsLogin
    case badURL
    case badResponse(Int)
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .needsLogin:
            return "Your Lectio session has expired. Please sign in again."
        case .badURL:
            return "Could not build the Lectio URL."
        case .badResponse(let code):
            return "Lectio returned an unexpected response (\(code))."
        case .emptyBody:
            return "Lectio returned an empty page."
        }
    }
}

/// Lectio rolls its session cookies forward on every authenticated page load
/// (`LastAuthenticatedPageLoad2` is literally a timestamp it rewrites each
/// time). Our URLSession deliberately stores nothing, so every renewed cookie
/// was being thrown away and the app kept replaying the set captured at login
/// until Lectio stopped accepting it — which is what "signs you out" was.
/// This collects what comes back so the session can keep it.
actor CookieCollector {
    static let shared = CookieCollector()
    private var jar: [String: HTTPCookie] = [:]

    func absorb(_ cookies: [HTTPCookie]) {
        for cookie in cookies where cookie.domain.lowercased().contains("lectio.dk") {
            jar[cookie.name] = cookie
        }
    }

    func drain() -> [HTTPCookie] {
        let all = Array(jar.values)
        jar.removeAll()
        return all
    }
}

enum LectioService {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // We manage cookies ourselves, sourced from the WKWebView we logged in with.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Short, because a week load now retries on its own — a long hang is
        // worse than a quick second attempt on a patchy mobile signal.
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Set only for a background check (see BackgroundCheck): a session
    /// with a cookie store of its own, which keeps and sends cookies the way
    /// a browser does. Requests made inside it go through it and let it
    /// handle the cookies; everything else is exactly as before.
    @TaskLocal static var browser: URLSession?

    static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        return cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }

    /// True when a URL is Lectio's login wall or the UNI-Login/MitID broker.
    static func isLoginWall(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString.lowercased() else { return false }
        return s.contains("login.aspx")
            || s.contains("unilogin")
            || s.contains("broker")
            || s.contains("mitid")
            || s.contains("login.microsoftonline")
    }

    static func fetchHTML(_ urlString: String, cookies: [HTTPCookie]) async throws -> String {
        guard let url = URL(string: urlString) else { throw LectioError.badURL }

        let client = browser ?? session
        var request = URLRequest(url: url)
        if browser == nil {
            request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        }
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("da,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await client.data(for: request)

        if let http = response as? HTTPURLResponse {
            // Keep whatever Lectio just handed back, even on a redirect.
            if let fields = http.allHeaderFields as? [String: String], let from = http.url {
                let renewed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: from)
                if !renewed.isEmpty { await CookieCollector.shared.absorb(renewed) }
            }
            if isLoginWall(http.url) { throw LectioError.needsLogin }
            guard (200..<300).contains(http.statusCode) else {
                throw LectioError.badResponse(http.statusCode)
            }
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1), !html.isEmpty else {
            throw LectioError.emptyBody
        }

        // Belt and braces: Lectio sometimes serves the login page at a 200.
        if html.contains("unilogin.dk") && html.contains("Loginvælger") {
            throw LectioError.needsLogin
        }

        return html
    }

    /// Raw bytes with the session's cookies — used for the profile picture,
    /// which AsyncImage can't load since it wouldn't send our cookies.
    static func fetchData(_ urlString: String, cookies: [HTTPCookie]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LectioError.badURL }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Fetches a single message's body text for the message detail sheet.
    static func fetchMessageBody(link: String, cookies: [HTTPCookie]) async throws -> String {
        let html = try await fetchHTML(link, cookies: cookies)
        let root = HTMLDocument.parse(html)
        if let content = root.allWithClass("message-thread-message-content").first {
            return content.text
        }
        if let alt = root.firstWhere({ ($0.attr("id") ?? "").contains("MessageThread") }) {
            return alt.text
        }
        return ""
    }

    /// Fetches one specific week of the schedule (for the swipe pager).
    static func fetchWeek(code: String, cookies: [HTTPCookie]) async throws -> ScheduleWeek {
        let html = try await fetchHTML(LectioConfig.skemaURL(weekCode: code), cookies: cookies)
        var week = LectioParser.parseSchedule(html).week
        if week.code.isEmpty { week.code = code }
        if week.label.isEmpty { week.label = LectioDates.weekLabel(code: code) }
        return week
    }

    private static func attempt(_ url: String, cookies: [HTTPCookie]) async -> Result<String, Error> {
        do { return .success(try await fetchHTML(url, cookies: cookies)) }
        catch { return .failure(error) }
    }

    /// Fetches the three pages the dashboard needs and parses them natively.
    static func loadSnapshot(cookies: [HTTPCookie]) async throws -> LectioSnapshot {
        guard !cookies.isEmpty else { throw LectioError.needsLogin }

        async let forsideTask = attempt(LectioConfig.forsideURL, cookies: cookies)
        async let skemaTask = attempt(LectioConfig.skemaURL, cookies: cookies)
        async let opgaverTask = attempt(LectioConfig.opgaverURL, cookies: cookies)
        // The dashboard block only carries a handful of homework items and
        // truncates each one with "[...]". The Lektier overview has all of them,
        // with the lesson they belong to.
        async let lektierTask = attempt(LectioConfig.base + "/material_lektieoversigt.aspx", cookies: cookies)

        // forside.aspx is the one page we treat as authoritative about whether
        // the session is still alive. If the schedule or the assignments page
        // hiccups, that is not a reason to throw the user back to the login
        // screen — it used to be, and one bad response signed them out.
        let forside = try await forsideTask.get()
        let skema = (try? await skemaTask.get()) ?? ""
        let opgaver = (try? await opgaverTask.get()) ?? ""
        let lektier = (try? await lektierTask.get()) ?? ""

        // forside.aspx feeds four different parsers. Tokenize it ONCE — doing it
        // per parser meant six full parses per refresh, which is most of what
        // made a refresh feel slow.
        let forsideRoot = HTMLDocument.parse(forside)
        let scheduleResult = skema.isEmpty
            ? LectioParser.ScheduleResult()
            : LectioParser.parseSchedule(root: HTMLDocument.parse(skema))
        let messagesResult = LectioParser.parseMessages(root: forsideRoot)

        var snapshot = LectioSnapshot()
        snapshot.weekLabel = scheduleResult.week.label
        snapshot.currentWeekCode = scheduleResult.week.code
        if !scheduleResult.week.code.isEmpty {
            snapshot.weeks[scheduleResult.week.code] = scheduleResult.week
        }
        snapshot.schedule = scheduleResult.week.days
        if lektier.isEmpty {
            snapshot.homework = LectioParser.parseHomework(root: forsideRoot)
        } else {
            snapshot.homework = LectioParser.parseLessonNotes(lektier).map { note in
                HomeworkItem(code: note.code,
                             title: note.displayTitle,
                             due: note.date,
                             time: note.start,
                             text: [note.homework, note.note]
                                .filter { !$0.isEmpty }
                                .joined(separator: "\n\n"),
                             link: note.link)
            }
        }
        snapshot.assignments = opgaver.isEmpty
            ? []
            : LectioParser.parseAssignments(root: HTMLDocument.parse(opgaver))
        snapshot.messages = messagesResult.messages
        snapshot.unreadMessages = messagesResult.unread
        snapshot.profile = LectioParser.parseProfile(root: forsideRoot)
        if let school = snapshot.profile.schoolName, !school.isEmpty {
            LectioConfig.schoolName = school
        }

        snapshot.fetchedAt = Date()
        return snapshot
    }
}
