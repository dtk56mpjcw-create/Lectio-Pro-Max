import Foundation

/// One row of Lectio's "Indlæg" table on an assignment: a document someone
/// attached, or a comment someone wrote.
struct HandInEntry: Identifiable, Hashable {
    var id: String { time + "|" + user + "|" + document + "|" + comment }
    var time: String = ""
    var user: String = ""
    var comment: String = ""
    var document: String = ""
    var documentLink: String? = nil
}

/// The student row: where the assignment stands right now.
struct HandInStatus: Hashable {
    var waitingFor: String = ""     // "Elev" / "Lærer"
    var delivery: String = ""       // "Afleveret / Fravær: 0%" or "Ikke aflev./ Fravær: 100%"
    var finished: Bool = false      // Lectio's "Afsluttet" checkbox
    var grade: String = ""
    var gradeNote: String = ""
    var studentNote: String = ""

    var isDelivered: Bool {
        let lower = delivery.lowercased()
        return lower.contains("afleveret") && !lower.contains("ikke")
    }

    /// "Afventer: Lærer" means it's with the teacher and there's nothing to do.
    var waitingOnTeacher: Bool { waitingFor.lowercased().contains("lærer") }

    /// Lectio writes this column as "Afleveret / Fravær: 0%" or
    /// "Ikke aflev./ Fravær: 100%" — the hand-in state and the absence the
    /// assignment counts for, in one string. Said in English.
    var deliveryLine: String {
        guard !delivery.isEmpty else { return "" }
        var parts: [String] = [isDelivered ? "Handed in" : "Not handed in"]
        if let group = Rx.match("fravær:\\s*([0-9]+(?:[.,][0-9]+)?\\s*%)", delivery) {
            parts.append("counts as " + group[1].replacingOccurrences(of: " ", with: "") + " absence")
        }
        return parts.joined(separator: " · ")
    }
}

/// Someone in a group hand-in, or someone who could be added to one.
struct GroupPerson: Identifiable, Hashable {
    /// Lectio's elevid.
    var id: String
    var name: String            // "Ivan Surov"
    var className: String = ""  // "1j 12"
    /// Lectio's own postback for taking this person off the group, when the
    /// page offers one (it doesn't always — nor once the assignment closes).
    var removeTarget: String? = nil
    var removeArgument: String = ""

    /// As a schedule target, so the app's avatars and people lists can show it.
    var asTarget: ScheduleTarget {
        ScheduleTarget(name: className.isEmpty ? name : name + " (" + className + ")",
                       url: LectioConfig.skemaURL + "?type=elev&elevid=" + id,
                       kind: .student)
    }
}

struct HandIn {
    var status = HandInStatus()
    var entries: [HandInEntry] = []
    /// A group hand-in ("Gruppeaflevering"): who's in it, and — while Lectio
    /// still allows it — who from the class can be added.
    var isGroup = false
    var groupMembers: [GroupPerson] = []
    var groupCandidates: [GroupPerson] = []
    /// False once Lectio closes the assignment — then no upload is possible.
    var canHandIn = false
    /// Every enabled field of Lectio's ASP.NET form, ready to be posted back.
    /// ASP.NET rejects a post that doesn't carry its own __VIEWSTATEX and
    /// __EVENTVALIDATION back verbatim, so these have to be read per request.
    var form: [String: String] = [:]
    var pageURL: String = ""
}
