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
    static let taskID = "com.ivan.lectiopro.refresh"

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
        guard await LectioCookies.shared.hasCredentials() else { return }

        // The same requests and the same jar as the app: Lectio's renewal
        // with the key is followed on the way (see LectioHTTP).
        var outcome = await fetch(now: now)
        if case .needsLogin = outcome {
            // As a last resort, WebKit follows Lectio's own auto-login.
            guard await renewedByWebKit() else { return }
            outcome = await fetch(now: now)
        }
        guard case .fetched(let fresh) = outcome, !Task.isCancelled else { return }

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
        case fetched(LectioSnapshot)
        case needsLogin
        case failed
    }

    /// Dashboard, this week, and the next school day's week when it's
    /// another one.
    nonisolated private static func fetch(now: Date) async -> Outcome {
        let cookies = await LectioCookies.shared.snapshot()
        do {
            var snapshot = try await LectioService.loadSnapshot(cookies: cookies)
            for iso in ScheduleWatch.watchedDays(now: now) {
                let code = LectioDates.weekCode(iso: iso)
                if snapshot.weeks[code] == nil,
                   let week = try? await LectioService.fetchWeek(code: code, cookies: cookies) {
                    snapshot.weeks[code] = week
                }
            }
            return .fetched(snapshot)
        } catch LectioError.needsLogin {
            return .needsLogin
        } catch {
            return .failed
        }
    }

    /// Lectio's auto-login, followed by WebKit — up to about ten seconds.
    /// What it comes back with goes into the jar.
    private static func renewedByWebKit() async -> Bool {
        guard let url = URL(string: LectioConfig.forsideURL) else { return false }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await LectioCookies.shared.snapshot() {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { done.resume() }
            }
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        defer { web.stopLoading() }
        _ = web.load(URLRequest(url: url))
        var last: URL?
        var steady = 0
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if web.isLoading { steady = 0; continue }
            if web.url == last { steady += 1 } else { steady = 0; last = web.url }
            if steady >= 3 { break }
        }
        guard let landed = web.url, LectioHTTP.isLectio(landed),
              !LectioService.isLoginWall(landed) else { return false }
        let all = await withCheckedContinuation { (done: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { done.resume(returning: $0) }
        }
        let lectio = all.filter { $0.domain.lowercased().contains("lectio.dk") }
        guard carriesAuth(lectio) else { return false }
        await LectioCookies.shared.absorb(lectio)
        return true
    }

    private static func carriesAuth(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { ["autologinkeyv2", "asp.net_sessionid"].contains($0.name.lowercased()) }
    }
}
