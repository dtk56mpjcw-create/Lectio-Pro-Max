import BackgroundTasks
import Foundation
import WebKit

/// Checks Lectio while the app is closed and tells you what changed (see
/// ScheduleWatch); on the way it refreshes what the widgets and the lesson
/// reminders go by, and the copy the app opens on.
///
/// iOS decides when this runs: more often for apps you use a lot, not at
/// all in Low Power Mode or with Background App Refresh off. So news can
/// come late — it's a bonus, never the only way to find out. There's no
/// server of ours: it's the phone asking Lectio, exactly as the app does
/// when it's open, with the sign-in that's already on the phone.
@MainActor
enum BackgroundCheck {

    /// Also listed in Info.plist (BGTaskSchedulerPermittedIdentifiers).
    static let taskID = "com.ivan.lectiopromax.refresh"

    /// Asks iOS to wake the app again: about every 20 minutes during a
    /// school day, hourly in the evening, and not before 6:30 at night.
    static func schedule(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = nextRun(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func nextRun(after now: Date) -> Date {
        let cal = LectioDates.calendar
        let hour = cal.component(.hour, from: now)
        if hour >= 22 || hour < 6 {
            var day = cal.startOfDay(for: now)
            if hour >= 22 { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
            return cal.date(bySettingHour: 6, minute: 30, second: 0, of: day) ?? now.addingTimeInterval(3600)
        }
        let schoolHours = LectioDates.isWeekday(iso: LectioDates.isoString(from: now)) && hour < 16
        return now.addingTimeInterval(schoolHours ? 20 * 60 : 60 * 60)
    }

    /// Signed out: nothing to check.
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
    }

    // MARK: - One check

    /// Never signs you out. If Lectio won't take the session, the app sorts
    /// that out the next time it's opened, as it always has.
    static func run() async {
        schedule()
        guard UserDefaults.standard.string(forKey: "lectio.authState") == "authenticated" else { return }
        let now = Date()

        var cookies = CookieVault.load()
        guard carriesAuth(cookies) else { return }

        var outcome = await fetch(with: cookies, now: now)
        if case .needsLogin = outcome {
            // The session timed out. Let WebKit follow Lectio's own
            // auto-login, as the app does, and try once more.
            guard let renewed = await renewedByWebKit(), carriesAuth(renewed) else { return }
            cookies = merged(cookies, renewed)
            outcome = await fetch(with: cookies, now: now)
        }
        guard case .fetched(let fresh, let jar) = outcome, !Task.isCancelled else { return }

        // Keep the cookies Lectio rolled forward, where the app looks for
        // them: our own file, and WebKit's store.
        let kept = merged(cookies, jar)
        CookieVault.save(kept)
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in jar {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { done.resume() }
            }
        }
        _ = await CookieCollector.shared.drain()

        // Merge into what the app has, the way a refresh does.
        let session = LectioSession.active
        let base = session?.snapshot ?? SnapshotCache.load() ?? LectioSnapshot()
        var snapshot = fresh
        snapshot.completedKeys = base.completedKeys
        snapshot.weeks = base.weeks.merging(fresh.weeks) { _, new in new }
        if snapshot.schedule.isEmpty { snapshot.schedule = base.schedule }
        if snapshot.assignments.isEmpty { snapshot.assignments = base.assignments }
        snapshot.inbox = session.map { $0.threads } ?? base.inbox

        session?.adopt(snapshot)
        await SnapshotCache.write(snapshot)

        await NotificationService.post(ScheduleWatch.check(snapshot, now: now))
        WidgetFeedBuilder.publish(snapshot, now: now)
    }

    private enum Outcome {
        case fetched(LectioSnapshot, [HTTPCookie])
        case needsLogin
        case failed
    }

    /// Dashboard, this week, and the next school day's week when it's
    /// another one. Through a session that keeps cookies the way a
    /// browser does, so whatever Lectio hands back along the way — a
    /// renewed session on a redirect — is sent on the next request.
    nonisolated private static func fetch(with cookies: [HTTPCookie], now: Date) async -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        guard let jar = config.httpCookieStorage else { return .failed }
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12
        for cookie in cookies { jar.setCookie(cookie) }
        let browser = URLSession(configuration: config)
        defer { browser.finishTasksAndInvalidate() }

        do {
            return try await LectioService.$browser.withValue(browser) { () async throws -> Outcome in
                var snapshot = try await LectioService.loadSnapshot(cookies: cookies)
                for iso in ScheduleWatch.watchedDays(now: now) {
                    let code = LectioDates.weekCode(iso: iso)
                    if snapshot.weeks[code] == nil,
                       let week = try? await LectioService.fetchWeek(code: code, cookies: cookies) {
                        snapshot.weeks[code] = week
                    }
                }
                let lectio = (jar.cookies ?? []).filter { $0.domain.lowercased().contains("lectio.dk") }
                return .fetched(snapshot, lectio)
            }
        } catch LectioError.needsLogin {
            return .needsLogin
        } catch {
            return .failed
        }
    }

    /// Lectio's auto-login, followed by WebKit — up to about eight seconds.
    private static func renewedByWebKit() async -> [HTTPCookie]? {
        guard let url = URL(string: LectioConfig.forsideURL) else { return nil }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in CookieVault.load() {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { done.resume() }
            }
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        _ = web.load(URLRequest(url: url))
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !web.isLoading { break }
        }
        guard !web.isLoading, !LectioService.isLoginWall(web.url) else { return nil }
        let all = await withCheckedContinuation { (done: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { done.resume(returning: $0) }
        }
        return all.filter { $0.domain.lowercased().contains("lectio.dk") }
    }

    /// Later ones win, by name.
    private static func merged(_ older: [HTTPCookie], _ newer: [HTTPCookie]) -> [HTTPCookie] {
        var byName: [String: HTTPCookie] = [:]
        for cookie in older { byName[cookie.name] = cookie }
        for cookie in newer { byName[cookie.name] = cookie }
        return Array(byName.values)
    }

    private static func carriesAuth(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { ["autologinkeyv2", "asp.net_sessionid"].contains($0.name.lowercased()) }
    }
}
