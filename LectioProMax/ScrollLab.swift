#if DEBUG
import SwiftUI
import UIKit

/// Debug builds only: a stand-in for the Schedule tab, for finding the
/// long-day scroll jerk (SCROLL_BUG.md, "Experiment 0: the scroll lab").
///
/// Fake days and no Lectio data, in a pager built the way ScheduleTab builds
/// its own: a sideways scroll view of pages, each page a scroll view of its
/// own. Every piece the Schedule adds on top of that is a switch in the
/// menu. "Like the Schedule" switches them all on, "Bare minimum" leaves
/// only the paging. If the bare minimum jerks, the jerk is iOS's; if it
/// doesn't, switching the pieces back on one at a time finds the one that
/// brings it.
///
/// Switched on under Me → Settings → Testing; it then takes the Schedule
/// tab's place, inside the real tab bar. Nothing here touches Lectio.
struct ScrollLab: View {
    static let enabledKey = "lab.enabled"
    static let shrinkKey = "lab.shrinkTabBar"

    @AppStorage(ScrollLab.enabledKey) private var enabled = false
    @AppStorage(ScrollLab.shrinkKey) private var shrinkTabBar = true
    @AppStorage("lab.paging") private var paging = LabPaging.swiftUI.rawValue
    @AppStorage("lab.fullHeight") private var fullHeight = true
    @AppStorage("lab.refreshable") private var refreshable = true
    @AppStorage("lab.trackPage") private var trackPage = true
    @AppStorage("lab.measuredBottom") private var measuredBottom = true
    @AppStorage("lab.underTabBar") private var underTabBar = true
    @AppStorage("lab.secondPager") private var secondPager = true
    @AppStorage("lab.rows") private var rows = 8

    @State private var page: Int? = LabDays.start
    @State private var safeBottom: CGFloat = 0
    @State private var barLine: CGFloat = 0

    /// What's switched on, in words: shown on every page, so a screen
    /// recording says which setup it is.
    private var summary: String {
        var parts = [LabPaging(rawValue: paging)?.label ?? "?"]
        if fullHeight { parts.append("full height") }
        if refreshable { parts.append("refresh") }
        if trackPage { parts.append("tracks page") }
        if measuredBottom { parts.append("measured bottom") }
        if underTabBar { parts.append("under tab bar") }
        if secondPager { parts.append("2nd pager") }
        parts.append(shrinkTabBar ? "bar shrinks" : "bar fixed")
        parts.append("\(rows) rows")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            // Built as ScheduleTab's `pagers` is: the day pager and, behind
            // the scenes, a second one for the week, both kept alive.
            ZStack {
                ScrollViewReader { proxy in
                    dayPager(proxy)
                }
                if secondPager {
                    hiddenPager
                }
            }
            .ignoresSafeArea(.container, edges: underTabBar ? Edge.Set.bottom : Edge.Set())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(LabMeasureBar(on: measuredBottom, safeBottom: $safeBottom, barLine: $barLine))
            // Any change starts the pager afresh.
            .id(summary)
            .background { AppBackground() }
            .navigationTitle("Scroll lab")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
    }

    private var pageAxes: Axis.Set { fullHeight ? [.horizontal, .vertical] : [.horizontal] }

    private func dayPager(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(LabDays.all, id: \.self) { day in
                    LabPage(day: day, rows: rows, summary: summary,
                            refreshable: refreshable, measuredBottom: measuredBottom,
                            barLine: barLine, floor: max(safeBottom, 84))
                        .containerRelativeFrame(pageAxes)
                }
            }
            .scrollTargetLayout()
            // Watches the pager (and pages it, for UIKit paging).
            .background(alignment: .topLeading) {
                LabPagerProbe(forcePaging: paging == LabPaging.uiKit.rawValue)
                    .frame(width: 1, height: 1)
            }
        }
        .scrollIndicators(.hidden)
        .modifier(LabSwiftUIPaging(on: paging == LabPaging.swiftUI.rawValue))
        .modifier(LabTrackPage(on: trackPage, page: $page, proxy: proxy))
    }

    /// The week pager's place: there, invisible and not touchable, as it is
    /// in day view.
    private var hiddenPager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { week in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(0..<20, id: \.self) { row in
                                Color.clear.frame(height: 100).id("week\(week)row\(row)")
                            }
                        }
                    }
                    .containerRelativeFrame(pageAxes)
                    .id("week\(week)")
                }
            }
            .scrollTargetLayout()
        }
        .modifier(LabSwiftUIPaging(on: paging == LabPaging.swiftUI.rawValue))
        .scrollIndicators(.hidden)
        .opacity(0)
        .allowsHitTesting(false)
        .scrollDisabled(true)
        .accessibilityHidden(true)
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Section("Start from") {
                Button("Like the Schedule") { likeTheSchedule() }
                Button("Bare minimum") { bareMinimum() }
            }
            Picker("Paging", selection: $paging) {
                ForEach(LabPaging.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            Section("Pieces") {
                Toggle("Pages as tall as the pager", isOn: $fullHeight)
                Toggle("Pull to refresh", isOn: $refreshable)
                Toggle("Tracks the page", isOn: $trackPage)
                Toggle("Bottom room measured", isOn: $measuredBottom)
                Toggle("Pager under the tab bar", isOn: $underTabBar)
                Toggle("Second pager behind", isOn: $secondPager)
                Toggle("Tab bar shrinks", isOn: $shrinkTabBar)
            }
            Picker("Day length", selection: $rows) {
                Text("Short: fits the screen").tag(4)
                Text("Like 30 Sep: a bit longer").tag(8)
                Text("Long: two screens").tag(16)
            }
            .pickerStyle(.inline)
            Section {
                Button("Close the lab", role: .destructive) { enabled = false }
            }
        } label: {
            Label("Lab settings", systemImage: "slider.horizontal.3")
        }
    }

    /// Every piece on, as `main`'s ScheduleTab has them.
    private func likeTheSchedule() {
        paging = LabPaging.swiftUI.rawValue
        fullHeight = true
        refreshable = true
        trackPage = true
        measuredBottom = true
        underTabBar = true
        secondPager = true
        shrinkTabBar = true
        rows = 8
    }

    /// Only a paging pager of scrolling pages, in the real tab bar.
    private func bareMinimum() {
        paging = LabPaging.swiftUI.rawValue
        fullHeight = true
        refreshable = false
        trackPage = false
        measuredBottom = false
        underTabBar = false
        secondPager = false
        shrinkTabBar = true
        rows = 8
    }
}

// MARK: - Days

private enum LabDays {
    /// Pages -30…+29, starting in the middle so both ways can be swiped.
    static let all = Array(0..<60)
    static let start = 30
}

enum LabPaging: Int, CaseIterable {
    case none, swiftUI, uiKit

    var label: String {
        switch self {
        case .none: return "No paging"
        case .swiftUI: return "SwiftUI paging"
        case .uiKit: return "UIKit paging"
        }
    }
}

/// One fake day: a big title, then rows the size of the Schedule's
/// modules.
private struct LabPage: View {
    let day: Int
    let rows: Int
    let summary: String
    let refreshable: Bool
    let measuredBottom: Bool
    let barLine: CGFloat
    let floor: CGFloat
    /// Where this page's scroll view ends, from the top of the screen.
    @State private var pageBottom: CGFloat = 0

    /// Room at the bottom to scroll clear of the tab bar: measured as
    /// ScheduleTab's `barClearance` does, or a fixed amount.
    private var bottomRoom: CGFloat {
        guard measuredBottom else { return 130 }
        guard pageBottom > 0, barLine > 0 else { return floor + 24 }
        return min(max(pageBottom - barLine, floor), 400) + 24
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Day \(day - LabDays.start)")
                        .scaledFont(size: 34, weight: .bold)
                    Text(summary)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 35.5)
                .padding(.bottom, 4)

                // Ids of their own: a bare number would clash with the
                // pager's page ids, and scrolling to a page would scroll a
                // day instead.
                ForEach((1...rows).map { "row\($0)" }, id: \.self) { row in
                    Text("Module \(String(row.dropFirst(3)))")
                        .scaledFont(size: 17, weight: .semibold)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        .contentCard(radius: Metrics.inner + 4)
                }
                Text("End of day \(day - LabDays.start)")
                    .scaledFont(size: 13.5)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, bottomRoom)
        }
        .scrollIndicators(.hidden)
        .modifier(LabPageBottom(on: measuredBottom, pageBottom: $pageBottom))
        .modifier(LabRefresh(on: refreshable))
        // In Xcode's console (filter "Lab:"). A jerk at the end shows as
        // "interacting → idle" at the end with no "decelerating" between.
        .onScrollPhaseChange { old, new, context in
            let g = context.geometry
            let y = Int(g.contentOffset.y + g.contentInsets.top)
            let end = Int(g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height)
            print("Lab: \(LabLog.stamp) day \(day - LabDays.start) \(old) → \(new) at \(y) of \(end)")
        }
    }
}

// MARK: - The pieces, each one switchable

private struct LabSwiftUIPaging: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.scrollTargetBehavior(.paging)
        } else {
            content
        }
    }
}

/// As ScheduleTab's pagers: the page kept in state, and put squarely back
/// on it whenever the pager comes to rest.
private struct LabTrackPage: ViewModifier {
    let on: Bool
    @Binding var page: Int?
    let proxy: ScrollViewProxy

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content
                .scrollPosition(id: $page, anchor: .center)
                .onAppear { align(animated: false) }
                .onScrollPhaseChange { _, phase, _ in
                    if phase == .idle { align(animated: true) }
                }
        } else {
            content
        }
    }

    private func align(animated: Bool) {
        let target = page ?? LabDays.start
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
            } else {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

/// As ScheduleTab's `pagers`: the bottom safe area and the top of the tab
/// bar, measured live.
private struct LabMeasureBar: ViewModifier {
    let on: Bool
    @Binding var safeBottom: CGFloat
    @Binding var barLine: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.safeAreaInsets.bottom
                } action: { inset in
                    safeBottom = inset
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .global).maxY.rounded()
                } action: { line in
                    barLine = line
                }
        } else {
            content
        }
    }
}

/// As ScheduleTab's DayPage: where the page ends, measured live.
private struct LabPageBottom: ViewModifier {
    let on: Bool
    @Binding var pageBottom: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .global).maxY.rounded()
                } action: { bottom in
                    pageBottom = bottom
                }
        } else {
            content
        }
    }
}

private struct LabRefresh: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.refreshable { try? await Task.sleep(for: .seconds(1)) }
        } else {
            content
        }
    }
}

// MARK: - Watching the pager from UIKit

/// A 1×1 view in the pager's content that finds the pager's UIScrollView.
/// It prints its size once, and a line whenever the pager moves up or down,
/// which a sideways pager never should. For "UIKit paging" it also switches
/// UIKit's paging on and keeps it on (SwiftUI turns it off on updates).
private struct LabPagerProbe: UIViewRepresentable {
    let forcePaging: Bool

    func makeUIView(context: Context) -> Probe { Probe(forcePaging: forcePaging) }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.attach()
    }

    final class Probe: UIView {
        let forcePaging: Bool
        private weak var pager: UIScrollView?
        private var watches: [NSKeyValueObservation] = []
        private var lastDrift: CGFloat = 0

        init(forcePaging: Bool) {
            self.forcePaging = forcePaging
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            self.forcePaging = false
            super.init(coder: coder)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
            // Sizes are only real once SwiftUI has laid the pager out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.attach()
                self?.report()
            }
        }

        func attach() {
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let scroll = view as? UIScrollView else {
                print("Lab: no scroll view above the probe")
                return
            }
            if scroll !== pager {
                pager = scroll
                var list = [scroll.observe(\.contentOffset) { [weak self] scroll, _ in
                    MainActor.assumeIsolated { self?.offsetChanged(scroll) }
                }]
                if forcePaging {
                    list.append(scroll.observe(\.isPagingEnabled) { scroll, _ in
                        MainActor.assumeIsolated {
                            if !scroll.isPagingEnabled { scroll.isPagingEnabled = true }
                        }
                    })
                }
                watches = list
            }
            if forcePaging && !scroll.isPagingEnabled { scroll.isPagingEnabled = true }
        }

        private func report() {
            guard let scroll = pager else { return }
            let room = scroll.contentSize.height + scroll.adjustedContentInset.top
                + scroll.adjustedContentInset.bottom - scroll.bounds.height
            print("Lab: pager \(Int(scroll.contentSize.width))×\(Int(scroll.contentSize.height)) in \(Int(scroll.bounds.width))×\(Int(scroll.bounds.height)), insets top \(Int(scroll.adjustedContentInset.top)) bottom \(Int(scroll.adjustedContentInset.bottom)), room to move up/down \(Int(room)) pt, UIKit paging \(scroll.isPagingEnabled ? "on" : "off")")
        }

        private func offsetChanged(_ scroll: UIScrollView) {
            let drift = (scroll.contentOffset.y + scroll.adjustedContentInset.top).rounded()
            guard drift != lastDrift else { return }
            lastDrift = drift
            print("Lab: \(LabLog.stamp) pager moved up/down: \(drift) pt")
        }
    }
}

enum LabLog {
    /// "18:34:05.123", for lining console lines up with a screen recording.
    static var stamp: String {
        Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }
}
#endif
