import SwiftUI
import Observation

// MARK: - Find on page

/// Find on page, as in Safari: on an open page (a lesson, a homework or an
/// assignment, a message, your absence, grades or study plan, a settings
/// page) the search field finds its words on the page itself. Every match
/// is marked in yellow and the current one more strongly; the page scrolls
/// to it, the Search key or the arrows in the bar go to the next, and the
/// bar says which of how many. Dan (29 Sep): if you open a homework with a
/// long text you should be able to search it with this search bar, the
/// same everywhere.
///
/// It happens in the copy of the tab behind the search field (SearchTab),
/// the only place with a PageFind in the environment. The real tabs draw
/// their text as they always have.
///
/// A page takes part with three things:
/// - `.findsOnPage()` on the page: the search is this page's, and the bar
///   gets the count and the arrows;
/// - `.findScroller()` on what its scroll view scrolls, so it can go to a
///   match;
/// - `FindableText` instead of `Text` for what's worth finding.
@MainActor
@Observable
final class PageFind {
    /// What's looked for, trimmed; empty when nothing is.
    private(set) var query = ""
    /// The current match, counted from the top of the page.
    private(set) var current = 0
    /// What each scrolling part of the page found, by its order on the
    /// page (a lesson's Overview, then its Content).
    private var found: [Int: [FindReport]] = [:]

    /// One match: in which part of the page, in which text, and which one
    /// in that text.
    struct Hit: Equatable {
        let area: Int
        let text: UUID
        let index: Int
    }

    /// Every match on the page, in reading order.
    var hits: [Hit] {
        found.keys.sorted().flatMap { area in
            (found[area] ?? []).flatMap { report in
                (0..<report.count).map { Hit(area: area, text: report.id, index: $0) }
            }
        }
    }

    var total: Int {
        found.values.reduce(0) { sum, reports in sum + reports.reduce(0) { $0 + $1.count } }
    }

    var currentHit: Hit? {
        let all = hits
        guard !all.isEmpty else { return nil }
        return all[min(current, all.count - 1)]
    }

    /// "2 of 5", for the bar.
    var countLabel: String {
        let total = total
        return total == 0 ? "No matches" : "\(min(current, total - 1) + 1) of \(total)"
    }

    /// Which match in `text` is the current one, if it's in there.
    func currentIndex(in text: UUID) -> Int? {
        guard let hit = currentHit, hit.text == text else { return nil }
        return hit.index
    }

    /// New words to find: from the first match again.
    func look(for query: String) {
        guard query != self.query else { return }
        self.query = query
        current = 0
    }

    func next() {
        let total = total
        guard total > 0 else { return }
        current = (min(current, total - 1) + 1) % total
    }

    func previous() {
        let total = total
        guard total > 0 else { return }
        current = (min(current, total - 1) + total - 1) % total
    }

    /// What a scrolling part of the page has found (see FindScroller).
    func report(_ reports: [FindReport], area: Int) {
        let now = reports.isEmpty ? nil : reports
        if found[area] != now { found[area] = now }
    }

    /// Where `query` is in `text`, whatever the case or accents, as the
    /// searches match ("e" finds "é").
    static func matches(of query: String, in text: AttributedString) -> [Range<AttributedString.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }
}

/// How many matches one text has, and which text it is.
struct FindReport: Equatable, Sendable {
    let id: UUID
    let count: Int
}

/// The texts with a match, in the order they are on the page.
struct FindReportsKey: PreferenceKey {
    static let defaultValue: [FindReport] = []

    static func reduce(value: inout [FindReport], nextValue: () -> [FindReport]) {
        value.append(contentsOf: nextValue())
    }
}

/// Text that find on page can find in (see PageFind): every match marked
/// in pale yellow, the current one in full yellow with dark text. Used as
/// `Text` is, and styled the same way from outside; outside find it's
/// plain `Text`.
struct FindableText: View {
    private let text: AttributedString
    @Environment(PageFind.self) private var find: PageFind?
    /// Which text this is, for going to it.
    @State private var id = UUID()

    init(_ text: String) {
        self.text = AttributedString(text)
    }

    init(_ text: AttributedString) {
        self.text = text
    }

    var body: some View {
        let ranges = find.map { PageFind.matches(of: $0.query, in: text) } ?? []
        if let find, !ranges.isEmpty {
            Text(Self.marked(text, ranges, current: find.currentIndex(in: id)))
                .id(id)
                .preference(key: FindReportsKey.self, value: [FindReport(id: id, count: ranges.count)])
        } else {
            Text(text)
        }
    }

    private static func marked(_ text: AttributedString, _ ranges: [Range<AttributedString.Index>],
                               current: Int?) -> AttributedString {
        var out = text
        for (index, range) in ranges.enumerated() {
            // Typed, so they're SwiftUI's colours and not UIKit's.
            if index == current {
                out[range].backgroundColor = Color.yellow
                out[range].foregroundColor = Color.black
            } else {
                out[range].backgroundColor = Color.yellow.opacity(0.35)
            }
        }
        return out
    }
}

/// What a page's scroll view scrolls: it collects the page's matches and
/// scrolls to the current one, into the top part of the screen, clear of
/// the keyboard.
private struct FindScroller: ViewModifier {
    let area: Int
    @Environment(PageFind.self) private var find: PageFind?
    /// What was found last, to tell the page again when it's back on
    /// screen (going away takes its matches off the count).
    @State private var latest: [FindReport] = []

    func body(content: Content) -> some View {
        if let find {
            ScrollViewReader { proxy in
                content
                    .onPreferenceChange(FindReportsKey.self) { reports in
                        Task { @MainActor in
                            latest = reports
                            find.report(reports, area: area)
                        }
                    }
                    .onChange(of: find.currentHit) { _, hit in
                        guard let hit, hit.area == area else { return }
                        withAnimation(.snappy) {
                            proxy.scrollTo(hit.text, anchor: UnitPoint(x: 0.5, y: 0.3))
                        }
                    }
                    .onAppear { find.report(latest, area: area) }
                    .onDisappear { find.report([], area: area) }
            }
        } else {
            content
        }
    }
}

/// The count and the arrows in the page's bar while finding. That the page
/// is searched by finding on it is said where it's pushed
/// (`.searchPage(.page)`), with how to draw it behind the search field.
private struct FindsOnPage: ViewModifier {
    @Environment(PageFind.self) private var find: PageFind?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if let find, !find.query.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Text(find.countLabel)
                            .scaledFont(size: 15, weight: .semibold)
                            .monospacedDigit()
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            find.previous()
                        } label: {
                            Label("Previous match", systemImage: "chevron.up")
                        }
                        .disabled(find.total < 2)
                        Button {
                            find.next()
                        } label: {
                            Label("Next match", systemImage: "chevron.down")
                        }
                        .disabled(find.total < 2)
                    }
                }
            }
    }
}

extension View {
    /// The count and arrows for finding on this page (see PageFind).
    func findsOnPage() -> some View {
        modifier(FindsOnPage())
    }

    /// Goes on what a page's scroll view scrolls, so find can go to a
    /// match. `area` orders a page's scrolling parts, top to bottom or
    /// left to right.
    func findScroller(area: Int = 0) -> some View {
        modifier(FindScroller(area: area))
    }
}
