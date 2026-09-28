import Foundation

/// Reads one piece of a lesson's content (a `lc-display-fragment` on
/// `aktivitetforside2.aspx`) the way Lectio's editor laid it out.
///
/// It used to be read with `text`, which keeps only the words: a link to
/// Quizlet became two plain words, a picture of the workbook page vanished,
/// and a heading ran into the paragraph after it ("Por cierto: If you
/// don't…"). This keeps where paragraphs and lines end, links, bold,
/// italic, crossed-out and underlined text, list items, pictures and
/// embedded videos and pages. File links are collected on their own, as
/// files, as they were before.
///
/// What a teacher can add, by Lectio's own guide: text, material, files,
/// links, pictures, video, audio and formulas. Nothing here is particular
/// to a subject or a school.
struct LessonContentReader {
    private(set) var blocks: [LessonContentBlock] = []
    private(set) var files: [LessonFile] = []

    /// The lesson page's own address, which relative addresses in the
    /// content are read from, as a browser reads them.
    private var base: URL?
    private var runs: [LessonRun] = []
    /// The list item being read, if any: "•" or "3.".
    private var marker: String?
    private var bold = 0
    private var italic = 0
    private var strike = 0
    private var underline = 0
    /// Inside `<pre>`: line breaks in the source are real.
    private var preformatted = 0
    private var link: String?

    static func read(_ fragment: HTMLNode, base: URL? = nil) -> (blocks: [LessonContentBlock], files: [LessonFile]) {
        var reader = LessonContentReader()
        reader.base = base
        reader.walk(fragment)
        reader.endBlock()
        return (reader.blocks, reader.files)
    }

    /// The words alone, one paragraph a line.
    static func plainText(_ blocks: [LessonContentBlock]) -> String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Elements that start a line of their own. Teachers pick "Heading 3" in
    /// the editor for big text, so headings are paragraphs, bold only when
    /// the teacher made them bold.
    private static let blockNames: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
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
        case "iframe", "embed":
            media(element.attr("src"), title: element.attr("title"), kind: nil)
        case "object":
            media(element.attr("data"), title: element.attr("title"), kind: nil)
        case "video", "audio":
            let source = element.attr("src") ?? element.all("source").first?.attr("src")
            media(source, title: element.attr("title"), kind: name)
        case "math":
            // A formula written as MathML: its words where it gives them,
            // else its symbols in a row.
            let alt = (element.attr("alttext") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if alt.isEmpty { walk(element) } else { add(alt) }
        case "strong", "b":
            bold += 1
            walk(element)
            bold -= 1
        case "em", "i":
            italic += 1
            walk(element)
            italic -= 1
        case "s", "strike", "del":
            strike += 1
            walk(element)
            strike -= 1
        case "u", "ins":
            underline += 1
            walk(element)
            underline -= 1
        case "pre":
            endBlock()
            preformatted += 1
            walk(element)
            preformatted -= 1
            endBlock()
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
        if (element.attr("data-lc-display-linktype") ?? "") == "file" || Self.isLectioFile(href) {
            if let fileLink = resolve(href) {
                let name = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
                files.append(LessonFile(name: name.isEmpty ? "File" : name, link: fileLink))
            }
            return
        }
        let outer = link
        link = webLink(href) ?? outer
        walk(element)
        link = outer
    }

    /// Lectio's own file store (`/lectio/<school>/lc/…`, or relative to the
    /// page), not another site's address that happens to have "/lc/" in it.
    static func isLectioFile(_ href: String) -> Bool {
        let lower = href.lowercased()
        // A document in Lectio's archive, as messages attach them.
        if lower.contains("dokumenthent.aspx") { return true }
        guard lower.contains("/lc/") else { return false }
        let onAnotherSite = lower.contains("://") || lower.hasPrefix("//")
        return !onAnotherSite || lower.contains("lectio.dk/")
    }

    /// Somewhere a tap can go: a web page or an email address. Not a
    /// script, and not a spot on the same page.
    private func webLink(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") { return trimmed }
        if trimmed.isEmpty || lower.hasPrefix("javascript:") || trimmed.hasPrefix("#") { return nil }
        return resolve(trimmed)
    }

    /// An address in full. "www.quizlet.com/…" is on the web; "//www.youtube.com/…"
    /// takes https; one relative to the page is read from the page's own
    /// address, as a browser does ("../GetImage.aspx" isn't next to the
    /// school's root).
    private func resolve(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:") { return trimmed }
        if lower.hasPrefix("www.") { return "https://" + trimmed }
        if let base, let url = URL(string: trimmed, relativeTo: base) { return url.absoluteString }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        return LectioParser.absoluteURL(trimmed)
    }

    private mutating func image(_ element: HTMLNode) {
        let src = (element.attr("src") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return }
        // An emoji or icon the editor drew as a picture: its words, in line.
        // Small both ways; a formula can be short but wide, and stays a
        // picture.
        let width = Int(element.attr("width") ?? "")
        let height = Int(element.attr("height") ?? "")
        let tiny = (width != nil || height != nil) && (width ?? 0) <= 32 && (height ?? 0) <= 32
        if tiny || src.lowercased().contains("/lectio/img/") {
            let alt = (element.attr("alt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !alt.isEmpty { add(alt) }
            return
        }
        guard let source = resolve(src) else { return }
        endBlock()
        // Inside a link (a video's thumbnail, say), the picture goes there.
        blocks.append(.image(source, link: link))
    }

    /// A video, a sound, or a page embedded from elsewhere. One kept in
    /// Lectio is a file like any other (Quick Look plays it, with the
    /// sign-in); one from the web is a row that opens where it lives.
    private mutating func media(_ raw: String?, title: String?, kind: String?) {
        guard let address = resolve(raw) else { return }
        let lower = address.lowercased()
        guard !lower.hasPrefix("data:"), !lower.hasPrefix("about:") else { return }
        let given = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: address)?.host?.lowercased().hasSuffix("lectio.dk") == true {
            let fallback = kind == "audio" ? "Sound" : "Video"
            files.append(LessonFile(name: given.isEmpty ? fallback : given, link: address))
            return
        }
        endBlock()
        blocks.append(.embed(link: LessonEmbeds.openable(address),
                             title: LessonEmbeds.name(for: address, given: given, kind: kind)))
    }

    // MARK: Text

    /// A newline in the source is layout, not a line break (as in `text`):
    /// Word-pasted HTML has one between every nested span. Except in `<pre>`.
    private mutating func add(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let flat = preformatted > 0 ? lines : lines.replacingOccurrences(of: "\n", with: " ")
        guard !flat.isEmpty else { return }
        runs.append(LessonRun(text: flat, link: link, bold: bold > 0, italic: italic > 0,
                              strike: strike > 0, underline: underline > 0))
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
            if let last = out.last, last.hasStyle(of: style) {
                out[out.count - 1].text.append(character)
            } else {
                var run = style
                run.text = String(character)
                out.append(run)
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
                            // Styled (in the link, struck through…) only with
                            // that style on both sides: "Read ~~p. 10–12~~".
                            let inside = space.hasStyle(of: run)
                                && out.last?.hasStyle(of: run) == true
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

/// What an embedded video or page is, and where a tap should take you.
enum LessonEmbeds {
    /// The player's own page rather than the bare player, so it opens in
    /// the YouTube or Vimeo app, or in Safari with its controls.
    static func openable(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return address }
        let parts = url.path.split(separator: "/").map(String.init)
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com"),
           parts.count >= 2, parts[0] == "embed" {
            return "https://www.youtube.com/watch?v=" + parts[1]
        }
        if host == "player.vimeo.com", parts.count >= 2, parts[0] == "video" {
            return "https://vimeo.com/" + parts[1]
        }
        return address
    }

    /// "YouTube video", "Google Slides": what it is. Otherwise the title the
    /// teacher's page gave it, or where it's from.
    static func name(for address: String, given: String, kind: String?) -> String {
        let url = URL(string: address)
        let host = (url?.host ?? "").lowercased()
        let path = (url?.path ?? "").lowercased()
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") || host == "youtu.be" {
            return "YouTube video"
        }
        if host.contains("vimeo.com") { return "Vimeo video" }
        if host == "docs.google.com" {
            if path.hasPrefix("/presentation") { return "Google Slides" }
            if path.hasPrefix("/document") { return "Google Docs" }
            if path.hasPrefix("/spreadsheets") { return "Google Sheets" }
            if path.hasPrefix("/forms") { return "Google Forms" }
        }
        if host.contains("geogebra.org") { return "GeoGebra" }
        if !given.isEmpty { return given }
        if kind == "audio" { return "Sound" }
        if kind == "video" { return "Video" }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.isEmpty ? "Embedded page" : bare
    }

    /// Whether it plays, for the row's symbol.
    static func isVideo(_ address: String) -> Bool {
        let url = URL(string: address)
        let host = (url?.host ?? "").lowercased()
        let path = (url?.path ?? "").lowercased()
        return host.contains("youtube") || host == "youtu.be" || host.contains("vimeo")
            || [".mp4", ".mov", ".m4v", ".webm"].contains { path.hasSuffix($0) }
    }
}
