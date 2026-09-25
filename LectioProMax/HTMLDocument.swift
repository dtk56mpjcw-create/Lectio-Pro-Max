import Foundation

/// Single-pass tolerant HTML tokenizer producing an HTMLNode tree.
///
/// Runs over the page's raw UTF-8 bytes. The previous version walked
/// `[Character]` and built two Strings for every character it compared, which
/// cost seconds per page on device — Lectio's schedule is ~75 KB and a refresh
/// parses several pages. Byte scanning with sliced Strings only at the points
/// where we actually emit text is roughly two orders of magnitude cheaper.
enum HTMLDocument {

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    // ASCII bytes this scanner tests for constantly.
    private static let lt: UInt8 = 0x3C        // <
    private static let gt: UInt8 = 0x3E        // >
    private static let slash: UInt8 = 0x2F     // /
    private static let bang: UInt8 = 0x21      // !
    private static let qmark: UInt8 = 0x3F     // ?
    private static let dquote: UInt8 = 0x22    // "
    private static let squote: UInt8 = 0x27    // '
    private static let equalsB: UInt8 = 0x3D   // =
    private static let dash: UInt8 = 0x2D      // -
    private static let ampB: UInt8 = 0x26      // &
    private static let semi: UInt8 = 0x3B      // ;

    private static let commentOpen: [UInt8] = Array("<!--".utf8)
    private static let scriptClose: [UInt8] = Array("</script".utf8)
    private static let styleClose: [UInt8] = Array("</style".utf8)

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        return b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    @inline(__always)
    private static func isLetter(_ b: UInt8) -> Bool {
        let l = b | 0x20
        return l >= 0x61 && l <= 0x7A
    }

    @inline(__always)
    private static func lower(_ b: UInt8) -> UInt8 {
        return (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
    }

    // MARK: - Tokenizer

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(name: "#root")
        var stack: [HTMLNode] = [root]
        let bytes = Array(html.utf8)
        let count = bytes.count
        var i = 0
        var textBuf: [UInt8] = []
        textBuf.reserveCapacity(512)

        func flushText() {
            if !textBuf.isEmpty {
                stack[stack.count - 1].content.append(.text(decode(textBuf)))
                textBuf.removeAll(keepingCapacity: true)
            }
        }

        while i < count {
            let ch = bytes[i]

            if ch != lt {
                textBuf.append(ch)
                i += 1
                continue
            }

            // Comment
            if matches(bytes, i, commentOpen) {
                flushText()
                var j = i + 4
                while j + 2 < count && !(bytes[j] == dash && bytes[j + 1] == dash && bytes[j + 2] == gt) {
                    j += 1
                }
                i = min(j + 3, count)
                continue
            }

            // Doctype / processing instruction
            if i + 1 < count && (bytes[i + 1] == bang || bytes[i + 1] == qmark) {
                flushText()
                var j = i + 2
                while j < count && bytes[j] != gt { j += 1 }
                i = min(j + 1, count)
                continue
            }

            // Closing tag
            if i + 1 < count && bytes[i + 1] == slash {
                flushText()
                var j = i + 2
                let nameStart = j
                while j < count && bytes[j] != gt { j += 1 }
                let tagName = lowerToken(bytes, nameStart, j)
                if stack.count > 1 {
                    var k = stack.count - 1
                    while k > 0 {
                        if stack[k].name == tagName {
                            stack.removeSubrange(k..<stack.count)
                            break
                        }
                        k -= 1
                    }
                }
                i = min(j + 1, count)
                continue
            }

            // Opening tag
            if i + 1 < count && isLetter(bytes[i + 1]) {
                flushText()
                var j = i + 1
                let bodyStart = j
                var quote: UInt8 = 0
                var previousNonSpace: UInt8 = 0x20
                while j < count {
                    let c = bytes[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if (c == dquote || c == squote) && previousNonSpace == equalsB {
                        // Only a quote immediately after '=' opens an attribute
                        // value. Lectio ships stray quotes (class="..."" style=...);
                        // treating those as value delimiters ran us past '>'.
                        quote = c
                    } else if c == gt {
                        break
                    }
                    if !isSpace(c) { previousNonSpace = c }
                    j += 1
                }

                var bodyEnd = j
                var selfClosing = false
                if bodyEnd > bodyStart && bytes[bodyEnd - 1] == slash {
                    selfClosing = true
                    bodyEnd -= 1
                }

                let parsed = splitTag(bytes, bodyStart, bodyEnd)
                let node = HTMLNode(name: parsed.0, attrs: parsed.1)
                node.parent = stack[stack.count - 1]
                stack[stack.count - 1].content.append(.element(node))

                i = min(j + 1, count)

                if selfClosing || voidElements.contains(node.name) { continue }

                // Raw-text elements: skip their contents entirely.
                if node.name == "script" || node.name == "style" {
                    let closing = node.name == "script" ? scriptClose : styleClose
                    var k = i
                    while k < count {
                        if bytes[k] == lt && matches(bytes, k, closing) { break }
                        k += 1
                    }
                    var m = k
                    while m < count && bytes[m] != gt { m += 1 }
                    i = min(m + 1, count)
                    continue
                }

                stack.append(node)
                continue
            }

            // Stray '<'
            textBuf.append(ch)
            i += 1
        }

        flushText()
        return root
    }

    /// Case-insensitive literal comparison at a byte position.
    @inline(__always)
    private static func matches(_ bytes: [UInt8], _ start: Int, _ needle: [UInt8]) -> Bool {
        if start + needle.count > bytes.count { return false }
        for k in 0..<needle.count {
            if lower(bytes[start + k]) != lower(needle[k]) { return false }
        }
        return true
    }

    /// Whitespace-trimmed, ASCII-lowercased string for a byte range.
    private static func lowerToken(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        var s = start
        var e = end
        while s < e && isSpace(bytes[s]) { s += 1 }
        while e > s && isSpace(bytes[e - 1]) { e -= 1 }
        if s >= e { return "" }
        var out = [UInt8]()
        out.reserveCapacity(e - s)
        for k in s..<e { out.append(lower(bytes[k])) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Splits `a href="x" class="y"` into ("a", ["href": "x", "class": "y"]).
    static func splitTag(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (String, [String: String]) {
        var i = start
        while i < end && !isSpace(bytes[i]) { i += 1 }
        let name = lowerToken(bytes, start, i)

        var attrs: [String: String] = [:]
        while i < end {
            while i < end && isSpace(bytes[i]) { i += 1 }
            if i >= end { break }

            let keyStart = i
            while i < end && !isSpace(bytes[i]) && bytes[i] != equalsB { i += 1 }
            let key = lowerToken(bytes, keyStart, i)
            while i < end && isSpace(bytes[i]) { i += 1 }

            var value = ""
            if i < end && bytes[i] == equalsB {
                i += 1
                while i < end && isSpace(bytes[i]) { i += 1 }
                if i < end && (bytes[i] == dquote || bytes[i] == squote) {
                    let q = bytes[i]
                    i += 1
                    let vs = i
                    while i < end && bytes[i] != q { i += 1 }
                    value = decode(Array(bytes[vs..<i]))
                    if i < end { i += 1 }
                } else {
                    let vs = i
                    while i < end && !isSpace(bytes[i]) { i += 1 }
                    value = decode(Array(bytes[vs..<i]))
                }
            }

            if !key.isEmpty { attrs[key] = value }
        }

        return (name, attrs)
    }

    // MARK: - Entities

    static func decodeEntities(_ s: String) -> String {
        return decode(Array(s.utf8))
    }

    /// Entity-decodes a byte run. Entity names are ASCII, so this is safe to do
    /// byte-wise even though the surrounding text may be UTF-8.
    static func decode(_ bytes: [UInt8]) -> String {
        if !bytes.contains(ampB) { return String(decoding: bytes, as: UTF8.self) }

        let count = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(count)
        var i = 0
        while i < count {
            if bytes[i] == ampB {
                var j = i + 1
                var terminated = false
                while j < count && (j - i) <= 12 {
                    if bytes[j] == semi { terminated = true; break }
                    j += 1
                }
                if terminated {
                    let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    if let decoded = decodeEntity(name) {
                        out.append(contentsOf: Array(decoded.utf8))
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            let hex = String(entity.dropFirst(2))
            if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                return String(Character(scalar))
            }
            return nil
        }
        if entity.hasPrefix("#") {
            let dec = String(entity.dropFirst())
            if let v = UInt32(dec), let scalar = Unicode.Scalar(v) {
                return String(Character(scalar))
            }
            return nil
        }
        return nil
    }
}
