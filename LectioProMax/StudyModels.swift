import Foundation

/// A lesson's homework and note, from Lectio's "Lektier" overview. Richer than
/// the dashboard block: that only lists titles, this carries the full text.
struct LessonNote: Identifiable, Hashable, Codable {
    var id: String { date + "|" + start + "|" + code + "|" + title }
    var date: String = ""        // ISO
    var start: String = ""
    var end: String = ""
    var code: String = ""
    var title: String = ""
    var teacher: String = ""
    var room: String = ""
    var homework: String = ""
    var note: String = ""
    var link: String? = nil

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !code.isEmpty { return code.uppercased() }
        return "Lesson"
    }
}

/// One row of Lectio's absence overview — a subject, and how much you've missed.
struct AbsenceSubject: Identifiable, Hashable, Codable {
    var id: String { code }
    var code: String = ""          // "1j hi"
    var modules: String = ""       // "1/3"
    var percent: String = ""       // "16,7%"
    var writtenModules: String = ""
    var writtenPercent: String = ""
    var isTotal: Bool = false

    /// The percentage as a number, for sorting and colouring.
    var percentValue: Double {
        let cleaned = percent.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }
}

/// A single absence registration.
struct AbsenceRecord: Identifiable, Hashable, Codable {
    var id: String { (reasonLink ?? "") + "|" + date + "|" + start + "|" + code }
    var week: String = ""
    var date: String = ""          // ISO
    var start: String = ""
    var end: String = ""
    var module: String = ""        // "Module 1"
    var code: String = ""          // "1j nv"
    var teacher: String = ""
    var room: String = ""
    var percent: String = ""
    var registered: String = ""
    var reason: String = ""        // Lectio's Danish value, e.g. "Sygdom"
    var comment: String = ""
    /// The page that lets you give (or change) a reason.
    var reasonLink: String? = nil
    /// True when Lectio is still waiting for you to explain it.
    var needsReason: Bool = false

    /// "Tue 15 Sep · 08:00–09:35 · Module 1"
    var whenLine: String {
        var bits: [String] = []
        if !date.isEmpty { bits.append(LectioDates.dayLabel(iso: date)) }
        if !start.isEmpty {
            bits.append(end.isEmpty ? start : start + "–" + end)
        }
        if !module.isEmpty { bits.append(module) }
        return bits.joined(separator: " · ")
    }

    var whereLine: String {
        return [code.uppercased(), room, teacher].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Lectio's absence vocabulary is Danish. These are the labels the app shows;
/// the Danish value is what gets sent back, since that's what the form expects.
enum AbsenceWording {
    static func reason(_ danish: String) -> String {
        switch danish.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sygdom": return "Illness"
        case "kom for sent": return "Late arrival"
        case "private forhold": return "Personal reasons"
        case "skolerelaterede aktiviteter": return "School activity"
        case "andet": return "Other"
        default: return danish
        }
    }

    static func subject(_ danish: String) -> String {
        switch danish.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "samlet": return "Total"
        case "ej hold": return "No class"
        default: return danish
        }
    }
}

/// Someone or something whose timetable can be looked up.
struct ScheduleTarget: Identifiable, Hashable, Codable {
    var id: String { url }
    var name: String = ""
    var url: String = ""           // absolute SkemaNy URL
    var kind: Kind = .teacher

    enum Kind: String, Codable, CaseIterable {
        case student, teacher, klasse, subject, room

        var label: String {
            switch self {
            case .student: return "Students"
            case .teacher: return "Teachers"
            case .klasse:  return "Classes"
            case .subject: return "Subjects"
            case .room:    return "Rooms"
            }
        }

        var icon: String {
            switch self {
            case .student: return "person"
            case .teacher: return "person.text.rectangle"
            case .klasse:  return "person.3"
            case .subject: return "book"
            case .room:    return "door.left.hand.open"
            }
        }

        /// The FindSkema listing each kind comes from. Subjects have none —
        /// FindSkema's `hold` page serves no list at all — so they're read off
        /// your own timetable instead, which is the useful set anyway.
        var findSkemaType: String {
            switch self {
            case .student: return "elev"
            case .teacher: return "laerer"
            case .klasse:  return "stamklasse"
            case .subject: return ""
            case .room:    return "lokale"
            }
        }
    }

    /// The id Lectio's context card wants: the person's id with a letter in
    /// front, which is also how it spells them everywhere else ("S80637536702").
    /// Only people have one.
    var contextCardID: String? {
        switch kind {
        case .student:
            guard let g = Rx.match("elevid=(\\d+)", url) else { return nil }
            return "S" + g[1]
        case .teacher:
            guard let g = Rx.match("laererid=(\\d+)", url) else { return nil }
            return "T" + g[1]
        default:
            return nil
        }
    }
}

// MARK: - Studieplan

/// One forløb — a teaching unit, a few weeks long.
struct StudyPhase: Identifiable, Hashable {
    var id: String { link.isEmpty ? title : link }
    var title: String = ""
    var link: String = ""
    var estimate: String = ""      // "2,00" modules, as Lectio writes it
    var period: String = ""        // "to 13/8-26 - to 20/8-26"
    var summary: String = ""       // the description, from Lectio's own tooltip
}

/// A subject's whole year: its units, and the hours it expects of you.
struct StudyPlanSubject: Identifiable, Hashable {
    var id: String { name }
    var name: String = ""          // "1j ma"
    var phases: [StudyPhase] = []
    /// Elevtid: hours logged against the subject, and the year's norm. Lectio
    /// leaves the norm off for subjects that haven't got one.
    var hours: Double = 0
    var norm: Double = 0

    var hasNorm: Bool { norm > 0 }
    var progress: Double {
        guard norm > 0 else { return 0 }
        return min(hours / norm, 1)
    }

    /// "1j ma" is the team; the subject code is the part after the class.
    var code: String {
        return name.split(separator: " ").dropFirst().first.map(String.init) ?? name
    }
}

// MARK: - A lesson's full page

/// A file pinned to a lesson in Lectio.
struct LessonFile: Identifiable, Hashable {
    var id: String { link }
    var name: String = ""
    var link: String = ""
}

/// One block of content on a lesson's page — a piece of text, a file, or both.
struct LessonEntry: Identifiable, Hashable {
    var id: String
    var text: String = ""
    var files: [LessonFile] = []

    var isEmpty: Bool { text.isEmpty && files.isEmpty }
}

/// Lectio groups a lesson's content under headings: "Lektier", "Øvrigt indhold"
/// and so on. Kept as Lectio writes them, since a school can add its own.
struct LessonSection: Identifiable, Hashable {
    var id: String { title + "|" + String(entries.count) }
    var title: String = ""
    var entries: [LessonEntry] = []
}

/// Lectio writes its section headings in Danish. Shown in English where we
/// recognise them, left alone where a school has invented its own.
enum LessonWording {
    static func section(_ danish: String) -> String {
        switch danish.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "lektier": return "Homework"
        case "note", "noter": return "Note"
        case "øvrigt indhold", "ovrigt indhold": return "Other content"
        case "præsentation", "praesentation": return "Presentation"
        case "indhold", "content": return "Content"
        case "materialer": return "Materials"
        case "opgaver": return "Assignments"
        case "elevfeedback": return "Student feedback"
        default: return danish
        }
    }
}

/// Everything on `aktivitetforside2.aspx` for one lesson.
struct LessonDetail {
    var note: String = ""          // the activity note, e.g. "Water 2:1"
    var sections: [LessonSection] = []

    var files: [LessonFile] { sections.flatMap { $0.entries.flatMap { $0.files } } }
    var isEmpty: Bool { note.isEmpty && sections.allSatisfy { $0.entries.allSatisfy { $0.isEmpty } } }
}


extension ScheduleTarget {
    /// Lectio writes a student's class into their name: "Ababacarr Mbye Jaye
    /// (1u 01)" — class 1u, number 01.
    var studentClass: String? {
        guard kind == .student, let g = Rx.match("\\(([^)]+)\\)\\s*$", name) else { return nil }
        let inside = g[1].trimmingCharacters(in: .whitespaces)
        return inside.split(separator: " ").first.map(String.init)
    }

    /// The name without the trailing "(1u 01)".
    var shortName: String {
        guard kind == .student, let cut = name.range(of: " (", options: .backwards) else { return name }
        return String(name[..<cut.lowerBound])
    }
}

extension ScheduleTarget {
    /// What the list sorts and indexes by: a student's own name, not Lectio's
    /// "Name (1u 01)" string.
    var sortName: String { kind == .student ? shortName : name }

    /// The letter this lands under in the index.
    var indexLetter: String {
        guard let first = sortName.trimmingCharacters(in: .whitespaces).first else { return "#" }
        return first.isLetter ? String(first).uppercased() : "#"
    }
}
