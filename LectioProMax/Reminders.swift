import Foundation

/// When a reminder should fire, relative to the thing it's about.
enum ReminderTiming: String, CaseIterable, Codable {
    case eveningBefore
    case morningOf
    case twoHoursBefore

    var label: String {
        switch self {
        case .eveningBefore: return "Evening before"
        case .morningOf: return "Morning of"
        case .twoHoursBefore: return "2 hours before"
        }
    }

    var icon: String {
        switch self {
        case .eveningBefore: return "moon"
        case .morningOf: return "sunrise"
        case .twoHoursBefore: return "clock"
        }
    }
}

/// Which individual things have a reminder on them. Kept per item rather than as
/// one global switch, so a reminder is something you put on the thing itself.
enum RemindersStore {
    private static let key = "reminders.items"

    static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func timing(for itemKey: String) -> ReminderTiming? {
        guard let raw = all[itemKey] else { return nil }
        return ReminderTiming(rawValue: raw)
    }

    static func isOn(_ itemKey: String) -> Bool {
        return all[itemKey] != nil
    }

    static func set(_ timing: ReminderTiming?, for itemKey: String) {
        var current = all
        if let timing = timing {
            current[itemKey] = timing.rawValue
        } else {
            current.removeValue(forKey: itemKey)
        }
        all = current
    }

    /// Absence has no due date, so it just gets an on/off that fires the next
    /// morning; the timing enum doesn't apply.
    static func setAbsence(_ on: Bool, for itemKey: String) {
        set(on ? .morningOf : nil, for: itemKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
