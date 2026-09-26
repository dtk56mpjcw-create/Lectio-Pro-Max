import Foundation

/// Stores the Lectio session cookies ourselves.
///
/// This is the piece the app was missing. It delegated cookie persistence to
/// WKWebView, but WebKit — correctly, by the HTTP spec — drops *session*
/// cookies when the app terminates. Lectio's `ASP.NET_SessionId` is exactly
/// that: a session cookie. So every cold start began with a cookie set that
/// could no longer authenticate, Lectio answered with the login page, and the
/// app concluded the user was signed out. Backgrounding the app kept working,
/// which is why this only ever showed up on a full close-and-reopen.
///
/// The file lives in the app's own sandboxed container and is excluded from
/// device backups, since it holds live session tokens.
enum CookieVault {

    private struct Stored: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var isSecure: Bool
    }

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("lectio-cookies.json")
    }

    static func save(_ cookies: [HTTPCookie]) {
        guard var target = CookieVault.url else { return }
        let stored = cookies.map {
            Stored(name: $0.name, value: $0.value, domain: $0.domain,
                   path: $0.path.isEmpty ? "/" : $0.path,
                   expires: $0.expiresDate, isSecure: $0.isSecure)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        // Readable once the phone has been unlocked after a restart, so a
        // background check can use it while the phone is locked; encrypted
        // until then, like the rest of the app's data.
        try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func load() -> [HTTPCookie] {
        guard let target = CookieVault.url,
              let data = try? Data(contentsOf: target),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }

        let now = Date()
        var cookies: [HTTPCookie] = []
        for item in stored {
            // Don't resurrect something Lectio has already retired.
            if let expiry = item.expires, expiry < now { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path
            ]
            if let expiry = item.expires { properties[.expires] = expiry }
            if item.isSecure { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
        }
        return cookies
    }

    static func clear() {
        guard let target = CookieVault.url else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
