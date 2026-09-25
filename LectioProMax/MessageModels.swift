import Foundation

/// A row in the inbox.
/// Lectio's message folders, by the ids its folder tree uses.
enum MessageFolder: Int, CaseIterable, Identifiable {
    case newest = -70      // "Nyeste" — Lectio's own default view
    case unread = -40      // "Alle ulæste"
    case flagged = -50     // "Alle med flag"
    case sent = -80        // "Sendte beskeder"
    case deleted = -60     // "Alle slettede"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .newest: return "Messages"
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .sent: return "Sent"
        case .deleted: return "Deleted"
        }
    }

    var menuTitle: String { self == .newest ? "Newest" : title }

    var icon: String {
        switch self {
        case .newest: return "tray"
        case .unread: return "envelope.badge"
        case .flagged: return "flag"
        case .sent: return "paperplane"
        case .deleted: return "trash"
        }
    }

    var emptyText: String {
        switch self {
        case .newest: return "No messages"
        case .unread: return "Nothing unread"
        case .flagged: return "Nothing flagged"
        case .sent: return "Nothing sent"
        case .deleted: return "Nothing deleted"
        }
    }
}

struct MessageThreadSummary: Identifiable, Hashable, Codable {
    var id: String = ""             // Lectio's thread id
    var subject: String = ""
    var latestSender: String = ""
    var firstSender: String = ""
    var recipients: String = ""
    var changed: String = ""        // "15:21" today, otherwise a date
    var unread: Bool = false
    var flagged: Bool = false
    var hasAttachment: Bool = false

    var link: String {
        return LectioConfig.base + "/beskeder2.aspx?type=visbesked&id=" + id
    }
}

struct MessageAttachment: Identifiable, Hashable, Codable {
    var id: String { link }
    var name: String = ""
    var link: String = ""
}

/// One message inside a thread.
struct ThreadMessage: Identifiable, Hashable, Codable {
    var id: String { sender + "|" + date + "|" + String(body.prefix(48)) }
    var sender: String = ""
    var date: String = ""
    var title: String = ""
    var body: String = ""
    var attachments: [MessageAttachment] = []
}

struct MessageThread {
    var id: String = ""
    var subject: String = ""
    var recipients: String = ""
    var messages: [ThreadMessage] = []
    /// Lectio hides the reply box on threads marked "kan ikke besvares".
    var canReply = false
    /// The ASP.NET control prefix of the composer row, e.g.
    /// `s$m$Content$Content$MessageThreadCtrl$MessagesGV$ctl06`. It's an index
    /// into the messages grid, so it shifts as a thread grows — always read it
    /// from the page rather than hard-coding it.
    var composerPrefix: String = ""
    var form: [String: String] = [:]
    var pageURL: String = ""
}

/// Someone (or some class/group) a message can be sent to.
struct Recipient: Identifiable, Hashable, Codable {
    var id: String = ""            // e.g. "T66601704359", "S80637536702"
    var name: String = ""
    var kind: RecipientKind = .teacher

    enum RecipientKind: String, Codable {
        case teacher, student, team, group

        var icon: String {
            switch self {
            case .teacher: return "person.text.rectangle"
            case .student: return "person"
            case .team: return "person.3"
            case .group: return "person.2.badge.gearshape"
            }
        }

        var label: String {
            switch self {
            case .teacher: return "Teacher"
            case .student: return "Student"
            case .team: return "Class"
            case .group: return "Group"
            }
        }
    }
}
