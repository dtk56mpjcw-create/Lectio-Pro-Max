# Task: the search button — wrong search, and keep the tab behind it

Read `CLAUDE.md` first (design language, hard rules, what Dan has already
rejected). Dan builds and tests in Xcode himself on two phones: his iPhone
with a home button (SE size) on iOS 26, and a friend's iPhone 15 on iOS 27.
Nothing here can be tested in CI, so explain in your PR exactly what he
should try on each phone.

## What Dan asked for (his words)

> "search from schedule is bagged, and is it possible so that background will
> still show as normal when u press search button, so it doesnt feel like its
> a new tab, the stuff only changes when u type something"

When asked to pin it down, he answered:

1. **The bug:** the wrong search shows — e.g. it says **Search Me** when he
   pressed search from Schedule.
2. **The background:** it must be **exactly where he was** — the same day,
   the same week, the same Messages folder. Not a fresh copy of the tab, not
   today, not a blurred snapshot.

So there are two jobs. Do job 1 first, as its own commit, so Dan can test it
on its own.

## How search works today (commit 7924b15)

- `RootView.swift`: a native `TabView(selection: $tab)` with Schedule,
  Homework, Messages, Me, and `Tab(value: AppTab.search, role: .search)`.
  The search tab holds `SearchTab(query:context:)` with `.searchable`
  attached to that tab only (on the TabView it leaked into every tab's
  navigation bar — see the comment there; don't move it back).
- `searchContext` = the tab the search button searches. It is updated in
  `.onChange(of: tab) { _, new in guard new != .search, new != searchContext
  else { return }; searchContext = new; query = "" }`.
- `SearchTab.swift`: its own `NavigationStack`, `AppBackground()`, title
  `context.searchTitle` ("Search Schedule" / "Search Homework" / "Search
  Messages" / "Search Me"). Body switches on the context: `ScheduleSearch`,
  `HomeworkSearch`, `MessageSearch`, `MeSearch`. With an empty query each one
  shows a `ContentUnavailableView` (Schedule shows Pinned + Recent).
- Dan's rule for what each search covers (keep it): "in schedule tab it
  searches all in schedule, in homework tab it searches all in homework, in
  messages tab it searches all in messages"; Me searches the Me pages.

## Job 1 — the wrong search shows

Find the real cause before fixing. Candidates, most likely first:

1. **Find a schedule lives in the Me tab.** `MeTab` pushes
   `FindScheduleScreen` (`MeRoute.findSchedule`). If Dan was on Find a
   schedule — which to him *is* "schedule" — and pressed search, the code
   correctly says Search Me. Ask Dan (or state your assumption in the PR)
   whether search from Find a schedule and from someone else's schedule
   (`TargetScheduleScreen`) should be **Search Schedule**. If yes, let a
   screen override the context, e.g. a preference key or an
   `@Observable` "current search context" that screens set on appear and
   RootView reads when search is pressed.
2. **The tab binding doesn't change the way the code assumes.** On iOS 26
   the search tab collapses the bar to the field plus one button for the tab
   you came from; on iOS 27 search sits back in the bar. Check whether
   leaving search through that button, or via a widget / notification
   (`AppRouter` sets `tab` directly), leaves `searchContext` stale. A more
   robust capture: `.onChange(of: tab) { old, new in if new == .search,
   old != .search { searchContext = old } }` — the context is simply the tab
   you left, read at the moment you enter search.
3. `searchContext` is `@State` that starts as `.schedule`; make sure a
   relaunch or state restoration can't bring the app back with `tab ==
   .search` and a context that doesn't match.

Also while you're here: **Search Me** showed a plain white background
instead of the grouped gray the other pages use. Fix that so every search
screen uses the same background as the tab it searches.

Done when: from every tab root, and from every pushed screen Dan uses
(Find a schedule, someone's schedule, a lesson, a homework item, a message
thread, Settings), the title and prompt name the right tab — on both phones.

## Job 2 — keep the tab behind the search field

Pressing search must not look like a new tab. With an **empty query** Dan
sees the tab he was on, exactly as it was. Only once he types does the
content change to results. Clearing the field brings the tab back.

A SwiftUI view can't be in two tabs at once, so the search tab has to draw
its own copy of the tab you came from — at the same position. That means
the tabs' position state has to move out of `@State` into shared,
observable state both copies read and write:

| Tab | State to share (today `@State` in) |
|---|---|
| Schedule | `selectedDate`, `dayPage`, `weekPage`, `weekMode` (`ScheduleTab.swift` ~lines 64–68) — and, if you can, `opener.path` |
| Homework | `filter` (`WorkFilter`), and ideally `path` (`HomeworkTab.swift`) |
| Messages | `folder`, `folderThreads`, `folderLoading`, and ideally `path` (`MessagesTab.swift`) |
| Me | nothing at the root; a pushed page needs a `path` (MeTab has none yet) |

Suggested shape (change it if you find better): one `@MainActor @Observable`
store per tab, owned by `RootView` (or a singleton like `FindMemory.shared`),
injected with `.environment`, and each tab view takes a flag such as
`isSearchBackdrop` for its second copy. `SearchTab` then shows, when the
query is empty, `ScheduleTab(backdrop: true)` / `HomeworkTab(...)` /
`MessagesTab(...)` / `MeTab(...)` instead of the empty-state views, and the
results list once there's text. Because the state is shared, paging a day
in the backdrop moves the real Schedule too — that's correct.

"Exactly where I was" is required for the tab roots (day, week, folder,
filter). For pushed screens (a lesson, a thread, Find a schedule, someone's
schedule), share the navigation path too if it's clean; if it isn't, say so
in the PR rather than showing a jump back to the root silently.

### Gotchas — read before writing code

- **AppRouter.** `ScheduleTab` handles widget / notification routes in
  `.onChange(of: AppRouter.shared.request, initial: true)` and sets the
  request to `nil`. A second ScheduleTab would race the real one for it. The
  backdrop copy must not handle routes (or other one-shot work).
- **Duplicate loading.** Each tab starts loads in `.task` (absence, inbox,
  lesson prefetch via `LessonCache.shared.prefetch`, …). The backdrop must
  not double the network traffic.
- **The scroll fix must survive.** Schedule's horizontal pagers use native
  `.scrollTargetBehavior(.paging)` with `pageWide()` on the page content —
  see `SCROLL_BUG.md` for how long that took. Two pagers bound to the same
  `dayPage` / `weekPage` must not fight each other or re-trigger `align`.
- **Floating bars.** Schedule measures its floating bars with
  `onGeometryChange` (`barTop`, `barLine`, `safeBottom`) and pads pages with
  `barClearance`. In the search tab the bar is the search field (and the
  keyboard may be up), so check the clearances still look right.
- **Someone else's schedule** (`TargetScheduleScreen`) calls
  `ClassNames.use(...)` for their class and restores yours in
  `.onDisappear`; `.onAppear` records it in Recent. A second copy appearing
  and disappearing must not flip the class names or add Recent entries.
- **Title and toolbar.** With an empty query the backdrop should look like
  the tab — its own heading and buttons — not "Search Schedule". Decide
  whether its buttons work (preferred) or are inert, and keep the search
  field and the tab bar exactly as iOS draws them.
- **Two iOS versions.** iOS 26 and iOS 27 lay out the search tab
  differently. Everything must work on both.
- Keep the look of `CLAUDE.md`: native iOS 26 components, Liquid Glass,
  no custom search bars, no new floating layers.

## Done when

1. The right search shows every time (job 1 checklist above), on both phones.
2. Press search from Schedule on Thursday in week view → Thursday's week is
   still there behind the field. Same for Day view, a Homework filter, the
   Sent / Deleted folder in Messages, and Me.
3. Type a letter → results replace it. Clear the field → the tab is back,
   still in the same place. Leave search → the real tab is in the same
   place too.
4. Widgets and notifications still open the right day / lesson / homework /
   message; the schedule swipe still snaps; nothing loads twice.
5. `CLAUDE.md` updated (code map + a short note in the struggles section on
   how the backdrop works and why).
