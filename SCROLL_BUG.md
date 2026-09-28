# Day view scroll bug — handoff notes

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

**Current state of `main`:** the Schedule code (`ScheduleTab.swift`, `RootView.swift`,
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
    `LazyHStack(spacing: 0)` → pages with `.containerRelativeFrame([.horizontal, .vertical])`,
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
