# Lectio Pro Max — notes for Claude Code

Lectio Pro Max is a native iOS app for **Lectio**, the school system used by
Danish gymnasiums. It's unofficial: not made by Macom (Lectio's maker) or any
school. Dan (Ivan Surov), a student, built it for himself and his classmates.
It shows the schedule, homework, assignments with hand-ins, messages, grades,
absence and elevfeedback. It also has widgets, lesson reminders and a
background check that notices changes.

Read this file first, and `SCROLL_BUG.md` before touching the Schedule tab's
scrolling.

---

## Working with Dan

- Dan isn't a professional iOS developer. Explain things in plain words, keep
  replies short, and say clearly what he needs to do (for example "⇧⌘K, then
  ⌘R").
- He tests in the iPhone 17 Simulator and on real phones. One of them is a
  classmate's **iPhone 15 on iOS 27**. Anything touching layout, tab bars or
  scrolling must work on **iOS 26 and iOS 27**.
- **Find the cause before changing code.** Reproduce the problem, form one
  hypothesis, test it, and only then fix. Don't pile guess on guess: the
  scroll bug (see below) went through about ten guessed fixes and got worse.
- When a fix "does nothing", suspect a stale build first: clean (⇧⌘K) and
  run again.
- Keep commits small, one topic each. Never force-push or rewrite `main`'s
  history.
- A full backup of the project, from before Claude Code got involved, sits on
  Dan's Mac in `~/Desktop/LectioProMax Backup 28 Sep`.

### Hard rules

- **Never type, ask for, store or log Dan's Lectio password or any
  credentials, tokens or cookies.** Signing in happens only in
  `LoginWebView`, done by Dan himself.
- When exploring Lectio, **read only**. While testing, never send messages,
  delete things, hand in, change groups or do anything else that writes to
  the school account or affects other people.
- Don't put Dan's email address anywhere. The `[kontakt]`/`[contact]`
  placeholders in `docs/privacy.html` and `docs/terms.html` wait for an
  address Dan chooses.

### Commit messages

Commit titles are plain English and describe what the user notices, e.g.
"Search field only on the Search tab" or "Long feedback wraps, the Next line
fits". The body explains why the change was needed and what caused the
problem.

---

## Build, run, test

- `LectioProMax.xcodeproj` has three targets:
  - `LectioProMax`, the app;
  - `LectioWidgetsExtension`;
  - `LectioProMaxTests`, which uses Swift Testing (`import Testing`, `@Test`).
    Run the tests with ⌘U or `xcodebuild test`.
- iOS **26.0** deployment target. **Swift 5 language mode**, with
  **Approachable Concurrency** on (`NonisolatedNonsendingByDefault`):
  - A plain `nonisolated async` function runs on the caller's actor, which is
    usually the main actor.
  - Network and parsing entry points in the `Lectio…Service` enums are marked
    `@concurrent` so they run off the main thread. Do the same for any new
    heavy work.
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on: import the module
  whose members you use (`import UIKit` for UIKit APIs).
- The cloud sessions have no Swift compiler. A syntax-only check catches
  typos: `pip install tree-sitter tree-sitter-swift`, then parse each file
  and look for ERROR nodes. It misreads `as? T ?? x` and `if let x = try?
  await …` (false alarms), and can't see type errors such as name clashes.
- There's no demo or mock data. Seeing real content needs a Lectio sign-in in
  the Simulator, and Dan does that himself. For layout and scroll experiments,
  a small self-contained repro view is often better.

### Signing

- Dan uses free Personal Teams: `L78DTW7MMS` (first Apple ID, "Ivan Surov"),
  `7X3U94Z6DH` (second, "Ivan S") and `DGKB47XJB8` (third). Free teams can only register about 3
  iPhones each; devices can't be deleted (registrations expire after about a
  week), and there's no TestFlight. Friends' phones are spread across the
  teams.
- **The IDs follow the team.** Pick the Team in Signing & Capabilities for
  **all three targets** (app, widgets, tests) and everything else follows,
  through project-level build settings:
  - `APP_ID_ROOT = $(APP_ID_ROOT_$(DEVELOPMENT_TEAM))`, with
    `APP_ID_ROOT_L78DTW7MMS = com.ivan.lectiopromax` and
    `APP_ID_ROOT_7X3U94Z6DH = com.ivan.lectiopro`,
    `APP_ID_ROOT_DGKB47XJB8 = com.ivan.lectiopro3`;
  - app `$(APP_ID_ROOT)`, widgets `$(APP_ID_ROOT).LectioWidgets`, tests
    `$(APP_ID_ROOT).tests`;
  - app group `APP_GROUP_ID = group.$(APP_ID_ROOT)`, used in both
    `.entitlements` files and passed to Swift through the `LectioAppGroup`
    key in both Info.plists (`WidgetFeed.appGroup` reads it).
  - **A new Apple ID** needs one more project-level line,
    `APP_ID_ROOT_<its team ID> = <a new, unused ID>` (for example
    `com.ivan.lectiopro3`). Without it the bundle ID comes out empty and
    the build fails.
- The background task is `com.ivan.lectiopro.refresh` whatever the team
  (`Info.plist` and `BackgroundCheck.taskID`); it isn't registered with Apple.
- The deep-link scheme is still `lectiopromax://` (see `Shared/AppLink.swift`).
- **Friends' phones** are installed by cable from Xcode, as a **Release**
  build (Edit Scheme → Run → Build Configuration → Release). A Debug build
  shows Settings' Testing section. Each phone needs iOS 26, Developer Mode,
  and Dan's Apple ID trusted under VPN & Device Management; the app stops
  opening after 7 days until it's installed again. The free team's device
  slots run out fast; TestFlight needs the paid Apple Developer Program.

---

## Map of the code

| Area | Files |
|---|---|
| App entry, sign-in gate | `LectioProMaxApp.swift`, `ContentView.swift` (`LoginScreen`), `LoginWebView.swift` (the only web view: UNI-Login / MitID) |
| Tabs | `RootView.swift`: a native `TabView` with Schedule, Homework, Messages, Me, and Search (`Tab(role: .search)`). The search button searches **the tab you were on** (`SearchTab.swift`): Schedule → anyone's schedule and your lessons, Homework → homework and assignments, Messages → messages, Me → absence, grades, study plan and the Me pages. A screen can belong to another tab's search: Me › Find a schedule and someone's schedule search Schedule (`.searchContext(.schedule)`, `SearchContexts`, read the moment search is pressed). No other screen has a search bar (Dan's call: they flashed on push and stuck half-way) |
| State | `LectioSession.swift`: `@MainActor @Observable`, holds `snapshot`; `SnapshotCache` is the offline copy |
| Network | `LectioHTTP.swift` (URLSession plus the cookie jar), `CookieVault.swift` (Keychain, this device only), `LectioForms.swift` (ASP.NET postbacks) |
| Services | `LectioService`, `LectioStudyService`, `LectioMessagesService`, `LectioMeService`, `LectioFeedbackService`, `LectioHandInService`, `LectioEventService` |
| Parsing | `LectioParser.swift`, `HTMLDocument.swift`, `HTMLNode.swift`: Lectio's HTML scraped; selectors reverse-engineered from real pages; Danish text |
| Schedule logic | `DayPlan.swift` (what an item is, `ClassNames`), `DayAgenda.swift`, `WeekAgenda.swift`, `LectioDates.swift` (always Danish time: `LectioDates.calendar`) |
| Schedule UI | `ScheduleTab.swift`: day and week pagers, `DayPage`/`WeekPage`, `ScreenZoom` day↔week switch, `PageHeading` |
| Find a schedule | `FindScheduleScreen.swift` (Me › Find a schedule: a native `List` with Pinned and the last 3 Recent (`FindMemory`), Browse lists with the iOS 26 section index, Teams via `TeamDirectory`; searching is the tab bar's, from Schedule), `TargetScheduleScreen.swift` (their schedule with the same pagers, `DayList` and `WeekAgenda` as yours; `ScheduleOwner` in the environment changes what the cards show). `IndexedTargetList.swift` is only the group hand-in picker now |
| Lesson page | `LessonDetailSheet.swift` (`LessonDetailScreen`: Overview and Content, a segmented control on a glass capsule plus paging; Overview is lesson info, the note and Elevfeedback, Content the homework and other content, by Dan's choice), `LessonContentView.swift`, `LessonContentReader.swift` (Lectio's editor HTML into paragraphs, links, pictures), `LessonBlocksView.swift` |
| Widgets | `Shared/WidgetFeed.swift` (JSON in the app group), `WidgetFeedBuilder.swift`, `LectioWidgets/` |
| Background and notifications | `BackgroundCheck.swift`, `ScheduleWatch.swift`, `NotificationService.swift`, `Reminder*.swift` |
| Design kit | `GlassKit.swift` (Palette, Metrics, ContentCard, GlassCircleButton, PressableCard…), `TypeScale.swift`, `SubjectColor.swift`, `NavigationChrome.swift` |

The code is heavily commented with *why* things are the way they are, often
naming a bug that was fixed. Read the comment before changing something that
looks odd, and keep writing comments in the same style: plain English, the
reason, not just the what.

---

## Design language

The goal: **it should feel like an app Apple made for iOS 26.** Reference apps
are Calendar (schedule, week view, the Today button), Settings (grouped cards),
Mail (messages) and Reminders.

1. **Native first.** Use the system's components and let them behave as they
   do elsewhere:
   - `TabView` with the Liquid Glass tab bar;
   - `NavigationStack` with large titles and standard pushes;
   - system sheets;
   - `.searchable`, `.refreshable`, swipe actions, context menus.
   Don't hand-roll a copy of something the system provides. Earlier
   hand-made versions (a custom tab bar, pinch-to-zoom between day and week)
   were removed for that reason.
2. **Liquid Glass only on the navigation layer**: the tab bar, toolbars and
   floating controls (`GlassCircleButton`, `.glassEffect(.regular.interactive())`).
   Content stays solid:
   - `.contentCard()` is the grouped cell colour on `systemGroupedBackground`,
     with no border and no translucency, as in Settings;
   - never glass on content, never glass on glass;
   - group glass in a `GlassEffectContainer`.
3. **Colour comes from the system.**
   - The accent is the `AccentColor` asset (system blue).
   - Status text uses `Palette.warning/positive/negative`: Apple's system
     orange, green and red as they are (Dan's choice, Sep 2026). Increase
     Contrast gives Apple's darker versions. No hand-picked colours.
   - **No gradients, glows, beige or "warm sunset" palettes.** The app had
     one, and it looked generated rather than native.
   - Subject colours come from `SubjectPalette`: Apple's system colours, the
     seven most distinguishable first (red, orange, yellow, green, teal,
     blue, purple).
   - Colour is only a cue. The subject's name is always printed next to it,
     in normal text colour, never in the subject colour.
4. **Type.**
   - Use the SF system font at exact tuned sizes through
     `.scaledFont(size:weight:)`, so everything follows Dynamic Type. Don't
     use a bare `.font(.system(size:))`.
   - Large page titles are 34 bold, a lesson name 17, details 13.5.
   - Headings were measured to sit exactly where the system's large titles
     do; keep them aligned across tabs.
5. **Spacing.** `Metrics.card` radius 18, `Metrics.inner` 12, page margin 18.
   Touch targets are at least 44 pt.
6. **Motion and haptics.**
   - Motion is short and springy (`.snappy`, springs).
   - Pressed rows shrink slightly (`PressableCard`), or dim instead when
     Reduce Motion is on.
   - Haptics use `.sensoryFeedback` (selection, success).
   - Motion should feel like the system's own. The day/week paging must feel
     exactly like native paging: Dan rejected a slower hand-made snap.
7. **Accessibility.** Dynamic Type everywhere, VoiceOver labels on icon-only
   buttons, header traits on titles, and contrast checked.
8. **Words.**
   - The UI is in English, in sentence case, short and plain.
   - Be honest about limits, e.g. "Lectio empties Deleted after 3 months".
   - No "unofficial app" line in the app, by Dan's choice (Sep 2026):
     Settings ends with "Made by good people". `docs/privacy.html` and
     `docs/terms.html` still say it's unofficial.
   - Keep Lectio's own Danish names where they *are* the name (Elevfeedback,
     Elevtid).
   - Anything with a time from Lectio is in Danish time.
9. **Performance is part of the design.**
   - Screens redraw only for what they read (Observation, `Equatable` views
     such as `DayOfWeek`).
   - Parsing and network work run off the main thread.
   - Lessons are prefetched, so they open instantly.

---

## Struggles so far (learn from them)

### 1. Day view scroll jerk — FIXED (confirmed 28 Sep 2026)

- **Cause:** a row a little wider than the page (on 30 Sep, a cancelled
  "Also on" item with "Cancelled" in full) made the day wider than its
  scroll view. The day could move sideways, and the paging pager took the
  drag over. Fixed by holding every day and week page to the page's width
  (`pageWide()` in `ScheduleTab`) and by letting that row fit. See the top
  of `SCROLL_BUG.md`.
- Found with a scroll lab (a debug-only test pager whose pieces switched
  on and off), since removed; it's in git history (`5d070fd`…`3c1aaa8`).
- The history below is what didn't work.

- On a long day (one with an "Also on" section, taller than the screen), the
  vertical scroll catches near the end, jumps back and doesn't bounce.
- It happens exactly when the sideways day/week pager has native paging on.
  Removing paging fixes the jerk, but loses the native snap Dan wants.
- `main` is back to the original `.scrollTargetBehavior(.paging)`, which has
  the native snap and the jerk.
- Every attempt is on the branch `scroll-experiments`, and `SCROLL_BUG.md`
  lists each attempt, its result and ranked next experiments.
- **Attempt 10** (rolled back): two suspected causes removed together. The
  pager paged with UIKit's own paging (`NativePaging`), so nothing reached
  the days, and each page was exactly as tall as the room under the
  navigation bar (`pagerPage`), so the pager couldn't take over a pull past
  the end of a long day. See "Attempt 10" in `SCROLL_BUG.md`.
- The jerk happens only on phones with a home indicator, never on the SE 3.
- **Attempt 11** (rolled back): also held the tab bar measurements
  (`barLine`, `safeBottom`) at the tallest bar.
- A first test of 10 and 11 ran an old build by mistake (its console
  showed `ScrollDebug` lines from `fc8e42b` to `7eb549c`). Before trusting a
  test, make sure Xcode builds the folder you pulled, and delete the app from
  the phone first ("Failed to terminate process" means the old one kept
  running).
- **Attempts 10 and 11, really built: still jerk,** and the long day scrolled
  on too far at the bottom. Both rolled back: `ScheduleTab.swift` is `main`'s
  again. See `SCROLL_BUG.md` for what they tried.
- **Attempt 12** (no shrinking tab bar) was reverted at Dan's request, before
  it was really built: he wants the shrinking bar.
- **Don't repeat those attempts.** They all changed the pager; the cause
  was in the content.

SwiftUI scroll facts learned the hard way:

- `.scrollTargetBehavior` reaches **every nested scroll view**, not just the
  one it's set on.
- Any scroll behaviour on a scroll view makes SwiftUI set where a scroll
  ends. A slow release in the bounce region then jumps instead of bouncing.
- SwiftUI turns `UIScrollView.isPagingEnabled` back off when it updates a
  scroll view that it wasn't told to page.
- `@State` written from `onGeometryChange` during a scroll re-lays out the
  page mid-gesture. Keep such writes rare and only on real changes.
- Content wider than a vertical scroll view, even by a little, lets it move
  sideways, and a paging scroll view around it then takes the drag over.
  Pages inside a pager hold their content to the page's width (`pageWide()`).
- A row can come out wider than it's offered. The "Also on" row did with
  "Cancelled" at full width (by `.fixedSize()` or a higher `layoutPriority`)
  next to a long name and a room; with the label cut to "C…", or gone, it
  didn't. Exactly which piece stuck out wasn't measured; the likely one is
  the room, squeezed to "0…". `pageWide()` keeps the scrolling safe either
  way.
- `.layoutPriority` only counts as the outermost modifier; under another
  one it's lost.
- Scroll ids must be unique across nested scroll views. Week cards use
  `WeekAgenda.cardID(date)`, because a bare date clashed with the pager's
  page id and the week jumped.

### 2. iOS 26 vs iOS 27

- iOS 27 puts search back into the tab bar and dropped the shrinking tab bar.
- `.searchable` must sit on the Search `Tab`, not on the `TabView`. On the
  `TabView` it leaked into every tab's navigation bar: a phantom field over
  Schedule and Homework, or one hidden under them that a pull-down tugged at.
  That fix (`7840174`) is still waiting to be confirmed on the iPhone 15.

### 3. Elevfeedback text overflowed the screen

- A `UITextView` with scrolling off reports its longest line as its natural
  width, so long answers ran off the sheet.
- The fix is `WrappingTextView` in `FeedbackEditor.swift`: no intrinsic
  width, and `sizeThatFits` uses the proposed width.
- Waiting to be confirmed on the classmate's phone.

### 4. Signing in and staying signed in

- Lectio sometimes shows "Der opstod en ukendt fejl". `LoginWebView` retries
  up to 2 times, forgets Lectio's cookies, and offers a Reload button.
- `autologinkeyV2` is the long-lived key. **Never** let an empty `Set-Cookie`
  wipe it (see `LectioHTTP.swift`).

### 5. Other lessons

- **Lectio forms** are ASP.NET postbacks. Percent-encode them the way a
  browser does, ASCII only (`LectioForms.encoded`).
- **Main-thread parsing** caused jank on smaller phones. Heavy work goes
  through `@concurrent` entry points.
- **Other schools** have classes named by their start year, kursister, and
  students with no class. See `ClassNames` in `DayPlan.swift` and the tests.
  - A subject is the first word of a team without a digit in it (class
    names have one: "1j", "HF1b", "2.a", "IB1"). "ap la" is its own
    subject, AP Latin.
  - A team with your own class anywhere in it ("Ma A 3.b") is yours when
    the word beside it is a subject code itself (`SubjectNames.isSubjectCode`:
    "Ma", "MaA", "Mat"; not "MUN" or "Pre-IB").
  - Colours read `Lesson.subjectCode` (the team's subject part), not `code`.
- **Schedule tooltips** have three labelled blocks after the blank line:
  "Lektier:", "Øvrigt indhold:" and "Note:" (`LectioParser.labelledBlocks`).
- **The hand-in page** gives the assignment's brief and note by row label
  ("Opgavebeskrivelse", "Opgavenote").
- **No error messages or Try again buttons, by Dan's choice.** Several
  screens keep a failed send, save or upload in an `@State` error that isn't
  shown. Showing them was tried and taken out again (Sep 2026): in Dan's use
  these requests don't fail, so he'd rather not have the extra UI. Don't add
  them back unless he asks.
- **Text boxes are read with `textareaValue`**, not `text`: `text` turns line
  breaks into spaces, which flattened notes that were posted back.
- **Lesson content and message bodies are read with `LessonContentReader`**,
  not `text`: `text` drops links, pictures, videos and the breaks at
  headings. It covers what Lectio's guide says a teacher can add (text,
  material, files, links, pictures, video, audio, formulas); relative
  addresses are read from the page's own address.
- **Start loading from a view that's always on screen.** `.task` on a
  `Group` whose only child is an `if` that's still false may never run.
- **Search the project for a new type's name first.** A `private struct` in
  one file still clashes with a type of the same name elsewhere ("Invalid
  redeclaration"); `LessonBlock` is DayAgenda's lesson card.
- **Debugging that worked:**
  - timestamped `#if DEBUG` console logs around the problem;
  - Dan's screen recordings, looked at frame by frame;
  - remove the logging once done.

---

### Find a schedule (29 Sep)

- Lectio lists teams per subject: `FindSkema.aspx?type=hold` lists the
  subjects (`fag=<id>`), and `FindSkema.aspx?type=hold&fag=<id>` that
  subject's teams, each `SkemaNy.aspx?type=holdelement&holdelementid=…`
  (checked read-only in Lectio). `TeamDirectory` loads a subject when it's
  opened, and all of them (four at a time) the first time you search; kept
  a week in Caches.
- Someone else's schedule is read with **their** class (`scheduleClass`):
  `DayPlan.build` sets the global `ClassNames.use(className)`, so
  `TargetScheduleScreen` puts yours back on disappear. Their weeks use
  `schoolDayModules(remembering: false)` so their late modules don't
  become the end of *your* day (`rememberedDayEnd`).
- The day pages keep `.pageWide()` (the scroll-jerk fix). The pages run
  under both bars (`ignoresSafeArea` top and bottom) and clear them with
  measured insets (`TargetBars`: the navigation bar's bottom and the tab
  bar's top, as ScheduleTab's `barClearance`); their back button and title
  used to cover the heading, and the tab bar the last rows.
- A pushed screen's search field (hidden until pulled down) showed through
  for a moment while the screen slid in (iOS starts it open, then folds
  it), and Messages' could stick half-way. So there are no search bars on
  screens any more: the tab bar's search button searches the tab you're on.
- `ScheduleOwner.team`/`.room` hide empty modules ("Free" said nothing for
  a team or a room) in the day (`DayContent`) and the week (`WeekDayCard`).

## Open items

- [x] Day view scroll jerk (`SCROLL_BUG.md`): fixed (`55fb332`, `ae1c45b`),
      confirmed by Dan; the scroll lab is removed.
- [ ] Confirm on the classmate's iPhone 15 (iOS 27): elevfeedback wrapping,
      the search field only on Search, pull-to-refresh in week view.
- [ ] Contact address for `docs/privacy.html` and `docs/terms.html` (Dan
      decides), then host `docs/` on GitHub Pages.
- [ ] New features after friends' feedback.
