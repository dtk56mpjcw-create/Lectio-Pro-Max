import Foundation
import WebKit

/// Holds the app's Lectio state. The session itself lives in WKWebView's own
/// persistent cookie store on this device — nothing is sent to any server of ours.
@MainActor
final class LectioSession: ObservableObject {

    @Published var snapshot = LectioSnapshot() {
        // Lessons are told apart from events by their class; learn how this
        // school writes classes as soon as the profile is known.
        didSet { ClassNames.use(snapshot.profile.className) }
    }
    @Published var isLoading = false
    @Published var isLoggedIn = false
    @Published var showLogin = false
    @Published var errorMessage: String?
    @Published var hasLoadedOnce = false
    /// Weeks whose fetch failed. The schedule shows a retry instead of a
    /// spinner that would otherwise sit there forever.
    @Published var failedWeeks: Set<String> = []
    /// Why a week failed, so the retry screen can say something useful.
    @Published var weekErrors: [String: String] = [:]
    /// The week the schedule is actually showing, so a refresh can revalidate
    /// THAT week and not just whatever Lectio calls the current one.
    @Published var visibleWeekCode: String = ""

    /// Auth state survives relaunches, so the app always knows on cold start
    /// whether to wait for cookies, or go straight to the login screen.
    enum AuthState: String {
        case unknown        // never signed in on this device
        case authenticated  // a real load has succeeded before
        case signedOut      // the user deliberately signed out
    }

    private var authState: AuthState {
        get { AuthState(rawValue: UserDefaults.standard.string(forKey: "lectio.authState") ?? "") ?? .unknown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lectio.authState") }
    }
    @Published var weekCodes: [String] = []
    @Published var selectedWeekCode: String = ""

    private var loadingWeeks: Set<String> = []
    /// Weeks to warm up once `key` has actually arrived, so a swipe never has
    /// three fetches and three parses competing for the same CPU.
    private var pendingWarm: [String: [String]] = [:]
    /// Cookies are read from WKWebView's store, which is a hop to the main
    /// thread each time; once we have a working set, reuse it.
    private var cachedCookies: [HTTPCookie] = []
    private var saveTask: Task<Void, Never>?

    /// When each week was last fetched. Deliberately NOT persisted: on a cold
    /// start every cached week counts as stale, so the disk copy paints
    /// immediately and is then quietly replaced with what Lectio has now.
    private var weekFetchedAt: [String: Date] = [:]
    private static let weekFreshness: TimeInterval = 600   // 10 minutes

    /// True once a full refresh has actually succeeded with these cookies.
    /// Week fetches wait for it, because on a cold start they otherwise race
    /// the cookie store and fail against a session that is merely not ready.
    private var sessionVerified = false
    private var deferredWeeks: [String] = []
    private var reverifyRequested = false
    private var retriedColdStart = false
    private var renewalInFlight = false
    private var renewedThisCycle = false

    /// The cookies that actually carry authentication. A partial read — WebKit
    /// handing back one cookie but not the rest — is worse than no read at all,
    /// because Lectio answers it with the login page.
    private static let authCookieNames: Set<String> = ["autologinkeyv2", "asp.net_sessionid"]

    /// WebKit's cookies live in a separate process, and asking the default data
    /// store for them while no WKWebView exists anywhere in the app can simply
    /// answer *empty* — which is exactly what "No Lectio session on this device
    /// yet" really was: the login WebView is gone once you've signed in, so
    /// nothing was keeping that process alive. This one is created once, never
    /// navigates anywhere, and exists purely so the answer is real. (Unlike the
    /// earlier auth probe, it loads no URL, so it cannot get bounced to MitID.)
    private lazy var cookieStoreKeepAlive: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        return WKWebView(frame: .zero, configuration: config)
    }()

    // MARK: - Lifecycle

    func bootstrap() async {
        _ = cookieStoreKeepAlive     // wake WebKit before anyone asks for cookies
        await restoreSavedCookies()
        prepareWeeks()
        loadCache()

        // Signed out last time? Normally go straight to login rather than
        // spinning forever — but verify it first. A bad guess used to be
        // written to disk and then sent you to the login screen on EVERY
        // launch afterwards, so this state has to be able to heal itself.
        if authState == .signedOut {
            let cookies = await cookiesWithRetry(attempts: 4)
            if cookies.isEmpty {
                isLoggedIn = false
                showLogin = true
                hasLoadedOnce = true
                return
            }
            authState = .unknown     // WebKit still has a real session; use it
        }
        await refresh()
    }

    /// Weeks available to swipe through, centred on this week.
    func prepareWeeks() {
        let now = Date()
        weekCodes = LectioDates.weekCodes(around: now, back: 2, forward: 8)
        if selectedWeekCode.isEmpty {
            selectedWeekCode = LectioDates.weekCode(for: now)
        }
    }

    // MARK: - Week loading

    /// Fetches one week on demand as the user swipes to it, then warms the
    /// neighbours it was given once that week is on screen.
    ///
    /// Fire-and-forget: `.task(id:)` cancels its work when the id changes, so
    /// swiping quickly through weeks used to cancel the very fetch it started
    /// and leave the view spinning forever. This detaches the load instead.
    func requestWeek(_ code: String, alsoWarm warm: [String] = []) {
        if code.isEmpty { return }
        if !warm.isEmpty { pendingWarm[code] = warm }
        startWeekLoad(code)
    }

    /// User-driven retry after a failed week.
    func retryWeek(_ code: String) {
        failedWeeks.remove(code)
        weekErrors[code] = nil
        errorMessage = nil
        startWeekLoad(code, force: true)
    }

    private func isFresh(_ code: String) -> Bool {
        guard let at = weekFetchedAt[code] else { return false }
        return Date().timeIntervalSince(at) < LectioSession.weekFreshness
    }

    private func startWeekLoad(_ code: String, force: Bool = false) {
        if code.isEmpty { return }
        if showLogin { return }
        if loadingWeeks.contains(code) { return }

        let haveCopy = snapshot.weeks[code] != nil

        // Already have it and it's recent: nothing to do.
        if haveCopy && !force && isFresh(code) {
            warmNeighbours(of: code)
            return
        }
        // A week we already have is refreshed quietly behind the cached copy.
        // A week that failed and that we have nothing for waits for a tap.
        if !force && !haveCopy && failedWeeks.contains(code) { return }

        // Don't fetch a week until we know the session works. An explicit tap
        // on "Try again" goes through regardless.
        if !sessionVerified && !force {
            if !deferredWeeks.contains(code) { deferredWeeks.append(code) }
            return
        }

        loadingWeeks.insert(code)
        Task { await self.performWeekLoad(code) }
    }

    /// Asks refresh() — the only thing allowed to decide the session is dead —
    /// to check, without piling up one request per failed week.
    private func requestReverification() {
        if reverifyRequested { return }
        reverifyRequested = true
        Task {
            await self.refresh()
            self.reverifyRequested = false
        }
    }

    /// Weeks that were asked for before the session was known good.
    private func flushDeferredWeeks(failed: Bool) {
        let queued = deferredWeeks
        deferredWeeks.removeAll()
        for code in queued {
            if failed {
                if snapshot.weeks[code] == nil {
                    failedWeeks.insert(code)
                    weekErrors[code] = errorMessage ?? "Couldn't reach Lectio."
                }
            } else {
                startWeekLoad(code, force: true)
            }
        }
    }

    private func warmNeighbours(of code: String) {
        guard let warm = pendingWarm[code], !warm.isEmpty else { return }
        pendingWarm[code] = nil
        for neighbour in warm { startWeekLoad(neighbour) }
    }

    /// Tries a few times before giving up. On a weak mobile signal a single
    /// dropped request used to kill that week for the rest of the session,
    /// because a failed week was never retried on its own.
    private func performWeekLoad(_ code: String) async {
        defer { loadingWeeks.remove(code) }

        let hadCopy = snapshot.weeks[code] != nil
        let backoff: [UInt64] = [0, 1_200_000_000, 3_000_000_000]
        var lastError: String?

        for attempt in 0..<backoff.count {
            if backoff[attempt] > 0 {
                try? await Task.sleep(nanoseconds: backoff[attempt])
            }

            let cookies = await usableCookies(attempts: 4)
            if cookies.isEmpty {
                if authState != .authenticated {
                    showLogin = true
                    return
                }
                lastError = "Couldn't read the Lectio session from this device."
                continue
            }

            do {
                let week = try await LectioService.fetchWeek(code: code, cookies: cookies)
                snapshot.weeks[code] = week
                weekFetchedAt[code] = Date()
                failedWeeks.remove(code)
                weekErrors[code] = nil
                await absorbRenewedCookies()
                scheduleSave()
                warmNeighbours(of: code)
                return
            } catch LectioError.needsLogin {
                // A week fetch is NOT allowed to decide you are signed out.
                // It races the cold start, and getting that wrong wrote
                // "signed out" to disk — which is why the app started asking
                // for a login on every launch. refresh() waits properly for the
                // cookie store, so let it be the one to judge.
                cachedCookies = []
                sessionVerified = false
                lastError = "Lectio didn't accept the session."
                requestReverification()
                break
            } catch {
                if isCancellation(error) { return }
                // Deliberately keep `cachedCookies`: discarding them here meant
                // one failed attempt poisoned every attempt after it, because
                // the next read had nothing to fall back on.
                lastError = error.localizedDescription
            }
        }

        // Only surface a failure when there's nothing on screen to fall back on.
        if !hadCopy {
            failedWeeks.insert(code)
            weekErrors[code] = lastError
        }
    }

    // MARK: - Full refresh

    func refresh() async {
        if isLoading {
            // Wait for the refresh already running instead of silently doing
            // nothing — a pull-to-refresh that returns instantly reads as broken.
            for _ in 0..<50 {
                if !isLoading { break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            return
        }
        if showLogin { return }   // never compete with the login WebView
        isLoading = true
        errorMessage = nil

        let cookies = await cookiesWithRetry(attempts: 5)
        if cookies.isEmpty {
            // For a previously-authenticated user this is just cookies not
            // being ready yet; for anyone else it means they must sign in.
            if authState != .authenticated {
                authState = .signedOut
                isLoggedIn = false
                showLogin = true
            } else if !retriedColdStart {
                // Signed in, but WebKit hasn't handed the cookies over yet.
                // Give it a moment and ask again rather than showing nothing.
                retriedColdStart = true
                isLoading = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refresh()
                return
            }
            isLoading = false
            hasLoadedOnce = true
            flushDeferredWeeks(failed: true)
            return
        }

        do {
            var fresh = try await LectioService.loadSnapshot(cookies: cookies)
            fresh.completedKeys = snapshot.completedKeys   // don't lose ticks on refresh
            fresh.weeks = snapshot.weeks.merging(fresh.weeks) { _, new in new }
            // A page that failed this time shouldn't blank what we already had.
            if fresh.schedule.isEmpty { fresh.schedule = snapshot.schedule }
            if fresh.assignments.isEmpty { fresh.assignments = snapshot.assignments }
            snapshot = fresh
            failedWeeks.removeAll()
            weekErrors.removeAll()

            // Every week other than the one Lectio just handed us is now stale,
            // so it revalidates the next time it's shown. Without this, a week
            // fetched once stayed frozen forever — refreshing, and even
            // relaunching, never touched it, because we already "had" it.
            weekFetchedAt.removeAll()
            if !fresh.currentWeekCode.isEmpty {
                weekFetchedAt[fresh.currentWeekCode] = Date()
            }

            isLoggedIn = true
            showLogin = false
            authState = .authenticated
            sessionVerified = true
            retriedColdStart = false
            renewedThisCycle = false
            await absorbRenewedCookies()
            scheduleSave()
            await refreshReminders()

            // Refresh the week actually on screen, which is often not this one.
            if !visibleWeekCode.isEmpty && visibleWeekCode != fresh.currentWeekCode {
                startWeekLoad(visibleWeekCode, force: true)
            }
            flushDeferredWeeks(failed: false)
        } catch LectioError.needsLogin {
            // Lectio won't accept these cookies. Before believing the session is
            // gone, let the hidden WebView do what a browser does on every visit:
            // follow Lectio's auto-login and pick up the refreshed cookies.
            isLoading = false
            if !renewedThisCycle {
                renewedThisCycle = true
                if await renewSessionSilently() {
                    await refresh()
                    return
                }
            }
            // Renewal failed too — now it really is a sign-out.
            isLoggedIn = false
            authState = .signedOut
            sessionVerified = false
            cachedCookies = []
            CookieVault.clear()
            showLogin = true
            errorMessage = nil
            deferredWeeks.removeAll()
        } catch {
            if !isCancellation(error) { errorMessage = error.localizedDescription }
            flushDeferredWeeks(failed: true)
        }

        hasLoadedOnce = true
        isLoading = false
    }

    /// Called when the in-app login WebView lands on a real Lectio page.
    func handleLoginSucceeded() async {
        showLogin = false
        isLoggedIn = true
        authState = .authenticated
        cachedCookies = []
        failedWeeks.removeAll()
        weekErrors.removeAll()
        weekFetchedAt.removeAll()
        sessionVerified = false
        deferredWeeks.removeAll()
        // Let Lectio finish establishing the session before we request anything.
        try? await Task.sleep(nanoseconds: 600_000_000)
        await refresh()
    }

    func signOut() async {
        saveTask?.cancel()
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))
        snapshot = LectioSnapshot()
        clearCache()
        CookieVault.clear()
        cachedCookies = []
        // What belongs to the account, not the phone: reminders (and their
        // notifications), drafts, the Deleted list, the signature, subject
        // colours, the remembered end of the school day, cached lessons and
        // faces. Appearance settings and the school stay.
        NotificationService.removeAll()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where ["reminders.", "lectio.feedbackDrafts", "messages.", "signature.", "subjectColors",
               "schedule.dayEndModule"].contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        ReminderBook.shared.forgetAll()
        LessonCache.shared.clear()
        PersonPhotos.shared.clear()
        loadingWeeks.removeAll()
        failedWeeks.removeAll()
        weekErrors.removeAll()
        weekFetchedAt.removeAll()
        pendingWarm.removeAll()
        threads.removeAll()
        recipients.removeAll()
        inboxFetchedAt = nil
        recipientsFetchedAt = nil
        lessonNotes.removeAll()
        absence = LectioStudyService.Absence()
        scheduleTargets.removeAll()
        lessonNotesAt = nil
        absenceAt = nil
        targetsAt = nil
        grades = nil
        gradesAt = nil
        studyPlan = nil
        studyPlanAt = nil
        deferredWeeks.removeAll()
        sessionVerified = false
        isLoggedIn = false
        authState = .signedOut      // survives relaunch, so we go to login
        hasLoadedOnce = true
        errorMessage = nil
        showLogin = true
    }

    /// Tick homework off. Stored by stable key so it survives refreshes.
    func toggleCompleted(_ item: WorkItem) {
        if snapshot.completedKeys.contains(item.key) {
            snapshot.completedKeys.remove(item.key)
        } else {
            snapshot.completedKeys.insert(item.key)
        }
        scheduleSave()
        // Ticking something off should stop its reminder.
        Task { await refreshReminders() }
    }

    /// A cancelled request isn't a failure the user should ever see — it just
    /// means they swiped to another day before the fetch finished.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.code == NSURLErrorCancelled || ns.domain == "Swift.CancellationError"
    }

    // MARK: - Cookies

    /// Puts the cookies we persisted back where both halves of the app expect
    /// them: our own request header, and WebKit's store, so the hidden WebView
    /// can renew the session if Lectio ever rejects them.
    private func restoreSavedCookies() async {
        let saved = CookieVault.load()
        guard !saved.isEmpty else { return }
        cachedCookies = saved
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in saved {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    /// Takes whatever cookies Lectio handed back during the last fetches and
    /// keeps them — both for this run and, via WebKit's store, for the next
    /// launch. Without this the app replayed the set captured at login until
    /// Lectio stopped honouring it.
    private func absorbRenewedCookies() async {
        let renewed = await CookieCollector.shared.drain()
        guard !renewed.isEmpty else { return }

        var merged: [String: HTTPCookie] = [:]
        for cookie in cachedCookies { merged[cookie.name] = cookie }
        for cookie in renewed { merged[cookie.name] = cookie }
        cachedCookies = Array(merged.values)
        CookieVault.save(cachedCookies)

        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in renewed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    /// Re-establishes the session the way a browser would: the hidden WebView
    /// follows Lectio's own auto-login and accepts the cookies it hands back,
    /// which our URLSession cannot do on its own. It is never allowed to
    /// conclude the user is signed out — it either renews, or it doesn't.
    private func renewSessionSilently() async -> Bool {
        if renewalInFlight { return false }
        renewalInFlight = true
        defer { renewalInFlight = false }

        guard let url = URL(string: LectioConfig.forsideURL) else { return false }
        let web = cookieStoreKeepAlive
        _ = web.load(URLRequest(url: url))

        for _ in 0..<40 {                       // up to ~8 seconds
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !web.isLoading { break }
        }
        if LectioService.isLoginWall(web.url) { return false }

        let cookies = await usableCookies(attempts: 4)
        return !cookies.isEmpty
    }

    // MARK: - Messages

    @Published var threads: [MessageThreadSummary] = []
    @Published var inboxLoading = false
    @Published var inboxError: String?
    @Published var recipients: [Recipient] = []

    private var inboxFetchedAt: Date?
    private var recipientsFetchedAt: Date?
    private static let inboxFreshness: TimeInterval = 180

    /// The full inbox, which the dashboard page doesn't give us — it only
    /// carries a handful of previews and a total unread count.
    func loadInbox(force: Bool = false) async {
        if inboxLoading { return }
        if showLogin { return }
        if !force, let at = inboxFetchedAt,
           Date().timeIntervalSince(at) < LectioSession.inboxFreshness, !threads.isEmpty {
            return
        }

        inboxLoading = true
        inboxError = nil
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else {
            inboxLoading = false
            inboxError = "Couldn't read the Lectio session from this device."
            return
        }
        do {
            threads = try await LectioMessagesService.loadInbox(cookies: cookies)
            inboxFetchedAt = Date()
            scheduleSave()
            // The inbox knows the real unread state; the dashboard only guesses.
            snapshot.unreadMessages = threads.filter { $0.unread }.count
            await absorbRenewedCookies()
        } catch LectioError.needsLogin {
            inboxError = "Lectio didn't accept the session."
            requestReverification()
        } catch {
            if !isCancellation(error) { inboxError = error.localizedDescription }
        }
        inboxLoading = false
    }

    /// Takes a thread out of the list the moment it's deleted, before Lectio
    /// has answered, so the row goes as your finger lets go.
    func removeThreadLocally(_ id: String) {
        threads.removeAll { $0.id == id }
        snapshot.unreadMessages = threads.filter { $0.unread }.count
        scheduleSave()
    }

    func applyThreads(_ updated: [MessageThreadSummary]) {
        guard !updated.isEmpty else { return }
        threads = updated
        inboxFetchedAt = Date()
        snapshot.unreadMessages = updated.filter { $0.unread }.count
        scheduleSave()
    }

    /// Marks a thread read locally the moment it's opened, so the list doesn't
    /// keep it bold while Lectio catches up.
    func markThreadOpened(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }), threads[index].unread else { return }
        threads[index].unread = false
        snapshot.unreadMessages = threads.filter { $0.unread }.count
        scheduleSave()
    }

    /// Everyone this account may write to. Big, and it changes rarely, so it's
    /// fetched once per session.
    func loadRecipients() async {
        if !recipients.isEmpty, let at = recipientsFetchedAt,
           Date().timeIntervalSince(at) < 3600 { return }
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else { return }
        if let list = try? await LectioMessagesService.recipientDirectory(cookies: cookies), !list.isEmpty {
            recipients = list
            recipientsFetchedAt = Date()
        }
    }

    // MARK: - Lektier, absence, other people's schedules

    @Published var lessonNotes: [LessonNote] = []
    @Published var absence = LectioStudyService.Absence()
    @Published var scheduleTargets: [ScheduleTarget] = []
    @Published var absenceLoading = false

    private var lessonNotesAt: Date?
    private var absenceAt: Date?
    private var targetsAt: Date?

    func loadLessonNotes(force: Bool = false) async {
        if !force, let at = lessonNotesAt, Date().timeIntervalSince(at) < 600 { return }
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else { return }
        if let notes = try? await LectioStudyService.loadLessonNotes(cookies: cookies) {
            lessonNotes = notes
            lessonNotesAt = Date()
            await absorbRenewedCookies()
        }
    }

    /// Rebuilds the local reminders from whatever we now know.
    func refreshReminders() async {
        await NotificationService.reschedule(snapshot: snapshot, absences: absence.records)
    }

    func loadAbsence(force: Bool = false) async {
        if absenceLoading { return }
        if !force, let at = absenceAt, Date().timeIntervalSince(at) < 300 { return }
        absenceLoading = true
        let cookies = await usableCookies(attempts: 3)
        if !cookies.isEmpty,
           let loaded = try? await LectioStudyService.loadAbsence(cookies: cookies) {
            absence = loaded
            absenceAt = Date()
            await absorbRenewedCookies()
            await refreshReminders()
        }
        absenceLoading = false
    }

    // MARK: - Me: grades and study hours

    @Published var grades: GradeReport?
    @Published var studyPlan: [StudyPlanSubject]?
    private var gradesAt: Date?
    private var studyPlanAt: Date?

    func loadGrades(force: Bool = false) async {
        if !force, let at = gradesAt, Date().timeIntervalSince(at) < 600 { return }
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else { return }
        if let report = try? await LectioMeService.loadGrades(cookies: cookies) {
            grades = report
            gradesAt = Date()
            await absorbRenewedCookies()
        }
    }

    func loadStudyPlan(force: Bool = false) async {
        if !force, let at = studyPlanAt, Date().timeIntervalSince(at) < 600 { return }
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else { return }
        if let plan = try? await LectioStudyService.loadStudyPlan(cookies: cookies) {
            studyPlan = plan
            studyPlanAt = Date()
            await absorbRenewedCookies()
        }
    }

    func loadScheduleTargets() async {
        if !scheduleTargets.isEmpty, let at = targetsAt, Date().timeIntervalSince(at) < 3600 { return }
        let cookies = await usableCookies(attempts: 3)
        guard !cookies.isEmpty else { return }
        if let targets = try? await LectioStudyService.loadScheduleTargets(cookies: cookies), !targets.isEmpty {
            scheduleTargets = targets
            targetsAt = Date()
        }
    }

    /// The cookie set anything outside this class should send with a request —
    /// the merged one, not WebKit's raw answer.
    func requestCookies() async -> [HTTPCookie] {
        return await usableCookies(attempts: 3)
    }

    /// Everything we know, newest source winning: what we saved to disk last
    /// run, what we've picked up this run, and whatever WebKit can tell us now.
    ///
    /// Merging matters. WebKit keeps Lectio's persistent cookies across
    /// launches but drops the session one, and our own vault keeps the session
    /// one — neither is complete on its own after a cold start.
    private func usableCookies(attempts: Int) async -> [HTTPCookie] {
        var merged: [String: HTTPCookie] = [:]
        for cookie in CookieVault.load() { merged[cookie.name] = cookie }
        for cookie in cachedCookies { merged[cookie.name] = cookie }
        for cookie in await currentCookiesRetrying(attempts: attempts) { merged[cookie.name] = cookie }

        let all = Array(merged.values)
        if !all.isEmpty {
            cachedCookies = all
            CookieVault.save(all)
        }
        return all
    }

    /// WKWebView's cookie store can answer empty for a moment on a cold start,
    /// which previously flashed the MitID login at people who were signed in.
    /// Asks WebKit, waiting a little for its cookie process to wake up.
    /// Returns whatever it has; deciding what that *means* is not its job.
    private func currentCookiesRetrying(attempts: Int) async -> [HTTPCookie] {
        var best: [HTTPCookie] = []
        for attempt in 0..<max(attempts, 1) {
            let cookies = await currentCookies()
            if carriesAuth(cookies) { return cookies }
            if cookies.count > best.count { best = cookies }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return best
    }

    private func cookiesWithRetry(attempts: Int = 3) async -> [HTTPCookie] {
        return await usableCookies(attempts: attempts)
    }

    /// WebKit sometimes answers with a couple of harmless cookies before the
    /// real ones are available. Sending that half-set makes Lectio reply with
    /// the login page, which used to read as "signed out".
    private func carriesAuth(_ cookies: [HTTPCookie]) -> Bool {
        for cookie in cookies where LectioSession.authCookieNames.contains(cookie.name.lowercased()) {
            return true
        }
        return false
    }

    func currentCookies() async -> [HTTPCookie] {
        return await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                let lectio = all.filter { $0.domain.lowercased().contains("lectio.dk") }
                continuation.resume(returning: lectio)
            }
        }
    }

    // MARK: - Offline cache

    private func loadCache() {
        guard let url = SnapshotCache.url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LectioSnapshot.self, from: data) else { return }
        snapshot = decoded
        threads = decoded.inbox ?? []
    }

    /// Encoding the whole snapshot took a visible beat on the main thread, and a
    /// single swipe could trigger it three times. Coalesce, then encode off-main.
    private func scheduleSave() {
        saveTask?.cancel()
        var pending = snapshot
        pending.inbox = threads
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            await SnapshotCache.write(pending)
        }
    }

    private func clearCache() {
        guard let url = SnapshotCache.url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deliberately outside the @MainActor class so the JSON encode genuinely runs
/// off the main thread rather than hopping straight back onto it.
enum SnapshotCache {
    static var url: URL? {
        let dirs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return dirs.first?.appendingPathComponent("lectio-snapshot.json")
    }

    static func write(_ snapshot: LectioSnapshot) async {
        guard let target = SnapshotCache.url,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: target, options: .atomic)
    }
}
