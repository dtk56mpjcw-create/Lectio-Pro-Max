import Foundation

// MARK: - The cookie jar

/// The Lectio session, as cookies: the one place every request reads them
/// from and every response writes them back to.
///
/// How Lectio keeps you signed in: `ASP.NET_SessionId` is the session and
/// runs out after a while; `autologinkeyV2` is the long-lived key. A request
/// that carries the key but no live session is quietly given a new session
/// — Lectio's own "stay signed in". So the key is the thing to protect:
///
/// - Lectio sometimes answers with an empty value for either cookie. That
///   is never taken as an instruction to forget it — it used to wipe the
///   key, and the next expired session meant signing in again.
/// - One jar, read when each request is sent, rather than a copy handed
///   around: a new session picked up by one request is what the next uses.
/// - When the session may have run out (nothing's succeeded for a few
///   minutes), the first request goes alone; the rest wait for it and use
///   the cookies it came back with, instead of each starting a renewal of
///   its own and overwriting the others'.
///
/// Kept in the Keychain (see CookieVault) — only on this phone, never in
/// backups.
actor LectioCookies {
    static let shared = LectioCookies()

    static let keyName = "autologinkeyv2"
    static let sessionName = "asp.net_sessionid"
    /// The two that must never be dropped because of an empty answer.
    static let guarded: Set<String> = [keyName, sessionName]

    /// After this long without a successful request, the session may have
    /// run out: the next request is a probe (see `begin`).
    static let quietPeriod: TimeInterval = 5 * 60

    private var jar: [String: HTTPCookie] = [:]
    private var loaded = false
    private var lastSaved = Date.distantPast
    private var lastGood: Date?
    private var probing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        for cookie in CookieVault.load() { jar[cookie.name] = cookie }
    }

    // MARK: Reading

    /// The cookies as they stand: not expired, not empty.
    func snapshot() -> [HTTPCookie] {
        ensureLoaded()
        let now = Date()
        return jar.values.filter { !$0.value.isEmpty && ($0.expiresDate.map { $0 > now } ?? true) }
    }

    /// The `Cookie` header for a request to Lectio.
    func header() -> String {
        snapshot().map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }

    /// The session cookie's value now, to tell whether another request has
    /// renewed it meanwhile.
    func sessionValue() -> String? {
        snapshot().first { $0.name.lowercased() == Self.sessionName }?.value
    }

    /// Whether there's anything to sign in with.
    func hasCredentials() -> Bool {
        snapshot().contains { Self.guarded.contains($0.name.lowercased()) }
    }

    /// For the test screen: which of the two are there, and until when.
    struct Status {
        var hasKey = false
        var keyExpires: Date?
        var hasSession = false
        var lastGood: Date?
    }

    func status() -> Status {
        let live = snapshot()
        let key = live.first { $0.name.lowercased() == Self.keyName }
        return Status(hasKey: key != nil,
                      keyExpires: key?.expiresDate,
                      hasSession: live.contains { $0.name.lowercased() == Self.sessionName },
                      lastGood: lastGood)
    }

    // MARK: Writing

    /// What a response handed back.
    func absorb(from response: HTTPURLResponse) {
        guard let url = response.url,
              let fields = response.allHeaderFields as? [String: String] else { return }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !incoming.isEmpty { absorb(incoming) }
    }

    /// Cookies from anywhere — a response, WebKit after a sign-in or a
    /// renewal — by the rules in `merged`.
    func absorb(_ incoming: [HTTPCookie]) {
        ensureLoaded()
        let before = jar
        jar = Self.merged(jar, incoming, now: Date())
        save(changedFrom: before)
    }

    /// A new sign-in: exactly what WebKit has now, nothing kept from before.
    func replace(with cookies: [HTTPCookie]) {
        ensureLoaded()
        jar = Self.merged([:], cookies, now: Date())
        lastGood = nil
        CookieVault.save(Array(jar.values))
        lastSaved = Date()
    }

    /// Only the first time: cookies passed in by a caller, when the jar has
    /// nothing (an install from before the jar).
    func seedIfEmpty(_ cookies: [HTTPCookie]) {
        ensureLoaded()
        if jar.isEmpty && !cookies.isEmpty { absorb(cookies) }
    }

    /// Lectio's own renewal: without the dead session cookie, the key is
    /// given a new session. False when there's no key to renew with.
    @discardableResult
    func dropSession() -> Bool {
        ensureLoaded()
        guard jar.keys.contains(where: { $0.lowercased() == Self.keyName }) else { return false }
        let names = jar.keys.filter { $0.lowercased() == Self.sessionName }
        guard !names.isEmpty else { return false }
        for name in names { jar[name] = nil }
        lastGood = nil
        CookieVault.save(Array(jar.values))
        lastSaved = Date()
        return true
    }

    /// Signing out.
    func clear() {
        jar = [:]
        loaded = true
        lastGood = nil
        CookieVault.clear()
    }

    /// The rules for taking in cookies. Pure, for the tests.
    ///
    /// - The key and the session are only ever replaced by a real value;
    ///   an empty or already-expired one is ignored.
    /// - Anything else follows the usual rules: a new value replaces the
    ///   old, an empty or expired one removes it.
    static func merged(_ jar: [String: HTTPCookie], _ incoming: [HTTPCookie],
                       now: Date) -> [String: HTTPCookie] {
        var out = jar
        for cookie in incoming where cookie.domain.lowercased().contains("lectio.dk") || cookie.domain.isEmpty {
            let dead = cookie.value.isEmpty || (cookie.expiresDate.map { $0 <= now } ?? false)
            if guarded.contains(cookie.name.lowercased()) {
                if dead { continue }
                // One of each, whatever the case Lectio writes it in.
                for name in out.keys where name.lowercased() == cookie.name.lowercased() { out[name] = nil }
                out[cookie.name] = cookie
            } else if dead {
                out[cookie.name] = nil
            } else {
                out[cookie.name] = cookie
            }
        }
        return out
    }

    /// Written to the Keychain at once when the key or the session changes;
    /// the rest (Lectio rewrites a timestamp cookie on every page) at most
    /// once a minute.
    private func save(changedFrom before: [String: HTTPCookie]) {
        func vital(_ jar: [String: HTTPCookie]) -> [String] {
            jar.filter { Self.guarded.contains($0.key.lowercased()) }
                .map { $0.key + "=" + $0.value.value }.sorted()
        }
        let vitalChanged = vital(before) != vital(jar)
        guard vitalChanged || Date().timeIntervalSince(lastSaved) > 60 else { return }
        CookieVault.save(Array(jar.values))
        lastSaved = Date()
    }

    // MARK: One at a time, when it matters

    /// Before a request. Returns true when this request is the probe: the
    /// session may have run out, so it goes alone, and the others wait for
    /// its cookies.
    func begin() async -> Bool {
        while true {
            if !probing {
                let fresh = lastGood.map { Date().timeIntervalSince($0) < Self.quietPeriod } ?? false
                if fresh { return false }
                probing = true
                return true
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// After a request, however it went.
    func end(probe: Bool, authenticated: Bool) {
        if authenticated { lastGood = Date() }
        if probe {
            probing = false
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }
    }

    /// For the test button: act as if the session had run out.
    func forgetFreshness() {
        lastGood = nil
    }
}

// MARK: - Requests

/// Every request to Lectio goes through here.
///
/// Redirects are followed by hand, a step at a time, taking the cookies each
/// step hands back — the way a browser does. That is where Lectio gives an
/// expired session a new one; URLSession, following them itself, sent the
/// old cookies to every step and threw the new ones away, so the renewal
/// never took. A step that leaves Lectio (to UniLogin, MitID, the school's
/// sign-in) means you're signed out, and is never followed: Lectio's cookies
/// don't go anywhere else.
enum LectioHTTP {
    static let maxHops = 12

    /// Sends a request with the jar's cookies and returns the final
    /// response. Throws `LectioError.needsLogin` only when Lectio really
    /// wants a sign-in — after it has had the chance to renew the session
    /// with the key, and once more without the dead session cookie.
    static func send(_ request: URLRequest, via session: URLSession,
                     seed: [HTTPCookie] = []) async throws -> (Data, HTTPURLResponse) {
        let jar = LectioCookies.shared
        await jar.seedIfEmpty(seed)
        let probe = await jar.begin()
        let sessionBefore = await jar.sessionValue()
        do {
            let result = try await follow(request, via: session)
            await jar.end(probe: probe, authenticated: true)
            return result
        } catch LectioError.needsLogin where (request.httpMethod ?? "GET") == "GET" {
            // The session is dead but the key may not be: without the dead
            // session cookie, Lectio gives the key a new session. (Or another
            // request has just been given one: then try again with that.)
            let now = await jar.sessionValue()
            var retry = now != nil && now != sessionBefore
            if !retry { retry = await jar.dropSession() }
            guard retry else {
                await jar.end(probe: probe, authenticated: false)
                throw LectioError.needsLogin
            }
            do {
                let result = try await follow(request, via: session)
                await jar.end(probe: probe, authenticated: true)
                return result
            } catch {
                await jar.end(probe: probe, authenticated: false)
                throw error
            }
        } catch {
            await jar.end(probe: probe, authenticated: false)
            throw error
        }
    }

    static func isLectio(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().hasSuffix("lectio.dk")
    }

    private static func follow(_ original: URLRequest, via session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = original
        for _ in 0..<maxHops {
            try Task.checkCancellation()
            guard let url = request.url else { throw LectioError.badURL }
            guard isLectio(url) else { throw LectioError.needsLogin }

            request.setValue(await LectioCookies.shared.header(), forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
            guard let http = response as? HTTPURLResponse else { throw LectioError.badResponse(0) }
            await LectioCookies.shared.absorb(from: http)

            if (300..<400).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                request = hop(to: next, after: request, status: http.statusCode, original: original)
                continue
            }
            if LectioService.isLoginWall(http.url ?? url) { throw LectioError.needsLogin }
            return (data, http)
        }
        throw LectioError.badResponse(310)
    }

    /// The next step of a redirect, as a browser makes it: 307 and 308 keep
    /// the method and body, the others become a plain GET.
    private static func hop(to url: URL, after previous: URLRequest, status: Int,
                            original: URLRequest) -> URLRequest {
        var next = URLRequest(url: url)
        next.timeoutInterval = original.timeoutInterval
        for (field, value) in original.allHTTPHeaderFields ?? [:] {
            let lower = field.lowercased()
            if lower == "cookie" || lower == "content-length" { continue }
            if lower == "content-type" && !(status == 307 || status == 308) { continue }
            next.setValue(value, forHTTPHeaderField: field)
        }
        if status == 307 || status == 308 {
            next.httpMethod = previous.httpMethod
            next.httpBody = previous.httpBody
        }
        next.setValue(previous.url?.absoluteString, forHTTPHeaderField: "Referer")
        return next
    }
}

/// Stops URLSession following redirects, so LectioHTTP can take each step.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
