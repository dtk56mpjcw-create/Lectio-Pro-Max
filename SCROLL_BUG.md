# Day view scroll bug — handoff notes

## Found (28 Sep): a row wider than the page

**The cause:** on 30 Sep, one row in "Also on" (a cancelled item with a long
name, "Cancelled" in full and a room) came out a little wider than the page.
That made the whole day wider than its scroll view, so the day could move
sideways, and the paging pager around it takes over any drag the day can't
carry further. At the end of the day that took the finger from the day: the
catch, the jump back, no bounce.

It explains every row of the evidence below: paging on (only a paging
scroll view takes a drag over), the pager setup alone never jerking (made-up
days had no such row), only 30 Sep, and the sideways wobble Dan saw. Phones
without a home indicator are narrower, so the row presumably fit there.

**The fix, waiting for Dan to confirm on the real Schedule:**
- `55fb332`: every day and week page holds its content to the page's width
  (`pageWide()`, `containerRelativeFrame(.horizontal)` in `ScheduleTab`),
  so no row can make a page wider than the screen. The lab's "Day no wider
  than the page" switch is the same thing, and it ended the jerk.
- `ae1c45b`: the row itself fits: the room number shares the space with the
  name instead of getting nothing (it drew "0…" and stuck out).
- Native paging and the shrinking tab bar both stay as they are.

Found with the scroll lab: pieces switched off one at a time, then the real
day's parts, then the cancelled row's look. The history below is kept so
none of it is repeated. Once confirmed, remove the lab and its debug hooks
(RootView, SettingsScreen, DayList, SmallItem).

## In plain words (for Dan)

The Schedule tab has two kinds of scrolling, one inside the other:

- **Sideways** — the pager that moves from day to day (and week to week).
- **Up and down** — each day is its own scrolling page.

On a **long day** (one tall enough to scroll, usually a day with an "Also on"
section) the up-and-down scroll misbehaves near the end: it feels cut off, as if
something holds it, then lets go and jumps back, and there's no normal rubber-band
bounce. Short days are fine. It shows most on an iPhone 15 on iOS 27, and it
reproduces in the Simulator.

What we've learned after many tries: **the jerk appears exactly when the sideways
pager has iOS's built-in paging (the snap) switched on, and disappears when it's
off.** It doesn't matter how it's switched on. The goal is to get both:
the native snap sideways *and* smooth scrolling up and down.

**Attempts 10 and 11, really built (Dan, 28 Sep evening): still jerk, and the
long day now scrolled on too far at the bottom (too much empty space under
the last item).** Rolled back: `ScheduleTab.swift` is `main`'s again. The notes
below explain what they tried; keep them so they aren't repeated.

**What attempt 10 tried (rolled back):**
there seem to be **two** causes, and no earlier attempt removed both at once.

1. `.scrollTargetBehavior(.paging)` also reaches the days inside the pager, so
   the days paged up and down.
2. Each page was a little taller than the room it has (it stuck out at the
   bottom by the navigation bar's height), so the pager itself could move up
   and down a bit. A paging scroll view takes over a drag that the view inside
   it can't carry further (that's how Photos moves to the next picture when you
   pan to the edge of a zoomed one). So a pull past the end of a long day went
   to the pager instead of the day, and on release the pager snapped back.

The fix turns on the native paging for the sideways pager only (so nothing
reaches the days) and makes each page exactly as tall as the room it has. See
"Attempt 10" below for how to test it.

**State of `main` before that:** the Schedule code (`ScheduleTab.swift`, `RootView.swift`,
`GlassKit.swift`) is rolled back to how it was before any scroll fix (`7840174`):
`.scrollTargetBehavior(.paging)` on the pagers, the native snap, and the original
long-day jerk. All the attempts below are kept on the branch `scroll-experiments`
(`git log scroll-experiments`); `1e90d72` there is the version without the jerk but
with the home-made snap Dan didn't like.

---

## For Claude Code

### Where the code is

- `LectioProMax/ScheduleTab.swift`
  - `ScheduleTab.pagers`: a `ZStack` holding both pagers, both kept alive. The
    week pager sits on top with opacity 0 in day mode. Each pager has
    `.scrollDisabled(...)` / `.allowsHitTesting(...)` for the mode it isn't in.
  - `dayPager(_:)` / `weekPager(_:)`: `ScrollView(.horizontal)` →
    `LazyHStack(spacing: 0)` → pages with `.pagerPage(height:)` (attempt 10; before
    it, `.containerRelativeFrame([.horizontal, .vertical])`),
    `.scrollTargetLayout()`, `.scrollPosition(id: $dayPage / $weekPage, anchor: .center)`,
    and `onScrollPhaseChange` that calls `align` only if the pager came to rest
    between pages.
  - `NativePaging`: a 1×1 `UIViewRepresentable` probe in the background of the
    pager's stack. It finds the pager's `UIScrollView` by walking up the superviews,
    sets `isPagingEnabled = true`, and uses KVO to switch it back on whenever
    SwiftUI switches it off, which SwiftUI does on updates.
  - `DayPage` / `WeekPage`: each is a vertical `ScrollView` with `.refreshable`.
    Each measures its own `frame(in: .global).maxY` into `@State pageBottom`
    (`onGeometryChange`), and that feeds the content's bottom padding through
    `barClearance(pageBottom:barLine:atLeast:)`.
  - `ScheduleTab` also measures `safeBottom` and `barLine` (the top of the tab bar)
    with `onGeometryChange` on `pagers`. `barLine` is held at the tallest bar so it
    doesn't follow the bar shrinking.
- `LectioProMax/RootView.swift`: a `TabView` with `.tabBarMinimizeBehavior(.onScrollDown)`.
  `.searchable` sits on the Search tab only.

### Project facts

- iOS 26 deployment target. Swift 5 language mode with Approachable Concurrency.
  SwiftUI with Liquid Glass.
- There's no demo data. Seeing real long days in the Simulator needs a Lectio
  login, and **Dan logs in himself — never handle his password.** For isolated
  testing, build a minimal repro instead (see Experiment 0).

### Evidence so far (all commits are in git; `git show <hash>` for details)

| Commit | Sideways pager | Days (vertical) | Result |
|---|---|---|---|
| before `8379930` | `.scrollTargetBehavior(.paging)` | inherited it | **jerk** on long days |
| `8379930` | same, plus `barLine`/inset held at the tallest tab bar | inherited | jerk |
| `42425b4` | same, plus tab bar minimize off (restored later) | inherited | jerk |
| `171c4ec` | same, plus `align` only when between pages | inherited | jerk |
| `18e85c7` | same, pages `containerRelativeFrame(.horizontal)` only (reverted later) | inherited | jerk |
| `8bc7cbf` | `.paging` | `FreeScrolling` (a custom behavior with an empty `updateTarget`) | **jerk** |
| `7eb549c` | no behavior; `NativePaging` sets `isPagingEnabled` once, which **didn't stick** | none | **vertical fixed**; sideways scrolled freely, no snap |
| `1e90d72` | no behavior; snap done by hand in `onScrollPhaseChange` (`scrollTo` on interacting→decelerating) | none | vertical fine; sideways snap slow and unnatural |
| `9e90dcc` | no behavior; `NativePaging` with KVO keeping `isPagingEnabled` on | none | **jerk back** (sideways snap presumably fine — confirm) |

Console logs from the debug build (`fc8e42b`) showed that on a long day, a slow
release near the end made the day's scroll phase go **interacting → idle at the
same offset, with no decelerating and no bounce**, and nothing in the app redrew in
between. A frame-by-frame look at a screen recording showed that a pull past the end
was yanked back within one frame while the finger was still down.

### What that means

- **Earlier theory, now doubtful:** "`.scrollTargetBehavior` is inherited by the
  nested vertical `ScrollView`s, so the days paged vertically." `.paging` is
  inherited, but `9e90dcc` has no behavior anywhere and still jerks.
- **What fits every row:** the jerk happens whenever the **pager's own
  `UIScrollView` has paging on**, whether SwiftUI's `.paging` turned it on or we
  did. When paging is off (`7eb549c`, `1e90d72`), vertical scrolling is perfect.
  - Most likely mechanism (unverified): a paging `UIScrollView` runs its
    snap-to-page logic when its pan ends, even after a purely vertical drag. SwiftUI
    then sees the pager change scroll phase or geometry, re-renders, and the inner
    day's bounce animation is cancelled (interacting → idle).
  - Things the app does that could turn a pager update into a visible jerk:
    - the `scrollPosition(id:)` write;
    - the `onGeometryChange` state writes (`pageBottom`, `barLine`,
      `safeBottom`) that change the day's bottom padding, and so its content
      height, right at the end of the content.

### Attempt 10: both causes at once (waiting for Dan's test)

Reading the table again, two mechanisms fit every row, and no attempt ever
removed both:

- **A. Inherited paging.** `.scrollTargetBehavior(.paging)` on a pager reaches
  the days and weeks inside it, so they paged vertically (seen in the `8bc7cbf`
  logs). Present in every row that used `.paging`.
- **B. Pages taller than the pager.** `.containerRelativeFrame([.horizontal, .vertical])`
  made each page as tall as the whole pager and then set it below the navigation
  bar (see the old `barClearance` comment), so the pager's `UIScrollView` had a
  vertical range the height of the navigation bar. UIKit hands a drag from a
  nested scroll view that has hit its edge to an enclosing **paging** scroll
  view (the PhotoScroller behaviour). So at the bottom of a long day, a pull
  past the end went to the pager: the day stopped at its edge with no bounce
  (the logged "interacting → idle at the same offset"; the "yanked back within
  one frame while the finger was still down"), and on release the pager paged
  back vertically. Short days don't scroll, so they never reach an edge. A
  non-paging pager doesn't take drags over, which is why `7eb549c` and
  `1e90d72` were smooth even though B was there.

| Row | A (inherited paging) | B (tall pages + paging pager) | Result |
|---|---|---|---|
| before `8379930` … `171c4ec` | yes | yes | jerk |
| `18e85c7` | yes | no | jerk |
| `8bc7cbf` | no (FreeScrolling) | yes | jerk |
| `7eb549c`, `1e90d72` | no | no (pager not paging) | smooth |
| `9e90dcc` | no | yes | jerk |
| **attempt 10** | no | no | **to test** |

The change (in `ScheduleTab.swift`):

- The pagers have no scroll behaviour. `NativePaging` (the KVO version from
  `9e90dcc`) switches UIKit's paging on for the pager's own scroll view, so the
  snap is the system's.
- Pages use `pagerPage(height:)`: the pager's width, and the height the pager
  has room for (measured once with `onScrollGeometryChange`: the container height
  minus the content insets). The pager can no longer move up and down.
- Debug builds print, in Xcode's console, the pager's size and insets once, and
  a line **"pager moved up/down"** if the pager ever moves vertically. It never
  should.

How to test (Simulator, then the iPhone 15 on iOS 27):

1. ⇧⌘K, then ⌘R.
2. Go to a long day. Slow drag past the end, hold, release: it should bounce
   like any list. Then flick to the end.
3. Swipe sideways between days: it should snap like before.
4. Today button, a day tapped in week view, and day ↔ week switching.
5. Look at the console. "pager moved up/down" should never appear.

If it still jerks: copy the `NativePaging:` lines from the console. If they show
the pager moving, B isn't fully fixed (the page height is off). If they don't,
B was right but not enough; go on with the experiments below. When it's
confirmed, remove the debug logging (`watchForDrift`).

**Attempts 10, 11 and 12 were never really tested.** The "still jerks" reports
below came from an old build: Dan's console showed `ScrollDebug` lines ("DayPage
2026-09-30 idle → interacting  y 9 of 282", "bottom 874.0 (was 0.0)") that only
exist in `fc8e42b`, `8bc7cbf` and `7eb549c`, and none of attempt 10's
`NativePaging:` lines, which print once at every start. The folder his Xcode
builds from wasn't on this branch. Check that first next time: the console
must show `NativePaging:` lines.

What that old build's log does show (30 Sep, iPhone 17 size): the day is 924 pt
of content in 758 pt, so it ends at offset 166; a fling there bounced normally
(decelerating 186 → 166), but a slow pull only got to 172 and went
"interacting → idle" at 166 with no bounce — the jerk, as before.

**Reported for attempt 10 (from the old build, see above):** still jerks on
the long day (Wed 30 Sep), but only on phones without a home button; on the
iPhone SE 3 it's fine. `42425b4` had noticed the same (iPhone 15 yes, SE no).

### Attempt 11: C, the tab bar shrinking (waiting for Dan's test)

- **C. The bottom moving mid-scroll.** On phones with a home indicator, iOS 26's
  tab bar shrinks as you scroll down (`.tabBarMinimizeBehavior(.onScrollDown)`)
  and grows back as you scroll up. `ScheduleTab` measured the top of the bar
  (`barLine`) and the bottom safe area (`safeBottom`) live, and every page's
  bottom padding (`barClearance`) follows them. So each page's length changed
  under the finger right at the end of a long day. `8379930` saw this in the
  logs and held the measurements at the tallest bar, but that was rolled back
  with everything else in `0ab14a2`, so attempt 10 had C back.
- Every earlier row had at least one of A, B or C. Attempt 11 = attempt 10 plus
  the hold from `8379930` (`barLine` only moves up, by less than a bar, or at a
  new width; `safeBottom` only grows).
- Debug builds also print "tab bar line …, held at …" whenever the bar moves
  away from the held line. Seeing those while scrolling confirms C happens; the
  pages no longer follow it.

If it still jerks: in Xcode's console, filter by `NativePaging`, reproduce, and
copy the lines. "pager moved up/down" means B isn't fixed; "tab bar line" lines
with a jerk would mean something else still follows the bar.

**Result of attempt 11 (Dan, 28 Sep):** still jerks. Dan's suggestion: compare
the day that jerks with the ones that don't. 30 Sep is built like every other
day; the only difference is its length. It's the one day long enough to scroll
far enough for iOS 26 to shrink the tab bar (`.tabBarMinimizeBehavior(.onScrollDown)`),
and the bar grows back when the page bounces at the end. The SE never jerked.

### Attempt 12: no shrinking tab bar (waiting for Dan's test)

- **D. The bar resizing under a paging pager.** When the bar shrinks or grows,
  the bottom of the screen changes and the views under it are laid out again.
  A paging `UIScrollView` snaps its offset back onto a page when it's laid out.
  Hypothesis: that's the yank. It fits every row: paging off (`7eb549c`,
  `1e90d72`) never jerked even with the shrinking bar on; the SE (no shrinking
  bar, if confirmed) never jerked; short days never scroll far enough to shrink
  it. The one row with shrinking off (`42425b4`) still had A.
- Change: `RootView` no longer sets `.tabBarMinimizeBehavior(.onScrollDown)`.
  The bar keeps its size, which is the system's default and iOS 27's only
  behaviour. One change, nothing else.
- **Taken back out at Dan's request** (he wants the shrinking bar), before it
  was ever built: the test above ran the old build. The shrinking bar is on
  again. If attempts 10 and 11, really built, still jerk, this is the next
  thing to test (turn it off for one run only).
- Confirm: (1) on the SE, scroll Homework down: does the bar shrink? If not,
  that's why the SE never jerked. (2) Face ID phone, 30 Sep: jerk gone?
- If it's gone: keep it; later, try going back from `NativePaging` to the
  standard `.scrollTargetBehavior(.paging)` alone, to see whether A was real.
  If it isn't gone: D is wrong; the console lines (`NativePaging` filter) are
  needed before anything else.

### Experiment 0, built: the scroll lab (`ScrollLab.swift`, debug builds only)

Me → Settings → Testing → **Scroll lab in Schedule** puts a test pager with
made-up days in the Schedule tab's place, inside the real tab bar. No Lectio
data. The slider button (top right) switches each piece of `main`'s
ScheduleTab on or off:

| Switch | What it is in ScheduleTab |
|---|---|
| Paging: none / SwiftUI / UIKit | `.scrollTargetBehavior(.paging)`; UIKit = `isPagingEnabled` kept on by a probe |
| Pages as tall as the pager | `.containerRelativeFrame([.horizontal, .vertical])` (off: `.horizontal` only) |
| Pull to refresh | `.refreshable` on each day |
| Tracks the page | `.scrollPosition(id:anchor: .center)` and `align` on idle |
| Bottom room measured | `safeBottom`/`barLine`/`pageBottom` measured live, `barClearance` padding (off: fixed 130 pt) |
| Pager under the tab bar | `.ignoresSafeArea(.container, edges: .bottom)` |
| Second pager behind | the hidden week pager in the `ZStack` |
| Tab bar shrinks | `.tabBarMinimizeBehavior(.onScrollDown)` (off: the default) |
| Day length | 4, 8 (like 30 Sep) or 16 rows of module height |

"Like the Schedule" switches all of them on; "Bare minimum" leaves SwiftUI
paging and the shrinking bar. Every page prints its setup under its title,
so a screen recording says which setup it is. The console (filter `Lab:`)
logs each day's scroll phases ("interacting → idle at 166 of 166" with no
"decelerating" in between is the jerk), the pager's size once ("room to move
up/down"), and any vertical movement of the pager.

Test plan, on a phone with a home indicator (the jerk never shows on the SE):
1. "Like the Schedule", 8 rows: does it jerk like the real 30 Sep? If not,
   the jerk needs something in the real day's content, not the pager setup.
2. "Bare minimum": does it jerk? If yes, it's iOS: SwiftUI paging over
   scrolling pages in a shrinking tab bar. Then try UIKit paging, and the
   bar fixed, one at a time.
3. If only (1) jerks: from "Like the Schedule", switch pieces off one at a
   time until it stops. That piece is the cause.

**Result (Dan, 28 Sep): with made-up days, both "Like the Schedule" and "Bare
minimum" scroll fine** on a phone with a home indicator. So the pager setup
alone doesn't jerk: the cause needs something in the real days' content.
Dan's suspects, from what 30 Sep has: the "Also on" section, a cancelled
lesson in it, and the "All day" row (Musikteater, audition 08:15–15:30).

So the lab can now show **real days** (drawn by the Schedule's own `DayList`,
today on the middle page) and leave parts of them out: cancelled lessons,
Also on, All day (`LabLeaveOut`, applied to the day's plan through a
debug-only `DayList.labLeavesOut`). Leaving a part out shortens the day, so
"Made-up rows at the end" keeps it long enough to scroll. "Made-up rows are
buttons" tests whether pressable cards matter. The presets now only set the
pager pieces, not what the days show.

Next test plan:
1. "Like the Schedule", Real days on, made-up rows None, swipe to 30 Sep:
   does it jerk in the lab? (It should, if the content is the cause.)
2. Leave out one suspect at a time, with 8 made-up rows so the day stays
   long: cancelled; Also on; All day. The one that stops the jerk is it.
3. If none does: made-up days again, rows as buttons.

**Result (Dan, 28 Sep): the real 30 Sep jerks in the lab too. "Leave out
cancelled" stops it; leaving out the other parts (All day, Also on's other
items) doesn't.** So it isn't the day's length (leaving out All day shortens
it about as much, and it still jerks): it's the cancelled item in Also on.

Nothing in a cancelled row obviously moves while scrolling: `SmallItem` draws
it like any other row, only struck through, grey, with a red "Cancelled"
(`.fixedSize()`) and no topic. So the lab narrows it down further, under
"Cancelled rows" in its menu:

| Switch | What it tells |
|---|---|
| Leave out cancelled in Also on only | whether it's that item (free modules and before/after keep theirs; "Leave out cancelled, everywhere" also cleared those) |
| Cancelled in Also on drawn as normal | the row stays, the day keeps its length, but it's drawn as not cancelled: the look or the item? |
| Cancelled not struck through | the strikethrough (`SmallItem`, through a debug-only `labCancelledLook` environment value) |
| No red "Cancelled" | the red label |

Test each switch on its own, on the real 30 Sep, from "Like the Schedule",
made-up rows None.

**Result (Dan, 28 Sep): "No red Cancelled" stops the jerk.** The switch took
the whole label away, so it's the label: its colour or its layout. The label
is `Text("Cancelled")`, 12.5 semibold, `.foregroundStyle(Palette.negative)`,
`.lineLimit(1)`, `.fixedSize()`. `Palette.negative` is a `Color(UIColor { traits in … })`,
a hand-made light/dark provider (so are `warning` and `positive`).

Next switches, under "The red Cancelled" (the label stays, the same size):

| Switch | If it stops the jerk |
|---|---|
| In grey | it's the colour, not the label's layout |
| In plain system red (SwiftUI's `.red`) | it's `Palette.negative`'s UIColor provider, not red as such; then the fix is Apple's usual way for light/dark colours (asset catalog colours), for all three status colours |
| Not fixed size | it's the `.fixedSize()` layout |

**Result (Dan, 28 Sep): grey jerks, plain system red jerks, not fixed size
doesn't jerk.** So the colour doesn't matter: it's the label's `.fixedSize()`.

Why exactly is still open. Other `.fixedSize()` views in the day don't
jerk: every lesson card's room, and the All day strip's "08:15–15:30" on
30 Sep itself. What's special about this one: it sits in `SmallItem`'s
`HStack` between a name with `.layoutPriority(1)` and a `Spacer` plus a room
that can shrink, near the bottom of the day, inside a pressable
`OpenButton`. `KindTag` (the "Exam" tag) sits in the same place in the
same row for an exam in Also on, with its own `.fixedSize()`: watch for a
long day with one.

**The fix (to confirm on the real Schedule):** the label keeps its whole
width through `.layoutPriority(2)` (it gets its room before the name, the
standard SwiftUI way to say who gives way) instead of `.fixedSize()`. The
lab's "Not fixed size" switch is now "Fixed size, the old way (jerks)", to
bring the jerk back and compare.

**First test of the fix (Dan, 28 Sep): no jerk on the real 30 Sep, but the
label showed as "C…".** The priority sat under the lab's debug-only
`.fixedSize(false, false)` and never reached the stack, so that build had a
squeezed label, not the planned layout. `f950e6d` puts `.layoutPriority(2)`
last: the label is back to its full width, the same geometry as with
`.fixedSize()`, only without it. **Test again:** if 30 Sep still doesn't jerk,
`.fixedSize()` itself was the trigger. If it jerks again, the trigger is the
row's geometry (the label at full width), not the modifier.

**Second test (Dan, 28 Sep): with "Cancelled" in full, the jerk is back.**
So it isn't `.fixedSize()`: it's the row with the whole label in it. Dan's
read: the full "Cancelled" pushes past the room the row leaves for the room
number.

Hypothesis (one): with the label at full width, `SmallItem`'s row comes out
wider than its card (the name and the label take their room, the room
number can't shrink below "0…"), so the day's content is a little wider
than the page. A scroll view whose content is wider than it can move
sideways, and a paging scroll view takes over a drag that the scroll view
inside it can't carry further (the handoff from attempt 10's B, only
sideways). That fits: the catch and no bounce (the day's drag ends when
the pager takes it), the sideways movement Dan saw on that day, paging
needed, and the label only at full width.

Test in the lab (Real days, 30 Sep): the console ("Lab:") prints the day's
content width, what the scroll view makes of it ("scrolls 366.40 wide in
366.00") and any sideways movement. Then "Day no wider than the page" (in
Pieces) holds the content to the page's width
(`.containerRelativeFrame(.horizontal)`): if that stops the jerk, the
hypothesis holds. The real fix would then be the row itself never coming
out wider than its card, plus the hold as a guard for every day.

**Third test (Dan, 28 Sep): "Day no wider than the page" stops the jerk.**
Hypothesis confirmed; see the top of this file for the fix.

Remove the lab (and its lines in RootView, SettingsScreen, DayList and
SmallItem) once the fix is confirmed.

### Experiments, cheapest first

For each one, test in the Simulator on a long day:

- slow drag past the end, hold, then release;
- a flick to the end;
- a sideways flick between days;
- the Today button;
- tapping a day in week view;
- switching between day and week.

0. **Confirm the link.** Log the *pager's* `onScrollPhaseChange` while dragging a
   long day only vertically. If the pager goes interacting → decelerating → idle
   during a vertical drag, that's the coupling. Also print what `NativePaging`
   attached to (its `contentSize` should be very wide), to rule out attaching to
   the wrong scroll view.
   A **minimal repro** answers "platform bug or app-specific?". It needs no login:
   - a horizontal paging `ScrollView` → `LazyHStack` → full-size pages, each a
     vertical `ScrollView` with ~2 screens of rows and `.refreshable`;
   - run it on iOS 26 and 27 simulators;
   - if it jerks, it's the platform; if not, add the app's pieces one at a time:
     `pageBottom` padding, `scrollPosition(id:)`, `tabBarMinimizeBehavior`, the
     `ZStack` with the second pager.
1. **Stop the padding feedback.** Replace the measured `pageBottom`/`barLine`
   bottom padding with something that doesn't change during a scroll, e.g.
   `.contentMargins(.bottom, <fixed tab-bar clearance>, for: .scrollContent)` or
   `.safeAreaPadding(.bottom, …)`. Keep `NativePaging` on. If the jerk goes, done.
2. **A snap SwiftUI does by target, not by `isPagingEnabled`.** Remove
   `NativePaging` and try `.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))`
   on the pagers (they already have `.scrollTargetLayout()`). Or try a custom
   `ScrollTargetBehavior` that only changes the target when `context.axes` is
   horizontal: velocity picks ±1 page, a slow release goes to the nearest page.
   `8bc7cbf` suggested that *any* behavior reaching the days broke their bounce,
   but that was with `.paging` also on the pager, so it's worth re-testing.
3. **UIKit pager (most robust).** Replace the SwiftUI horizontal `ScrollView` with
   a `UIPageViewController(transitionStyle: .scroll)`, or a `UICollectionView`
   with `isPagingEnabled` and `UIHostingConfiguration` cells, hosting `DayPage` /
   `WeekPage`. It's the Calendar-style setup, and SwiftUI no longer coordinates
   the pager with the days inside it. You need to:
   - pass `LectioSession` in with `.environment(session)`;
   - keep `selectedDate` / `dayPage` in sync;
   - keep the Today button and week-day taps working;
   - keep the day/week switch (`ScreenZoom`) and `.refreshable` working.
4. **`TabView` with `.tabViewStyle(.page(indexDisplayMode: .never))`.** A quick
   try, but it may share SwiftUI's scroll machinery.

When it's fixed, remove the debug logging and write the commit message in plain
language, saying why the change was made.

---

## Other open items

- **Waiting for confirmation on a classmate's iPhone 15 (iOS 27):**
  - long elevfeedback text wraps (`f04461d`, `WrappingTextView` in `FeedbackEditor.swift`);
  - the search field shows only on the Search tab (`7840174`);
  - pull-to-refresh works in week view.
- `docs/privacy.html` and `docs/terms.html` still have `[kontakt]`/`[contact]`
  placeholders. Dan picks the contact address; host them on GitHub Pages later.
- Run the tests (⌘U) and push.
