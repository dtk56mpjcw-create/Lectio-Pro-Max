import Foundation

/// Reads one piece of a lesson's content (a `lc-display-fragment` on
/// `aktivitetforside2.aspx`) the way Lectio's editor laid it out.
///
/// It used to be read with `text`, which keeps only the words: a link to
/// Quizlet became two plain words, a picture of the workbook page vanished,
/// and a heading ran into the paragraph after it ("Por cierto: If you
/// don't…"). This keeps where paragraphs and lines end, links, bold and
/// italic, list items and pictures. File links are collected on their own,
/// as files, as they were before.
struct LessonContentReader {
    private(set) var blocks: [LessonBlock] = []
    private(set) var files: [LessonFile] = []

    private var runs: [LessonRun] = []
    /// The list item being read, if any: "•" or "3.".
    private var marker: String?
    private var bold = 0
    private var italic = 0
    private var link: String?

    static func read(_ fragment: HTMLNode) -> (blocks: [LessonBlock], files: [LessonFile]) {
        var reader = LessonContentReader()
        reader.walk(fragment)
        reader.endBlock()
        return (reader.blocks, reader.files)
    }

    /// The words alone, one paragraph a line.
    static func plainText(_ blocks: [LessonBlock]) -> String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Elements that start a line of their own. Teachers pick "Heading 3" in
    /// the editor for big text, so headings are paragraphs, bold only when
    /// the teacher made them bold.
    private static let blockNames: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "section", "article", "header", "footer", "figure", "figcaption",
        "table", "tbody", "thead", "tfoot", "dl", "dt", "dd", "hr", "center", "address",
    ]

    // MARK: Walking

    private mutating func walk(_ node: HTMLNode) {
        for item in node.content {
            switch item {
            case .text(let text): add(text)
            case .element(let element): visit(element)
            }
        }
    }

    private mutating func visit(_ element: HTMLNode) {
        let name = element.name
        // As in `text`: scripts, Lectio's icon font (its glyph names are real
        // text), and the mobile copy of every row.
        if name == "script" || name == "style" { return }
        if element.hasClass("ls-fonticon") || element.hasClass("OnlyMobile") { return }

        switch name {
        case "br":
            runs.append(LessonRun(text: "\n"))
        case "img":
            image(element)
        case "a":
            anchor(element)
        case "strong", "b":
            bold += 1
            walk(element)
            bold -= 1
        case "em", "i":
            italic += 1
            walk(element)
            italic -= 1
        case "ul", "ol":
            endBlock()
            var number = 0
            for item in element.content {
                guard case .element(let child) = item else { continue }
                if child.name == "li" {
                    number += 1
                    listItem(child, marker: name == "ol" ? "\(number)." : "•")
                } else {
                    visit(child)
                }
            }
            endBlock()
        case "li":
            listItem(element, marker: "•")
        case "tr":
            // A row a line, its cells side by side.
            endBlock()
            var first = true
            for item in element.content {
                guard case .element(let cell) = item, cell.name == "td" || cell.name == "th" else { continue }
                let before = runs.count
                if !first { runs.append(LessonRun(text: " · ")) }
                let withSeparator = runs.count
                walk(cell)
                let words = runs[withSeparator...].contains { run in
                    run.text.contains { !$0.isWhitespace }
                }
                if !words {
                    // An empty cell: no separator for it.
                    runs.removeSubrange(before..<runs.count)
                } else {
                    first = false
                }
            }
            endBlock()
        default:
            if Self.blockNames.contains(name) {
                endBlock()
                walk(element)
                endBlock()
            } else {
                walk(element)
            }
        }
    }

    private mutating func listItem(_ element: HTMLNode, marker: String) {
        endBlock()
        self.marker = marker
        walk(element)
        endBlock()
    }

    /// A file of the lesson's (a row of its own), or a link in the text.
    private mutating func anchor(_ element: HTMLNode) {
        let href = element.attr("href") ?? ""
        if (element.attr("data-lc-display-linktype") ?? "") == "file" || href.contains("/lc/") {
            if let fileLink = LectioParser.absoluteURL(href) {
                let name = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
                files.append(LessonFile(name: name.isEmpty ? "File" : name, link: fileLink))
            }
            return
        }
        let outer = link
        link = Self.webLink(href) ?? outer
        walk(element)
        link = outer
    }

    /// Somewhere a tap can go: a web page or an email address. Not a
    /// script, and not a spot on the same page.
    static func webLink(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mailto:") { return trimmed }
        if trimmed.isEmpty || lower.hasPrefix("javascript:") || trimmed.hasPrefix("#") { return nil }
        return LectioParser.absoluteURL(trimmed)
    }

    private mutating func image(_ element: HTMLNode) {
        let src = (element.attr("src") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return }
        // An emoji or icon the editor drew as a picture: its words, in line.
        let width = Int(element.attr("width") ?? "") ?? .max
        let height = Int(element.attr("height") ?? "") ?? .max
        if width <= 32 || height <= 32 || src.lowercased().contains("/lectio/img/") {
            let alt = (element.attr("alt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !alt.isEmpty { add(alt) }
            return
        }
        // Pasted pictures come inline, as data.
        let source = src.lowercased().hasPrefix("data:") ? src : LectioParser.absoluteURL(src)
        guard let source else { return }
        endBlock()
        blocks.append(.image(source))
    }

    // MARK: Text

    /// A newline in the source is layout, not a line break (as in `text`):
    /// Word-pasted HTML has one between every nested span.
    private mutating func add(_ text: String) {
        let flat = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard !flat.isEmpty else { return }
        runs.append(LessonRun(text: flat, link: link, bold: bold > 0, italic: italic > 0))
    }

    private mutating func endBlock() {
        let tidied = Self.tidy(runs)
        if !tidied.isEmpty {
            if let marker {
                blocks.append(.listItem(marker: marker, runs: tidied))
            } else {
                blocks.append(.paragraph(tidied))
            }
        }
        runs = []
        marker = nil
    }

    /// Spaces collapsed to one, none at the start or end of a line, at most
    /// one empty line in a row, and runs of the same style joined up. A
    /// space between two words of one link stays part of the link.
    static func tidy(_ runs: [LessonRun]) -> [LessonRun] {
        var out: [LessonRun] = []
        var pendingBreaks = 0
        var pendingSpace: LessonRun?

        func write(_ character: Character, as style: LessonRun) {
            if let last = out.last, last.link == style.link,
               last.bold == style.bold, last.italic == style.italic {
                out[out.count - 1].text.append(character)
            } else {
                out.append(LessonRun(text: String(character), link: style.link,
                                     bold: style.bold, italic: style.italic))
            }
        }

        let plain = LessonRun(text: "")
        for run in runs {
            for character in run.text {
                if character == "\n" {
                    pendingBreaks += 1
                    pendingSpace = nil
                } else if character == " " || character == "\t" || character == "\u{00A0}" {
                    if pendingBreaks == 0 { pendingSpace = run }
                } else {
                    if !out.isEmpty {
                        if pendingBreaks > 0 {
                            for _ in 0..<min(pendingBreaks, 2) { write("\n", as: plain) }
                        } else if let space = pendingSpace {
                            // Inside a link only with the link on both sides.
                            let inside = run.link != nil && space.link == run.link
                                && out.last?.link == run.link
                            write(" ", as: inside ? run : plain)
                        }
                    }
                    pendingBreaks = 0
                    pendingSpace = nil
                    write(character, as: run)
                }
            }
        }
        return out
    }
}
