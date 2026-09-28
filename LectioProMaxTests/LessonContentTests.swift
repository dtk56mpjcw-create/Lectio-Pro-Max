import Foundation
import Testing
@testable import LectioProMax

/// A lesson's content as the teacher laid it out in Lectio's editor. Built
/// like the Spanish lesson of 30 Sep 2026 (1j, Nørre Gymnasium), whose
/// Quizlet links came out as plain words, whose picture of the workbook
/// page vanished, and whose paragraphs ran into each other.
///
/// Run with ⌘U.
struct LessonContentTests {

    private static let spanishLesson = """
    <div id="homeworkContentContainer">
      <div class="ls-paper-section-heading">Lektier</div>
      <div class="lc-display-fragment">
        <p>You need to practise the dialogue on page 26 of the workbook.
        You can use these Quizlets to practise:</p>
        <p>If you haven&#8217;t already registered as users on Quizlet, click on the two links:</p>
        <h2><a href="https://quizlet.com/dk/111/dialogue-flash-cards/">dialogue flashcards</a></h2>
        <h2><a href="https://quizlet.com/dk/222/interrogatives/">interrogatives<br>in spanish</a></h2>
        <h3><strong>Por cierto:</strong></h3>
        <h4>If you don&#8217;t understand the words, it&#8217;s your own responsibility.&nbsp;😊</h4>
        <h4>If you don&#8217;t have the workbook you can view the dialogue here:</h4>
        <p><img src="/lectio/59/GetImage.aspx?pictureid=12345" width="600"></p>
        <p><a data-lc-display-linktype="file" href="/lectio/59/lc/file.aspx?id=9">
          <span class="ls-fonticon">attach_file</span>dialogue.pdf</a></p>
      </div>
    </div>
    """

    private var entry: LessonEntry? {
        LectioParser.parseLessonDetail(Self.spanishLesson).sections.first?.entries.first
    }

    @Test func paragraphsStayApart() throws {
        let blocks = try #require(entry?.blocks)
        let texts = blocks.map(\.plainText)
        #expect(texts == [
            "You need to practise the dialogue on page 26 of the workbook. You can use these Quizlets to practise:",
            "If you haven’t already registered as users on Quizlet, click on the two links:",
            "dialogue flashcards",
            "interrogatives\nin spanish",
            "Por cierto:",
            "If you don’t understand the words, it’s your own responsibility. 😊",
            "If you don’t have the workbook you can view the dialogue here:",
            "",
        ])
    }

    @Test func linksCanBeTapped() throws {
        let blocks = try #require(entry?.blocks)
        #expect(blocks[2].runs == [LessonRun(text: "dialogue flashcards",
                                             link: "https://quizlet.com/dk/111/dialogue-flash-cards/")])
        // Both lines of the second link go to it; only the line break doesn't.
        let words = blocks[3].runs.filter { $0.text != "\n" }
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.link == "https://quizlet.com/dk/222/interrogatives/" })
    }

    @Test func boldStaysBold() throws {
        let blocks = try #require(entry?.blocks)
        #expect(blocks[4].runs == [LessonRun(text: "Por cierto:", bold: true)])
    }

    @Test func thePictureIsKept() throws {
        let blocks = try #require(entry?.blocks)
        #expect(blocks.last == .image("https://www.lectio.dk/lectio/59/GetImage.aspx?pictureid=12345"))
    }

    @Test func filesAreRowsOfTheirOwn() throws {
        let entry = try #require(entry)
        #expect(entry.files == [LessonFile(name: "dialogue.pdf",
                                           link: "https://www.lectio.dk/lectio/59/lc/file.aspx?id=9")])
        // Not in the text as well, and no icon-font glyph name.
        #expect(!entry.text.contains("dialogue.pdf"))
        #expect(!entry.text.contains("attach_file"))
    }

    @Test func listsKeepTheirMarkers() {
        let html = """
        <div class="ls-paper"><div class="lc-display-fragment">
          <ul><li>Read the text</li><li><b>Answer</b> question 3</li></ul>
          <ol><li>First</li><li>Second</li></ol>
        </div></div>
        """
        let blocks = LectioParser.parseLessonDetail(html).sections.first?.entries.first?.blocks ?? []
        #expect(blocks.map(\.plainText) == ["• Read the text", "• Answer question 3", "1. First", "2. Second"])
        #expect(blocks[1].runs.first == LessonRun(text: "Answer", bold: true))
    }

    @Test func spacesAreTidied() {
        let runs = LessonContentReader.tidy([
            LessonRun(text: "  Practise  "),
            LessonRun(text: " the ", link: "https://a.dk"),
            LessonRun(text: "dialogue ", link: "https://a.dk"),
            LessonRun(text: "\n\n\n  now "),
        ])
        // No space at either end, one between words, the link's own space
        // inside the link, and at most one empty line.
        #expect(runs == [
            LessonRun(text: "Practise "),
            LessonRun(text: "the dialogue", link: "https://a.dk"),
            LessonRun(text: "\n\nnow"),
        ])
    }

    @Test func smallPicturesAreWords() {
        // An emoji the editor drew as a picture reads as its words, in line.
        let html = """
        <div class="ls-paper"><div class="lc-display-fragment">
          <p>Well done <img src="/lectio/img/smiley.gif" alt=":)" width="16" height="16"></p>
          <p><img src="data:image/png;base64,iVBORw0KGgo=" width="400"></p>
          <p><a href="javascript:void(0)">Not a link</a></p>
        </div></div>
        """
        let blocks = LectioParser.parseLessonDetail(html).sections.first?.entries.first?.blocks ?? []
        #expect(blocks.first?.plainText == "Well done :)")
        #expect(blocks.contains(.image("data:image/png;base64,iVBORw0KGgo=")))
        #expect(blocks.last?.runs == [LessonRun(text: "Not a link")])
    }
}
