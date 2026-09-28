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

    @Test func videosAndEmbedsOpenWhereTheyLive() {
        let html = """
        <div class="ls-paper"><div class="lc-display-fragment">
          <p>Watch before class:</p>
          <iframe src="//www.youtube.com/embed/abc123?si=x" title="YouTube video player"></iframe>
          <iframe src="https://player.vimeo.com/video/42"></iframe>
          <iframe src="https://docs.google.com/presentation/d/1/embed"></iframe>
          <video src="/lectio/59/lc/clip.mp4"></video>
        </div></div>
        """
        let entry = LectioParser.parseLessonDetail(html).sections.first?.entries.first
        let embeds = entry?.blocks.compactMap { block -> String? in
            if case .embed(let link, let title) = block { return title + " " + link }
            return nil
        }
        #expect(embeds == [
            "YouTube video https://www.youtube.com/watch?v=abc123",
            "Vimeo video https://vimeo.com/42",
            "Google Slides https://docs.google.com/presentation/d/1/embed",
        ])
        // One kept in Lectio is a file, which Quick Look plays.
        #expect(entry?.files == [LessonFile(name: "Video", link: "https://www.lectio.dk/lectio/59/lc/clip.mp4")])
    }

    @Test func addressesAreReadFromThePage() {
        let html = """
        <div class="ls-paper"><div class="lc-display-fragment">
          <p><img src="../GetImage.aspx?pictureid=7" width="500"></p>
          <p><a href="www.quizlet.com/dk/1">Quizlet</a> and <a href="https://example.com/lc/page">a page</a></p>
          <p><a href="../lc/file.aspx?id=3">notes.pdf</a></p>
        </div></div>
        """
        let entry = LectioParser.parseLessonDetail(
            html, pageURL: "https://www.lectio.dk/lectio/59/aktivitet/aktivitetforside2.aspx?absid=1"
        ).sections.first?.entries.first
        #expect(entry?.blocks.first == .image("https://www.lectio.dk/lectio/59/GetImage.aspx?pictureid=7"))
        let links = entry?.blocks.flatMap { $0.runs.compactMap(\.link) } ?? []
        #expect(links.contains("https://www.quizlet.com/dk/1"))
        // Another site's "/lc/" is a link, not a Lectio file.
        #expect(links.contains("https://example.com/lc/page"))
        #expect(entry?.files.map(\.link) == ["https://www.lectio.dk/lectio/59/lc/file.aspx?id=3"])
    }

    @Test func linkedPicturesAndStruckWords() {
        let html = """
        <div class="ls-paper"><div class="lc-display-fragment">
          <p><a href="https://www.youtube.com/watch?v=abc"><img src="https://i.ytimg.com/vi/abc/0.jpg" width="480"></a></p>
          <p>Read <s>p. 10–12</s> p. 14–16, <u>all of it</u></p>
          <p><img src="/lectio/59/formula.png" width="140" height="24"></p>
        </div></div>
        """
        let blocks = LectioParser.parseLessonDetail(html).sections.first?.entries.first?.blocks ?? []
        #expect(blocks.count == 3)
        guard blocks.count == 3 else { return }
        #expect(blocks[0] == .image("https://i.ytimg.com/vi/abc/0.jpg", link: "https://www.youtube.com/watch?v=abc"))
        // The line runs through the spaces too.
        #expect(blocks[1].runs == [
            LessonRun(text: "Read "),
            LessonRun(text: "p. 10–12", strike: true),
            LessonRun(text: " p. 14–16, "),
            LessonRun(text: "all of it", underline: true),
        ])
        // Short but wide, like a formula: a picture, not its code.
        #expect(blocks[2] == .image("https://www.lectio.dk/lectio/59/formula.png"))
    }

    @Test func aMessageKeepsItsLinks() {
        let html = """
        <html><body>
        <div class='message-thread-message-sender'>Karen Madsen (KM), 25-09-2026 20:54:13</div>
        <div class='message-thread-message'>
          <div class='message-thread-message-header'>Reading</div>
          <div class='message-thread-message-content'>Read <a href="https://example.com/text">this text</a> before Monday.<br>Karen</div>
        </div>
        </body></html>
        """
        let message = LectioParser.parseThread(html, id: "1", pageURL: "").messages.first
        // The words, as before, for previews and search.
        #expect(message?.body.hasPrefix("Read this text before Monday.") == true)
        // And where the link goes.
        let runs = message?.blocks?.first?.runs ?? []
        #expect(runs.contains(LessonRun(text: "this text", link: "https://example.com/text")))
        #expect(message?.blocks?.first?.plainText == "Read this text before Monday.\nKaren")
    }

    @Test func anAssignmentShowsItsBrief() {
        let html = """
        <html><body><table class="ls-std-table-inputlist">
          <tr><th>Opgavetitel:</th><td>Essay</td></tr>
          <tr><th>Opgavebeskrivelse:</th><td><a href="/lectio/59/ExerciseFileGet.aspx?type=opgavedef&amp;entryid=5">Essay brief.pdf</a></td></tr>
          <tr><th>Opgavenote:</th><td>Read <a href="https://example.com/guide">the guide</a> first.</td></tr>
        </table></body></html>
        """
        let handIn = LectioParser.parseHandIn(html, pageURL: "https://www.lectio.dk/lectio/59/ElevAflevering.aspx?exerciseid=2")
        #expect(handIn.briefFiles == [LessonFile(
            name: "Essay brief.pdf",
            link: "https://www.lectio.dk/lectio/59/ExerciseFileGet.aspx?type=opgavedef&entryid=5")])
        #expect(handIn.note.first?.plainText == "Read the guide first.")
        #expect(handIn.note.first?.runs.contains(LessonRun(text: "the guide", link: "https://example.com/guide")) == true)
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
