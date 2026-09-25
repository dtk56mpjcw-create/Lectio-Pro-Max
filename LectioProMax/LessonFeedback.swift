import UIKit

/// Elevfeedback — the student's own writing on a lesson.
///
/// Lectio renders it with CKEditor, which looks discouraging but isn't: the
/// editor is a skin over a plain `<textarea>` whose value is an HTML fragment,
/// and its Save button is an ordinary ASP.NET postback. From `lc.bundle.js`:
///
///     ke.SaveEditorBookmark(e), window.__doPostBack(t.postBackCtrlId_save, "save")
///
/// and the page's own inline config gives
///
///     postBackCtrlId_save: 's$m$…$HomeworkEditLV$ctrl0$editor'
///
/// which is exactly the textarea's name (`…$editor$ed`) without the `$ed`. So we
/// never have to scrape that config: the target is derivable from the field.
struct LessonFeedback {
    /// The `?lectab=elevindhold` page — where both the read and the write happen.
    var pageURL: String = ""
    /// The lesson page it hangs off, kept so a save can re-fetch fresh state.
    var lessonURL: String = ""
    /// The editor textarea's name, e.g. `s$m$…$editor$ed`.
    var fieldName: String = ""
    /// The saved HTML fragment, exactly as Lectio stores it.
    var html: String = ""
    /// Everything the page expects posted back (`__VIEWSTATEX` and friends).
    var form: [String: String] = [:]
    /// False when the lesson has no Elevfeedback tab at all.
    var available = false
    /// True when this page actually has the editor on it. Lectio serves the tab
    /// read-only until "Rediger" is pressed, and about half the lessons come back
    /// that way on a plain GET, so "no textarea" does NOT mean "no feedback here".
    var hasEditor = false
    /// The postback target behind Lectio's "Rediger" button, when it's in view mode.
    var editModeTarget = ""
    /// Lectio's own delete control, scraped per page: both halves are generated,
    /// and the argument carries the content block's id.
    var deleteTarget = ""
    var deleteArgument = ""

    var canDelete: Bool { !deleteTarget.isEmpty }
    /// False when the content uses markup the native editor can't represent
    /// faithfully — a table or an image. Then it's shown but not edited here,
    /// because silently dropping a table on save would be worse than not editing.
    var editable = false
    /// Lectio's own grey hint ("Her kan eleven…"), when it offers one.
    var placeholder: String = ""

    /// The editor control is the postback target; the textarea is that plus `$ed`.
    var saveTarget: String {
        return fieldName.hasSuffix("$ed") ? String(fieldName.dropLast(3)) : fieldName
    }
    var dirtyField: String { saveTarget + "$isDirty" }

    var plainText: String { FeedbackHTML.plainText(html) }
    var isEmpty: Bool { plainText.isEmpty }
}

// MARK: - Attributes carried through the editor

extension NSAttributedString.Key {
    /// "ul" or "ol" on every character of a list item's paragraph.
    static let feedbackList = NSAttributedString.Key("lpmFeedbackList")
    /// An anchor's href.
    static let feedbackHref = NSAttributedString.Key("lpmFeedbackHref")
    /// True when that anchor is one of Lectio's attached files.
    static let feedbackIsFile = NSAttributedString.Key("lpmFeedbackIsFile")
    /// A span's `style` string, kept verbatim so colours survive a round-trip.
    static let feedbackStyle = NSAttributedString.Key("lpmFeedbackStyle")
    /// The "• " or "3. " a list item shows in the editor. Visible while editing,
    /// stripped on the way out: `<ul>`/`<ol>` draw their own markers.
    static let feedbackMarker = NSAttributedString.Key("lpmFeedbackMarker")
}

/// Converts between Lectio's HTML fragment and something a UITextView can edit.
///
/// Deliberately hand-written rather than `NSAttributedString(data:options:)`
/// with `.html`: that importer is fine going in, but its *exporter* emits
/// enormous Cocoa-flavoured markup — inline CSS on every paragraph, `-webkit`
/// properties, font tables — which would look wrong in Lectio's own editor
/// afterwards and be unpleasant for a teacher to read. Writing the HTML by hand
/// means only tags we actually handle ever reach Lectio.
enum FeedbackHTML {

    static let bodyFont = UIFont.systemFont(ofSize: 17)

    /// The tags the editor can represent without loss. Anything else makes the
    /// content read-only rather than risking a lossy save.
    /// Verified against Lectio's own CKEditor `dataProcessor` on a real lesson
    /// page: `<strong>`, `<em>`, `<s>`, lists, `<span style>` and the file anchor
    /// all survive a round-trip through its sanitiser untouched, while `<u>` and
    /// `<del>` are DELETED outright — Lectio's editor has no underline button and
    /// its content filter drops the tag. Headings, sub/sup, blockquotes, tables
    /// and images survive there but can't be represented here, so content using
    /// them is shown read-only rather than silently flattened on save.
    ///
    /// Headings are READ but never written. Lectio makes the first block of a
    /// feedback into `<h1 id="…">` all by itself — send it a plain `<p>` and it
    /// comes back as a heading with an id of Lectio's choosing — so the app has
    /// no reason to model one.
    ///
    /// It used to. The heading was drawn in a bold font and marked with an
    /// invisible per-character attribute saying "this is heading number N with
    /// this id". Typing inherits a font but not always a custom attribute, so a
    /// heading line could end up bold-but-no-longer-a-heading, and the writer
    /// dutifully turned that into a second `<p><strong>…</strong></p>` carrying a
    /// copy of the heading's text — which is exactly the duplicate that kept
    /// appearing in Lectio. Nothing invisible survives typing any more: a
    /// paragraph is a paragraph, and Lectio decides which one is the title.
    static let supportedTags: Set<String> = [
        "p", "div", "br", "span", "font",
        "strong", "b", "em", "i", "s", "strike",
        "ul", "ol", "li", "a",
        "h1", "h2", "h3",
    ]

    private struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var href: String?
        var isFile = false
        var css: String?
    }

    // MARK: - Lectio HTML -> editable attributed text

    static func attributed(from html: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard !html.isEmpty else { return out }
        let root = HTMLDocument.parse("<div id=\"lpmFeedbackRoot\">" + html + "</div>")
        guard let holder = root.first(id: "lpmFeedbackRoot") else { return out }
        render(holder, Style(), nil, into: out)
        trimTrailingNewlines(out)
        return out
    }

    static func plainText(_ html: String) -> String {
        let text = attributed(from: html).string
        return HTMLNode.collapseWhitespace(text)
    }

    static func isEditable(_ html: String) -> Bool {
        guard !html.isEmpty else { return true }
        let root = HTMLDocument.parse("<div id=\"lpmFeedbackRoot\">" + html + "</div>")
        guard let holder = root.first(id: "lpmFeedbackRoot") else { return true }
        return onlySupportedTags(holder)
    }

    private static func onlySupportedTags(_ node: HTMLNode) -> Bool {
        for child in node.children {
            if !supportedTags.contains(child.name) { return false }
            if !onlySupportedTags(child) { return false }
        }
        return true
    }

    private static func render(_ node: HTMLNode,
                               _ style: Style,
                               _ list: String?,
                               into out: NSMutableAttributedString) {
        for item in node.content {
            switch item {
            case .text(let raw):
                // A newline in Lectio's stored HTML is source layout, not a line
                // break — its editor puts one between every nested <span>.
                let flat = raw
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                if flat.isEmpty { continue }
                out.append(NSAttributedString(string: flat, attributes: attributes(for: style)))

            case .element(let el):
                switch el.name {
                case "script", "style":
                    continue

                case "br":
                    out.append(NSAttributedString(string: "\n", attributes: attributes(for: style)))

                case "b", "strong":
                    var inner = style; inner.bold = true
                    render(el, inner, list, into: out)

                case "i", "em":
                    var inner = style; inner.italic = true
                    render(el, inner, list, into: out)

                case "u":
                    var inner = style; inner.underline = true
                    render(el, inner, list, into: out)

                case "s", "strike", "del":
                    var inner = style; inner.strike = true
                    render(el, inner, list, into: out)

                case "span", "font":
                    var inner = style
                    if let css = el.attr("style"), !css.isEmpty { inner.css = css }
                    render(el, inner, list, into: out)

                case "a":
                    var inner = style
                    inner.href = el.attr("href")
                    inner.isFile = (el.attr("data-lc-display-linktype") == "file")
                    render(el, inner, list, into: out)

                case "ul", "ol":
                    var number = 1
                    for nested in el.content {
                        guard case .element(let child) = nested else { continue }
                        if child.name == "li" {
                            let marker = el.name == "ol" ? "\(number). " : "• "
                            renderListItem(child, style, el.name, marker, into: out)
                            number += 1
                        } else {
                            render(el: child, style, el.name, into: out)
                        }
                    }

                case "li":
                    // A stray list item with no list around it.
                    renderListItem(el, style, list ?? "ul", "• ", into: out)

                default:
                    // Every other element is treated as a block: paragraphs,
                    // divs, headings, table rows. Its children still render.
                    openBlock(out, style)
                    render(el, style, list, into: out)
                    closeBlock(out, style)
                }
            }
        }
    }

    /// One `<li>`: its own paragraph, marked with the list kind, and opened with
    /// a visible marker so the editor looks like a list rather than plain lines.
    private static func renderListItem(_ el: HTMLNode,
                                       _ style: Style,
                                       _ kind: String,
                                       _ marker: String,
                                       into out: NSMutableAttributedString) {
        openBlock(out, style)
        let start = out.length

        var markerAttributes = attributes(for: style)
        markerAttributes[.feedbackMarker] = true
        markerAttributes[.foregroundColor] = UIColor.secondaryLabel
        out.append(NSAttributedString(string: marker, attributes: markerAttributes))

        render(el, style, kind, into: out)
        closeBlock(out, style)

        if out.length > start {
            out.addAttribute(.feedbackList,
                             value: kind,
                             range: NSRange(location: start, length: out.length - start))
        }
    }

    /// Renders one element as if it were the only child of its parent.
    private static func render(el: HTMLNode,
                               _ style: Style,
                               _ list: String?,
                               into out: NSMutableAttributedString) {
        let holder = HTMLNode(name: "div")
        holder.content = [.element(el)]
        render(holder, style, list, into: out)
    }

    private static func openBlock(_ out: NSMutableAttributedString, _ style: Style) {
        guard out.length > 0 else { return }
        let last = (out.string as NSString).substring(from: out.length - 1)
        if last == "\n" { return }
        out.append(NSAttributedString(string: "\n", attributes: attributes(for: style)))
    }

    private static func closeBlock(_ out: NSMutableAttributedString, _ style: Style) {
        openBlock(out, style)
    }

    private static func trimTrailingNewlines(_ out: NSMutableAttributedString) {
        while out.length > 0 {
            let last = (out.string as NSString).substring(from: out.length - 1)
            guard last == "\n" || last == " " else { break }
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
    }

    /// Plain body attributes, for a fresh empty editor.
    static func baseAttributes(bold: Bool = false,
                               italic: Bool = false,
                               underline: Bool = false,
                               strike: Bool = false) -> [NSAttributedString.Key: Any] {
        var style = Style()
        style.bold = bold
        style.italic = italic
        style.underline = underline
        style.strike = strike
        return attributes(for: style)
    }

    private static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }

        var font = bodyFont
        if !traits.isEmpty,
           let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: bodyFont.pointSize)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let css = style.css { attrs[.feedbackStyle] = css }
        if let href = style.href, !href.isEmpty {
            attrs[.feedbackHref] = href
            attrs[.feedbackIsFile] = style.isFile
            attrs[.foregroundColor] = UIColor.systemBlue
            if !style.isFile { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        }
        return attrs
    }

    // MARK: - Editable attributed text -> Lectio HTML

    static func html(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        var cursor = 0
        while cursor <= ns.length {
            let rest = NSRange(location: cursor, length: ns.length - cursor)
            let newline = ns.range(of: "\n", options: [], range: rest)
            if newline.location == NSNotFound {
                paragraphs.append(NSRange(location: cursor, length: ns.length - cursor))
                break
            }
            paragraphs.append(NSRange(location: cursor, length: newline.location - cursor))
            cursor = newline.location + 1
        }

        // A trailing blank line is an artefact of typing, not content.
        while let last = paragraphs.last, last.length == 0 {
            paragraphs.removeLast()
        }

        var out = ""
        var openList: String?

        for range in paragraphs {
            let kind = listKind(text, range)
            if kind != openList {
                if let closing = openList { out += "</" + closing + ">" }
                if let opening = kind { out += "<" + opening + ">" }
                openList = kind
            }

            let inner = inlineHTML(text, range)
            let body = inner.isEmpty ? "&nbsp;" : inner
            out += (kind != nil) ? ("<li>" + body + "</li>") : ("<p>" + body + "</p>")
        }

        if let closing = openList { out += "</" + closing + ">" }
        return out
    }

    private static func listKind(_ text: NSAttributedString, _ range: NSRange) -> String? {
        guard range.length > 0, range.location < text.length else { return nil }
        return text.attribute(.feedbackList, at: range.location, effectiveRange: nil) as? String
    }

    private static func inlineHTML(_ text: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = text.string as NSString
        var out = ""

        text.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
            // The bullet the editor draws is chrome, not content.
            if attrs[.feedbackMarker] != nil { return }
            let raw = ns.substring(with: sub)
            if raw.isEmpty { return }
            var piece = escape(raw)

            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []

            if traits.contains(.traitBold) { piece = "<strong>" + piece + "</strong>" }
            if traits.contains(.traitItalic) { piece = "<em>" + piece + "</em>" }
            // No <u> is ever written: Lectio's content filter deletes the tag, so
            // emitting one would look like it worked and quietly lose the styling.
            // The underline attribute exists only to draw links in the editor.
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                piece = "<s>" + piece + "</s>"
            }
            if let css = attrs[.feedbackStyle] as? String, !css.isEmpty {
                piece = "<span style=\"" + escape(css) + "\">" + piece + "</span>"
            }
            if let href = attrs[.feedbackHref] as? String {
                let isFile = (attrs[.feedbackIsFile] as? Bool) ?? false
                let marker = isFile ? " data-lc-display-linktype=\"file\"" : ""
                piece = "<a href=\"" + escape(href) + "\"" + marker + ">" + piece + "</a>"
            }
            out += piece
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }
}
