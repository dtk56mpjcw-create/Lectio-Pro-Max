import Foundation
import Testing
@testable import LectioProMax

/// Find on page (see PageFind): what counts as a match, the order of the
/// matches down the page, and going round them.
@MainActor
struct PageFindTests {

    @Test func matchesIgnoreCaseAndAccents() {
        let text = AttributedString("Læs kapitel 3. Kapitel 4 er til næste gang; café og Cafe.")
        #expect(PageFind.matches(of: "kapitel", in: text).count == 2)
        #expect(PageFind.matches(of: "cafe", in: text).count == 2)
        // ø, æ and å are letters of their own, as in the searches.
        #expect(PageFind.matches(of: "laes", in: text).isEmpty)
        #expect(PageFind.matches(of: "", in: text).isEmpty)
        #expect(PageFind.matches(of: "biologi", in: text).isEmpty)
    }

    @Test func matchesDontOverlap() {
        #expect(PageFind.matches(of: "aa", in: AttributedString("aaaa")).count == 2)
    }

    @Test func hitsGoDownThePageThenAcross() {
        let find = PageFind()
        find.look(for: "x")
        let title = UUID(), note = UUID(), content = UUID()
        // The Content side reports before the Overview: still after it.
        let overview = UUID(), contentSide = UUID()
        find.report([FindReport(id: content, count: 1)], area: 1, from: contentSide)
        find.report([FindReport(id: title, count: 1), FindReport(id: note, count: 2)], area: 0, from: overview)

        #expect(find.total == 4)
        #expect(find.hits.map(\.text) == [title, note, note, content])
        #expect(find.currentHit == PageFind.Hit(area: 0, part: overview, text: title, index: 0))
        #expect(find.countLabel == "1 of 4")
    }

    @Test func nextAndPreviousGoRound() {
        let find = PageFind()
        find.look(for: "x")
        let text = UUID()
        find.report([FindReport(id: text, count: 3)], area: 0, from: UUID())

        find.next()
        #expect(find.currentIndex(in: text) == 1)
        find.next()
        find.next()
        #expect(find.currentIndex(in: text) == 0)
        find.previous()
        #expect(find.currentIndex(in: text) == 2)
        #expect(find.countLabel == "3 of 3")
    }

    @Test func newWordsStartFromTheTop() {
        let find = PageFind()
        find.look(for: "x")
        find.report([FindReport(id: UUID(), count: 3)], area: 0, from: UUID())
        find.next()
        find.look(for: "xy")
        #expect(find.current == 0)
    }

    @Test func startsOnTheSideYoureOn() {
        let find = PageFind()
        find.startArea = 1
        find.look(for: "x")
        let title = UUID(), content = UUID()
        find.report([FindReport(id: title, count: 1)], area: 0, from: UUID())
        find.report([FindReport(id: content, count: 1)], area: 1, from: UUID())
        #expect(find.currentHit?.text == content)
        // Nothing on that side: from the top.
        let other = PageFind()
        other.startArea = 1
        other.look(for: "y")
        other.report([FindReport(id: title, count: 1)], area: 0, from: UUID())
        #expect(other.currentHit?.text == title)
    }

    @Test func aPageThatGoesTakesItsMatches() {
        let find = PageFind()
        find.look(for: "x")
        let part = UUID()
        find.report([FindReport(id: UUID(), count: 2)], area: 0, from: part)
        find.withdraw(part)
        #expect(find.total == 0)
        #expect(find.currentHit == nil)
        #expect(find.countLabel == "No matches")
        // Nothing to go to: nothing happens.
        find.next()
        #expect(find.current == 0)
    }
}
