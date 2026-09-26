import SwiftUI

/// A colour per subject, the way Calendar gives each calendar one.
///
/// This used to be five shades of one beige, picked by hashing the raw team
/// text. Run through a colour checker, the closest two shades measured a
/// difference of 5.3 where 15 is the minimum for full-colour vision to tell
/// neighbours apart easily, and all five read as grey. With eleven subjects and
/// five shades, several subjects were guaranteed to share one — and because
/// the raw text was hashed, "1j ma" and "ma" could even come out different.
///
/// Testing Apple's twelve system colours in every combination, in light and
/// dark mode, at most SEVEN stay clearly distinct from each other when any two
/// can sit side by side (they can: any two subjects can be back to back in a
/// day): red, orange, yellow, green, teal, blue and purple — nearly Calendar's
/// own preset list. So colour can't identify eleven subjects on its own. It's a
/// glanceable cue; the subject name is always printed next to it, in ordinary
/// text colour, never in the subject colour.
///
/// Every subject gets a colour. Your own pick wins (More → Subject colours);
/// otherwise a known subject has its default; anything else — another
/// school's subjects, or one of yours the app has never seen — gets one worked
/// out from its name, the same one every time, rather than grey. They are the
/// system colours themselves, never typed-in values, so Dark Mode and Increase
/// Contrast retune them automatically.
enum SubjectPalette {
    /// The defaults: the seven most distinct colours on the main subjects.
    static let defaults: [String: SubjectColorChoice] = [
        "da": .red,        // Danish
        "hi": .orange,     // History
        "sa": .yellow,     // Social studies
        "nv": .green,      // Science foundation course
        "ap": .teal,       // AP / Latin
        "la": .teal,
        "ma": .blue,       // Maths
        "en": .purple,     // English
    ]

    /// The order automatic colours are drawn from: the seven that stay
    /// distinct first, then the rest of Apple's set.
    private static let automatic: [SubjectColorChoice] = [
        .red, .orange, .yellow, .green, .teal, .blue, .purple,
        .pink, .indigo, .mint, .cyan, .brown,
    ]

    /// Which colour a subject has — picked, default or automatic.
    static func choice(forKey key: String) -> SubjectColorChoice {
        SubjectColors.shared.picked[key] ?? automaticChoice(forKey: key)
    }

    /// The colour a subject has when nothing's been picked for it.
    static func automaticChoice(forKey key: String) -> SubjectColorChoice {
        if let known = defaults[key] { return known }
        return automatic[Int(stableHash(key) % UInt64(automatic.count))]
    }

    static func color(for rawCode: String) -> Color {
        guard let key = subjectKey(rawCode) else { return .gray }
        return choice(forKey: key).color
    }

    /// Whether this subject has a colour of its own — every subject does now,
    /// unless you've chosen grey for it.
    static func isAssigned(_ rawCode: String) -> Bool {
        guard let key = subjectKey(rawCode) else { return false }
        return choice(forKey: key) != .gray
    }

    /// FNV-1a over the letters. Swift's own hashValue changes every launch,
    /// which would repaint a subject each time the app opens.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in text.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Reduces whatever Lectio calls a team to the subject it teaches:
    /// "1j ma" → "ma", "1ij daAB" → "da", "1j fy øv" → "fy", "ENB" → "en".
    /// Class prefixes start with a digit ("1j", "2i"); the level letters glued
    /// on the end ("daAB", "enB") are dropped by keeping the first two letters,
    /// which is how Danish subject abbreviations are written.
    static func subjectKey(_ rawCode: String) -> String? {
        let tokens = rawCode
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .filter { token in
                guard let first = token.first else { return false }
                return !first.isNumber
            }
        guard let token = tokens.first else { return nil }
        let letters = token.lowercased().filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }
        return String(letters.prefix(2))
    }
}

extension Color {
    static func forSubject(_ code: String) -> Color { SubjectPalette.color(for: code) }

    /// The lesson stripe. Measured against its own card in light mode, the bare
    /// system colours were too faint to read as a mark — yellow 1.5:1, teal,
    /// green and orange about 2:1, where a graphic needs 3:1. Mixing in 35% ink
    /// takes every one of them to at least 3.4:1, the same trick Calendar uses
    /// for its yellow. In Dark Mode the system colours already clear 4.3:1
    /// against the dark card, so they're left exactly as Apple ships them.
    static func subjectStripe(_ code: String, in scheme: ColorScheme) -> Color {
        let base = SubjectPalette.color(for: code)
        return scheme == .dark ? base : base.mix(with: .black, by: 0.35)
    }
}

// MARK: - Choosing colours

/// The colours a subject can have: Apple's system colours.
enum SubjectColorChoice: String, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .gray: return .gray
        }
    }

    var name: String { rawValue.capitalized }
}

/// The colours you've picked, per subject ("ma" → blue). Observable, so every
/// card, dot and stripe that asked for a colour redraws the moment you change
/// one — nothing has to be told.
@Observable
final class SubjectColors {
    static let shared = SubjectColors()
    private static let storageKey = "subjectColors"

    private(set) var picked: [String: SubjectColorChoice]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        picked = raw.compactMapValues { SubjectColorChoice(rawValue: $0) }
    }

    /// Nil goes back to the default or automatic colour.
    func set(_ choice: SubjectColorChoice?, for key: String) {
        picked[key] = choice
        UserDefaults.standard.set(picked.mapValues(\.rawValue), forKey: Self.storageKey)
    }
}

/// Plain names for the subject codes Danish gymnasiums use; anything else is
/// shown as its code.
enum SubjectNames {
    private static let names: [String: String] = [
        "da": "Danish", "en": "English", "ma": "Maths", "hi": "History",
        "sa": "Social studies", "nv": "Science (NV)", "fy": "Physics",
        "ke": "Chemistry", "bi": "Biology", "ng": "Natural geography",
        "re": "Religion", "fi": "Philosophy", "id": "Sport", "mu": "Music",
        "bk": "Visual arts", "dr": "Drama", "ty": "German", "fr": "French",
        "sp": "Spanish", "la": "Latin", "ap": "General linguistics (AP)",
        "ol": "Classical studies", "ps": "Psychology", "it": "IT",
        "in": "Informatics", "ge": "Geography", "me": "Media",
        "ki": "Chinese", "ar": "Arabic", "ru": "Russian",
    ]

    static func name(forKey key: String) -> String {
        names[key] ?? key.uppercased()
    }

    /// The name only when the app actually knows the subject.
    static func knownName(forKey key: String) -> String? {
        names[key]
    }
}
