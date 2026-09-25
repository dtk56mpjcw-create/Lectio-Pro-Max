import Foundation

/// The first few lines of a piece of homework or an assignment, so the list
/// says what to do without opening anything.
///
/// Homework's text comes from the lesson's tooltip, which Lectio writes as
/// dashed lines cut short with "[...]", with any files listed by name.
/// Assignments carry the teacher's note from the assignments list.
struct WorkPreview: Hashable {
    /// Plain text, lines run together; empty when there's nothing to say.
    var text: String = ""
    /// Attached files, by name.
    var files: [String] = []

    var isEmpty: Bool { text.isEmpty && files.isEmpty }

    static func make(_ raw: String, title: String) -> WorkPreview {
        var preview = WorkPreview()
        var paragraphs: [String] = []
        let tidyTitle = LectioDates.tidy(title)

        // Homework and the lesson's note arrive as separate paragraphs; each
        // becomes one run of text, so the note starts on a line of its own
        // instead of running on from the homework's last sentence.
        let blocks = raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
        for block in blocks {
            var lines: [String] = []
            for piece in LectioDates.tidy(block).components(separatedBy: "\n") {
                var line = piece.trimmingCharacters(in: .whitespaces)
                // tidy() turns Lectio's "[...]" into "…", sometimes followed by
                // another "...". One ellipsis says the text was cut; a file
                // name doesn't need one at all.
                var cut = false
                while line.hasSuffix("…") || line.hasSuffix("...") {
                    line = String(line.dropLast(line.hasSuffix("…") ? 1 : 3))
                        .trimmingCharacters(in: .whitespaces)
                    cut = true
                }
                if line.isEmpty { continue }

                // Lectio's own block labels, sometimes left on a line of their own.
                let bare = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if bare == "lektier" || bare == "note" || bare == "homework" { continue }
                if line.caseInsensitiveCompare(tidyTitle) == .orderedSame { continue }

                if isFileName(line) {
                    preview.files.append(line)
                } else {
                    lines.append(cut ? line + "…" : line)
                }
            }
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: " ")) }
        }
        preview.text = paragraphs.joined(separator: "\n")
        return preview
    }

    private static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "odt", "odp", "ods",
        "txt", "rtf", "png", "jpg", "jpeg", "heic", "gif", "mp3", "mp4", "m4a",
        "mov", "zip", "pages", "key", "numbers", "epub"
    ]

    private static func isFileName(_ line: String) -> Bool {
        guard line.count <= 120, !line.contains(": "),
              let dot = line.lastIndex(of: ".") else { return false }
        let ext = line[line.index(after: dot)...].lowercased()
        return fileExtensions.contains(ext)
    }
}

extension WorkItem {
    var preview: WorkPreview { WorkPreview.make(text, title: title) }

    /// Homework on a lesson with no topic gets the team code as its title
    /// ("AP LA" over "AP LA"); the subject's name says more.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let justCode = trimmed.isEmpty || trimmed.caseInsensitiveCompare(code) == .orderedSame
        if justCode, let key = SubjectPalette.subjectKey(code) {
            return SubjectNames.name(forKey: key)
        }
        return LectioDates.tidy(title)
    }

    /// A school-wide event lists every class it's for ("1A-ELEVER, ALLE
    /// 1B-ELEVER, …"), which is no use as a label or a filter.
    var isSubjectCode: Bool {
        !code.isEmpty && !code.contains(",") && code.count <= 12
    }

    var displayCode: String {
        guard code.contains(",") else { return code.uppercased() }
        let parts = code.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return code.uppercased() }
        let shown = first.uppercased()
        return parts.count > 1 ? shown + " +\(parts.count - 1)" : shown
    }
}
