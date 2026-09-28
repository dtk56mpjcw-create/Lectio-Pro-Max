import SwiftUI

/// Look up anyone else's timetable — a teacher, a class, a room.
struct FindScheduleSheet: View {
    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var kind: ScheduleTarget.Kind = .student
    @State private var chosen: ScheduleTarget?
    /// The list came back empty: Lectio didn't answer. Without this the
    /// spinner went on for good.
    @State private var loadFailed = false

    private var pool: [ScheduleTarget] {
        session.scheduleTargets
            .filter { $0.kind == kind }
            .sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
    }

    private var filtered: [ScheduleTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()

            VStack(alignment: .leading, spacing: 13) {
                Text("Find a schedule")
                    .scaledFont(size: 26, weight: .bold)
                    .sheetTitleSpacing()

                Picker("Kind", selection: $kind) {
                    ForEach(ScheduleTarget.Kind.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                TextField(session.scheduleTargets.isEmpty && !loadFailed ? "Loading…" : "Search", text: $query)
                    .scaledFont(size: 16)
                    .autocorrectionDisabled()
                    .padding(13)
                    .contentCard(radius: Metrics.inner)

                list
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 24)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .task { await loadTargets() }
        // Pushed from More, so a schedule pushes too — back goes back.
        .navigationDestination(item: $chosen) { target in
            TargetScheduleSheet(target: target).asPushedScreen()
        }
    }

    private var list: some View {
        Group {
            if session.scheduleTargets.isEmpty && loadFailed {
                RetryNotice(text: "Couldn't load the list from Lectio") { Task { await loadTargets() } }
                Spacer()
            } else if session.scheduleTargets.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 50)
                Spacer()
            } else if filtered.isEmpty {
                EmptyNotice(icon: "magnifyingglass", text: "Nothing matches")
                Spacer()
            } else {
                IndexedTargetList(
                    targets: filtered,
                    // Rooms are numbered and there are only a handful of your
                    // own subjects, so both are already in a sensible order and
                    // a letter strip would only get in the way.
                    showsIndex: kind != .room && kind != .subject
                        && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) { chosen = $0 }
            }
        }
    }

    private func loadTargets() async {
        loadFailed = false
        await session.loadScheduleTargets()
        loadFailed = session.scheduleTargets.isEmpty
    }
}

/// A long list of people, grouped by first letter with a scrub strip down the
/// side. Used both for the search results and for a class's students.
struct IndexedTargetList: View {
    let targets: [ScheduleTarget]
    var showsIndex: Bool = true
    var onSelect: (ScheduleTarget) -> Void

    /// Grouped in whatever order the locale sorted them — so Æ, Ø and Å land
    /// after Z on a Danish phone without special-casing.
    private var sections: [(letter: String, items: [ScheduleTarget])] {
        let sorted = targets.sorted {
            $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
        }
        var order: [String] = []
        var buckets: [String: [ScheduleTarget]] = [:]
        for target in sorted {
            let letter = target.indexLetter
            if buckets[letter] == nil {
                order.append(letter)
                buckets[letter] = []
            }
            buckets[letter]?.append(target)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var indexVisible: Bool { showsIndex && sections.count > 2 }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sections, id: \.letter) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.letter)
                                    .scaledFont(size: 12.5, weight: .heavy)
                                    .tracking(0.7)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(section.items) { row($0) }
                                }
                                .contentCard(radius: Metrics.inner)
                            }
                            .id(section.letter)
                        }
                    }
                    .padding(.trailing, indexVisible ? 30 : 0)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                if indexVisible {
                    AlphabetIndex(letters: sections.map { $0.letter }) { letter in
                        // No animation: while a thumb is sliding down the strip,
                        // animating every jump lands behind the finger. Instant
                        // is what makes it feel attached to the touch.
                        proxy.scrollTo(letter, anchor: .top)
                    }
                }
            }
        }
    }

    private func row(_ target: ScheduleTarget) -> some View {
        Button { onSelect(target) } label: {
            HStack(spacing: 10) {
                // A face for people, an icon for everything else — a room has
                // no photo and a class is not a person.
                if target.contextCardID != nil {
                    PersonAvatar(target: target)
                } else {
                    Image(systemName: target.kind.icon)
                        .scaledFont(size: 13.5, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.sortName)
                        .scaledFont(size: 15.5)
                        .multilineTextAlignment(.leading)
                    if let klasse = target.studentClass {
                        Text(klasse)
                            .scaledFont(size: 12.5, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The letter strip down the right-hand edge, the way Apple's own long lists
/// work: tap a letter, or slide a thumb down it to scrub.
struct AlphabetIndex: View {
    let letters: [String]
    var onSelect: (String) -> Void

    @State private var active: String?
    @State private var activeY: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .scaledFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(active == letter ? Palette.accent : Color(.secondaryLabel))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // A wider target than the letters themselves, so the strip is
            // catchable without aiming.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let step = geometry.size.height / CGFloat(max(letters.count, 1))
                        let index = min(max(Int(value.location.y / step), 0), letters.count - 1)
                        activeY = (CGFloat(index) + 0.5) * step
                        let letter = letters[index]
                        if letter != active {
                            active = letter
                            onSelect(letter)
                        }
                    }
                    .onEnded { _ in active = nil }
            )
            // An OVERLAY, deliberately: putting the bubble in the layout made
            // the strip as wide as the bubble and pushed the letters off screen.
            .overlay(alignment: .top) {
                if let active = active {
                    Text(active)
                        .scaledFont(size: 25, weight: .bold)
                        .foregroundStyle(.primary)
                        .frame(width: 58, height: 58)
                        .contentCard(radius: 29)
                        .offset(x: -48, y: activeY - 29)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 26)
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: active)
    }
}

struct TargetScheduleSheet: View {
    let target: ScheduleTarget

    @Environment(LectioSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var week: ScheduleWeek?
    @State private var weekOffset = 0
    @State private var showingStudents = false
    @State private var openStudent: ScheduleTarget?
    @State private var loading = false
    @State private var errorMessage: String?

    private var weekCode: String {
        let day = LectioDates.calendar.date(byAdding: .day, value: weekOffset * 7, to: Date()) ?? Date()
        return LectioDates.weekCode(for: day)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(target.sortName)
                        .scaledFont(size: 24, weight: .bold)
                        .sheetTitleSpacing()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(showingStudents
                         ? "\(classmates.count) students"
                         : (week?.label ?? LectioDates.weekLabel(code: weekCode)))
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                }

                if target.kind == .klasse && !classmates.isEmpty {
                    Picker("View", selection: $showingStudents) {
                        Text("Schedule").tag(false)
                        Text("Students").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if showingStudents {
                    IndexedTargetList(targets: classmates) { openStudent = $0 }
                } else {
                    weekStepper
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if loading {
                                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 50)
                            } else if errorMessage != nil {
                                // Not "Nothing scheduled": that's what a week
                                // that didn't load used to say.
                                RetryNotice(text: "Couldn't load this week") { Task { await load() } }
                            } else if let week = week, !week.days.isEmpty {
                                ForEach(week.days) { day in
                                    dayBlock(day)
                                }
                            } else {
                                EmptyNotice(icon: "calendar", text: "Nothing scheduled this week")
                            }
                        }
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 24)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .task(id: weekCode) { await load() }
        .navigationDestination(item: $openStudent) { student in
            TargetScheduleSheet(target: student).asPushedScreen()
        }
    }

    /// Students whose name carries this class — Lectio writes it in brackets.
    private var classmates: [ScheduleTarget] {
        guard target.kind == .klasse else { return [] }
        return session.scheduleTargets
            .filter { $0.studentClass?.caseInsensitiveCompare(target.name) == .orderedSame }
    }

    private var weekStepper: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").scaledFont(size: 14, weight: .bold)
                    .frame(width: 34, height: 34).contentCard(radius: 17)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressableCard())
            .accessibilityLabel("Previous week")
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").scaledFont(size: 14, weight: .bold)
                    .frame(width: 34, height: 34).contentCard(radius: 17)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(PressableCard())
            .accessibilityLabel("Next week")
        }
    }

    private func dayBlock(_ day: ScheduleDay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(day.label.uppercased())
                .scaledFont(size: 12.5, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            ForEach(day.lessons.filter { !$0.isAllDay }) { lesson in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lesson.start)
                            .scaledFont(size: 14.5, weight: .semibold)
                            .monospacedDigit()
                        if !lesson.end.isEmpty {
                            Text(lesson.end)
                                .scaledFont(size: 12.5, weight: .medium)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.displayTitle)
                            .scaledFont(size: 15.5, weight: .medium)
                            .strikethrough(lesson.cancelled)
                            .multilineTextAlignment(.leading)
                        let meta = [lesson.code.uppercased(), lesson.room, lesson.teacher]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                        if !meta.isEmpty {
                            Text(meta)
                                .scaledFont(size: 13)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Metrics.inner + 2)
    }

    private func step(_ delta: Int) {
        weekOffset += delta
    }

    private func load() async {
        loading = true
        errorMessage = nil
        let cookies = await session.requestCookies()
        do {
            week = try await LectioStudyService.loadWeek(
                for: target, weekCode: weekCode, cookies: cookies)
        } catch {
            // Stepped on to another week meanwhile: that load takes over.
            if Task.isCancelled { return }
            // The week before stays out of it: kept, it showed under the
            // new week's arrows as if it were that week.
            week = nil
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
