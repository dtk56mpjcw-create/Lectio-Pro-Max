import Foundation
import Security

/// Where the Lectio session is kept between launches: the Keychain, the
/// place iOS meant for sign-ins. Only on this phone ("ThisDeviceOnly": not
/// in backups, not synced), readable once the phone has been unlocked after
/// a restart, so the background check can use it while it's locked.
///
/// WebKit alone can't be trusted with it: by the HTTP spec it drops
/// session cookies when the app is closed, and Lectio's session is one.
/// An older version kept the cookies in a file; it's moved over once.
///
/// Read and written through LectioCookies, which is the only thing that
/// should touch it.
enum CookieVault {

    private struct Stored: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var isSecure: Bool
    }

    private static let service = "com.ivan.lectiopromax.session"
    private static let account = "lectio-cookies"
    /// The Keychain outlives the app. A fresh install starts signed out, as
    /// people expect; this marks that it has.
    private static let installedKey = "lectio.keychainReady"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ cookies: [HTTPCookie]) {
        let stored = cookies.map {
            Stored(name: $0.name, value: $0.value, domain: $0.domain,
                   path: $0.path.isEmpty ? "/" : $0.path,
                   expires: $0.expiresDate, isSecure: $0.isSecure)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = base.merging(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> [HTTPCookie] {
        forgetIfReinstalled()
        var data = readKeychain()
        if data == nil, let legacy = legacyURL, let old = try? Data(contentsOf: legacy) {
            data = old
        }
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }

        let now = Date()
        var cookies: [HTTPCookie] = []
        for item in stored {
            // Don't resurrect something Lectio has already retired.
            if let expiry = item.expires, expiry < now { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path,
            ]
            if let expiry = item.expires { properties[.expires] = expiry }
            if item.isSecure { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
        }

        // Moved over from the old file: into the Keychain, and the file gone.
        if readKeychain() == nil, !cookies.isEmpty {
            save(cookies)
            if let legacy = legacyURL { try? FileManager.default.removeItem(at: legacy) }
        }
        return cookies
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
        if let legacy = legacyURL { try? FileManager.default.removeItem(at: legacy) }
    }

    // MARK: - Private

    private static func readKeychain() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func forgetIfReinstalled() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: installedKey) else { return }
        defaults.set(true, forKey: installedKey)
        // A cookie file means this isn't a fresh install but an update from
        // before the Keychain: keep the session, it's about to move over.
        if let legacy = legacyURL, FileManager.default.fileExists(atPath: legacy.path) { return }
        SecItemDelete(base as CFDictionary)
    }

    /// Where the old version kept them.
    private static var legacyURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("lectio-cookies.json")
    }
}
