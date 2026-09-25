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
/// The seven go to your main subjects; everything else is grey until it's
/// given one. They are the system colours themselves, never typed-in values, so
/// Dark Mode and Increase Contrast retune them automatically.
enum SubjectPalette {
    private static let assigned: [String: Color] = [
        "da": .red,        // Danish
        "hi": .orange,     // History
        "sa": .yellow,     // Social studies
        "nv": .green,      // Science foundation course
        "ap": .teal,       // AP / Latin
        "la": .teal,
        "ma": .blue,       // Maths
        "en": .purple,     // English
    ]

    static func color(for rawCode: String) -> Color {
        guard let key = subjectKey(rawCode) else { return .gray }
        return assigned[key] ?? .gray
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
}
