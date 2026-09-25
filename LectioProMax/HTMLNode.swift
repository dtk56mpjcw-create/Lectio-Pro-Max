import Foundation

/// A very small, tolerant HTML DOM. Lectio serves server-rendered ASP.NET HTML,
/// so we don't need a full spec-compliant parser — just enough structure to run
/// the same queries the old Playwright scraper used (tag name, id, class, attrs).
/// Deliberately dependency-free so the app needs no Swift packages.

enum HTMLContent {
    case text(String)
    case element(HTMLNode)
}

final class HTMLNode {
    let name: String
    var attrs: [String: String]
    var content: [HTMLContent] = []
    weak var parent: HTMLNode?

    /// `class` is split on every `hasClass` call otherwise, and a single query
    /// touches every node in the document. Split once, keep the set.
    private var classCache: Set<String>?

    init(name: String, attrs: [String: String] = [:]) {
        self.name = name
        self.attrs = attrs
    }

    var children: [HTMLNode] {
        var out: [HTMLNode] = []
        for c in content {
            if case .element(let n) = c { out.append(n) }
        }
        return out
    }

    func attr(_ key: String) -> String? {
        return attrs[key.lowercased()]
    }

    var classList: [String] {
        let raw = attrs["class"] ?? ""
        return raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    func hasClass(_ c: String) -> Bool {
        if classCache == nil {
            let raw = attrs["class"] ?? ""
            if raw.isEmpty {
                classCache = []
            } else {
                classCache = Set(raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))
            }
        }
        return classCache!.contains(c)
    }

    /// Recursive inner text, entity-decoded and whitespace-collapsed.
    var text: String {
        var raw = ""
        collectText(into: &raw)
        return HTMLNode.collapseWhitespace(raw)
    }

    /// Inner text exactly as the source spells it: entity-decoded, but with no
    /// whitespace collapsing, no icon-font or duplicate-row filtering, and no
    /// synthetic line breaks. That's what a `<textarea>` means — Lectio's editor
    /// keeps a whole HTML fragment in there, entity-encoded, and running it
    /// through `text` would quietly rewrite the document we're about to save.
    var rawText: String {
        var out = ""
        collectRawText(into: &out)
        return out
    }

    private func collectRawText(into out: inout String) {
        for item in content {
            switch item {
            case .text(let t):
                out += t
            case .element(let el):
                el.collectRawText(into: &out)
            }
        }
    }

    private func collectText(into out: inout String) {
        for item in content {
            switch item {
            case .text(let t):
                // A newline in the source is layout, not a line break. Lectio's
                // editor content is Word-pasted HTML with a newline between every
                // nested <span>, which used to break sentences mid-word. Real
                // line breaks come from the block elements handled below.
                out += t.replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
            case .element(let el):
                if el.name == "script" || el.name == "style" { continue }
                // Lectio draws its icons with an icon FONT, so the glyph names
                // ("sms", "bookmark", "edit") are real text nodes and leak into
                // everything — that's where "smsbookmark" came from.
                if el.hasClass("ls-fonticon") { continue }
                // Every row is rendered twice, once for desktop and once for
                // mobile. Reading both duplicated every line.
                if el.hasClass("OnlyMobile") { continue }
                if el.name == "br" || el.name == "p" || el.name == "tr" || el.name == "div" || el.name == "li" {
                    out += "\n"
                }
                el.collectText(into: &out)
            }
        }
    }

    // MARK: - Queries
    //
    // These walk `content` directly rather than the `children` property: a query
    // visits every node in the document, and `children` allocates a fresh array
    // at each one.

    /// Every descendant with the given tag name.
    func all(_ tagName: String) -> [HTMLNode] {
        var out: [HTMLNode] = []
        collectAll(tagName, into: &out)
        return out
    }

    private func collectAll(_ tagName: String, into out: inout [HTMLNode]) {
        for item in content {
            guard case .element(let c) = item else { continue }
            if c.name == tagName { out.append(c) }
            c.collectAll(tagName, into: &out)
        }
    }

    /// Every descendant (any tag) carrying the given class.
    func allWithClass(_ cls: String) -> [HTMLNode] {
        var out: [HTMLNode] = []
        collectWithClass(cls, into: &out)
        return out
    }

    private func collectWithClass(_ cls: String, into out: inout [HTMLNode]) {
        for item in content {
            guard case .element(let c) = item else { continue }
            if c.hasClass(cls) { out.append(c) }
            c.collectWithClass(cls, into: &out)
        }
    }

    /// First descendant with the given id.
    func first(id: String) -> HTMLNode? {
        for item in content {
            guard case .element(let c) = item else { continue }
            if c.attrs["id"] == id { return c }
            if let found = c.first(id: id) { return found }
        }
        return nil
    }

    /// First descendant matching a predicate.
    func firstWhere(_ predicate: (HTMLNode) -> Bool) -> HTMLNode? {
        for item in content {
            guard case .element(let c) = item else { continue }
            if predicate(c) { return c }
            if let found = c.firstWhere(predicate) { return found }
        }
        return nil
    }

    /// Every descendant matching a predicate.
    func allWhere(_ predicate: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        collectWhere(predicate, into: &out)
        return out
    }

    private func collectWhere(_ predicate: (HTMLNode) -> Bool, into out: inout [HTMLNode]) {
        for item in content {
            guard case .element(let c) = item else { continue }
            if predicate(c) { out.append(c) }
            c.collectWhere(predicate, into: &out)
        }
    }

    // MARK: - Helpers

    static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch == "\n" {
                out.append("\n")
                lastWasSpace = true
                continue
            }
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\u{00A0}" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        // Never more than one blank line between paragraphs.
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
