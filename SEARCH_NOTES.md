# Search: what was tried on 29 Sep 2026, and put back

Read this before changing the search. It explains what Dan wants, why it's
hard on iOS 26, every attempt made on 29 Sep and why each one was taken
out, and what to try next. All the code is in git: each attempt names its
commit, and `git show <commit>` or `git checkout <commit> -- <file>` brings
it back.

## In plain words (for Dan)

The search is back to how it was before any of this (commit `4fc2981`):
the search button searches everything the app has at once (homework,
messages and lessons), and Messages and Find a schedule have their own
search bars. Taken out again, in the order they were built:

- **A search per tab.** The search button searched the tab you were on:
  your own lessons from Schedule, anyone's schedule from Find a schedule
  (with its own title), homework from Homework, and so on; Messages and
  Find a schedule lost their own search bars. You said this one worked
  fine (`6f83686`), and it can come back as it was (see "Stage 1" below).
- **The background.** You wanted the screen you were on to stay behind the
  search field, working, until you type. iOS doesn't do that: the search
  button is a tab of its own, and the moment it opens, iOS takes the old
  screen away. I tried five ways around that without being able to run the
  app, and none was good enough: a copy of the tab (slow, jumpy, no field on
  some pages), a field on each page (it went to the top), a still picture
  (gray, and you didn't want a picture), and finally lending the real screen
  to the search tab (never tested).
- **Find on page.** On an open page (a homework, a lesson, a message…)
  typing marked the words in yellow, with "2 of 5" and arrows. It was built
  on top of the background, so it went with it.
- **One tap.** The first tap only opens the field; a second one starts
  typing. Three fixes were tried; none confirmed.

Next time, this should be built with Claude Code running on the Mac, where
it can run the Simulator and see the result before the phone.

## What's in the app now (commit `4fc2981`)

- `RootView.swift`: the native `TabView` with `Tab(role: .search)`. The
  field is `.searchable` on the search tab only (on the `TabView` it leaked
  into every tab's navigation bar, `7840174`), prompt "Homework, messages,
  lessons".
- `SearchTab.swift`: one search across everything the app holds: homework
  and assignments, message threads, and the lessons in the weeks loaded.
- Messages and Find a schedule have search bars of their own (Find a
  schedule with scopes). A pushed screen's search field showed through
  for a moment as it slid in; `quietSearchBarWhilePushing()` makes it
  see-through for the push.

## Stage 1: a search per tab (`7924b15` to `6f83686`) — worked, taken out on request

Dan's earlier session made the search button search the tab you were on
and removed the other search bars (`7924b15`; the task that followed is in
`SEARCH_TASK.md` at `3fe3621`). Then, in this one:

- `5b659c1`, `786f95d`: pressing search on Find a schedule said "Search
  Me", because those screens live in the Me tab. A screen now says whose
  search it is (`.searchedAs(kind)`); `SearchContexts` keeps the last
  screen on show per tab from appearing and disappearing (either order, a
  swipe back let go, leaving the tab), read the moment search is pressed
  through the tab bar's selection binding (`SearchContextTests`). Also:
  search lists hide their own background, as Search Me came out white.
- `9e2b18e`: search from your own schedule no longer listed Find a
  schedule's Pinned and Recent.
- `6f83686`: two searches: your own lessons from your day and week ("Search
  Schedule"), anyone's schedule from Find a schedule ("Find a Schedule").
  Dan: "seems to work fine now".
- `20a5b9d`: the test target built again (a test helper still took the old
  type). **Bring this back with `6f83686`**, or the tests don't build.

To bring Stage 1 back as it was: the files as at `6f83686`, plus
`LectioProMaxTests/SearchContextTests.swift` from `20a5b9d` (that's what
`af38362` was).

## What Dan wants (his words and answers, 29 Sep)

1. **The background.** "is it possible so that background will still show
   as normal when u press search button, so it doesnt feel like its a new
   tab, the stuff only changes when u type something." Exactly where he
   was: the same day, week, folder, open page. **Not a picture**: "i dont
   want a screenshot i want whats actually happens in app."
2. **An "overpowered" search.** On a tab's first page it searches the
   whole tab. On an open page ("if u open like homework in homework tab and
   theres a long text in it") it searches that page's text, marked on the
   page like Find in Safari (his choice over a list of matches). "It should
   work for all" pages.
3. **One tap** opens the field ready to type.
4. **The field always in the same place**, at the bottom.
5. **Close closes**: back to where he was, not a dead field that
   "teleports" you on the next tap.
6. **No lag, opens clearly.** "the problem is more in design and how it
   opens rather then if it works."

## Why it's hard: iOS 26 facts found on the way

- `Tab(role: .search)` is a tab of its own. Selecting it takes the previous
  tab's view off the screen (the tab bar controller swaps them).
- By the time SwiftUI calls the tab bar's selection binding, UIKit has
  already switched: `selectedViewController` is the search tab. Anything
  "taken from the tab on screen" there is taken from the empty search tab.
- `.searchable` on the search tab gives its field (in the tab bar, at the
  bottom) **only to the first page of the navigation stack** in the tab. A
  page pushed on top has no field. A pushed page with its own `.searchable`
  gets a field **in the top bar**, so the field jumps between top and
  bottom.
- One tap: `.searchable(isPresented:)` set to true as the search tab
  appeared was ignored; the first tap still only expanded the field. UIKit
  has `UISearchTab.automaticallyActivatesSearch` (iOS 26) for exactly this;
  it was set by key in the last two attempts, but never confirmed.
- Per-screen search bars (Messages, Find a schedule) flashed as a screen
  slid in and could stick half-way; that's why there's one search in the
  tab bar at all (`7924b15`).
- iOS 27 (the classmate's iPhone 15) puts search back into the tab bar.
  Where the field sits there wasn't checked for any of this.

## Stage 2: the background and find on page — none good enough

All of these were built on top of Stage 1.

| # | Commit | What it did | What happened |
|---|---|---|---|
| 1 | `d1e98a6` | A working **copy of the tab** drawn in the search tab until you type. Where each tab is moved out of `@State` into shared objects (`TabPlaces.swift`) so both copies were on the same day/folder/page. | Search didn't open on an open homework, lesson or Find a schedule: the page was pushed in the copy, and pushed pages have no field. |
| 1b | `09ec12a` | **Find on page** on the copy: `PageFind.swift` (`FindableText` marks matches and reports them through a preference; `.findScroller()` collects them and scrolls; `.findsOnPage()` puts "2 of 5" and ↑↓ in the bar). Added to every page with text. | Built, but it lived on the copy, so it had the copy's problems. The engine itself looked sound (`PageFindTests`). |
| 1c | `89e260c` | Someone's schedule shared its day and weeks with its copy (`TargetPlace`). | — |
| 2 | `b33b17c` | Each pushed page in the copy got **its own `.searchable`**; `isPresented = true` on appear for one tap. | Field at the top on some pages, at the bottom on others. Still two taps. Closing left a field you couldn't type in; tapping again jumped back. |
| 3 | `f22a3f3` | The open page **drawn again as the first page** of the search tab's stack (`.searchPage(kind) { page }`), so the field is always at the bottom. Closing the field goes back (`isPresented` true → false). Activation 250 ms later. `SearchLog` console lines. | "all still works really bad, nothing opens clearly, and really laggy". Causes found on review: a whole second tab built as the tab changed; a redrawn page starts at its top; the keyboard in a second step; `SearchContexts` was observed, so every push and pop anywhere redrew the TabView. |
| 4 | `bcc5308` | A **still picture** of the screen behind the field (a snapshot view of the tab bar controller's selected tab). `automaticallyActivatesSearch` set by key. `SearchContexts` not observed any more. | "works better", but plain gray behind the field (the picture was of the search tab: see the binding fact above), and finding on a lesson's Content side jumped to Overview (the redrawn page starts on Overview, and the first match was the title). |
| 4b | (not committed) | The picture taken as a finger touches the tab bar, by a gesture recognizer that notices and fails at once. | Dropped before testing: Dan doesn't want a picture. |
| 5 | `e536a01` | **The real tab lent to the search tab**: the previous tab's view controller's view moved into the search tab's first page while search is on (`LiveTab`/`LiveTabBox` in `TabBarBridge.swift`), told it's on screen again with `beginAppearanceTransition`, given back when search goes. Find on page on the real page (`PageFind` in every tab's environment; only page parts on screen count; starts on the lesson side on show). | Never tested: Dan asked to put search back as it was first. |

Put back in `af38362` to Stage 1 (`6f83686` with the test fix), then, at
Dan's request, further back to `4fc2981`, before Stage 1.

## Rules learned (don't repeat these)

- **Don't draw a second copy of a tab.** It's slow to open (Schedule builds
  both pagers), and it's never quite where you were (a new page starts at
  its top, on its first side).
- **Don't give pushed pages their own `.searchable`.** Their fields go to
  the top bar.
- **Don't take anything "from the tab on screen" in the selection binding.**
  iOS has switched already.
- **Don't observe `SearchContexts` in `RootView` all the time.** Every push
  and pop then redraws the whole TabView. Read it when search is pressed, or
  only while the search tab is on.
- **A fixed wait before activating the field** makes the keyboard come in a
  second, visible step.
- **Don't hand Dan a round that hasn't been seen running.** Five blind
  rounds cost him five test sessions. Build this with Claude Code on the Mac
  and check it in the Simulator (screenshots, a screen recording with
  `xcrun simctl io booted recordVideo`) before it goes to his phone. The
  Simulator needs his Lectio sign-in, or a small repro view with made-up
  tabs, which is enough for the search's look and feel.

## Ideas for next time (most promising first)

First bring Stage 1 back (see above): everything below builds on the
search per tab.

1. **Attempt 5, tried in the Simulator.** Lending the real tab's view to
   the search tab is the only way found to have exactly what's in the app
   behind the field, with no copy and no picture. Things to watch: whether
   the moved view keeps its bottom safe area (the tab bar's inset comes from
   the tab bar controller); whether taps reach it; whether screens pushed in
   it get `onAppear` (it's been told it's on screen again); the tab bar
   shrinking on scroll inside the search tab; iOS 27. Code: `e536a01`,
   `TabBarBridge.swift`, `SearchTab.swift`, `RootView.swift`.
2. **Search without leaving the tab.** iOS 26 can put a page's search in
   the bottom toolbar (`.searchable` with `DefaultToolbarItem(kind: .search,
   placement: .bottomBar)`, `searchToolbarBehavior(.minimize)`). If that sits
   well with the tab bar, the tab's own screen is simply still there, and
   find on page needs nothing special. Needs a prototype to see where iOS 26
   and 27 put the field when there's a tab bar, and whether pushed pages
   keep it at the bottom.
3. **Find on page on its own.** The engine from `09ec12a` (`PageFind.swift`,
   `FindableText` on the pages' texts, `PageFindTests`) doesn't depend on the
   background: it only needs a field while a page is on screen. It can come
   back once idea 1 or 2 gives the page a field.
4. **One tap.** Try `UISearchTab.automaticallyActivatesSearch` first
   (`TabBarBridge.searchTabActivatesField` in `bcc5308`), and look in the
   console that it was set. Only then SwiftUI's `isPresented`/`searchFocused`,
   and without a fixed wait.
5. **Close closes.** `.onChange(of: isPresented)`: from true to false with
   no result open, go back to the tab search was pressed on (`f22a3f3`).
   Small and independent of the rest; worth keeping whatever the background
   becomes.
