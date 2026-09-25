import SwiftUI

/// Deliberately single-tone. Subjects differ only by *shade* of one warm
/// neutral hue, never by hue — that's what keeps the interface reading as
/// clear and calm rather than a scatter of competing colours.
enum SubjectPalette {
    private static let hue: Double = 0.075        // warm sand
    private static let saturation: Double = 0.26

    static func color(for rawCode: String) -> Color {
        let lower = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return Color(hue: hue, saturation: 0.10, brightness: 0.68) }
        var hash: UInt64 = 5381
        for s in lower.unicodeScalars { hash = (hash &* 33) &+ UInt64(s.value) }
        let step = Double(hash % 5)               // 5 shades of the same hue
        let brightness = 0.62 + step * 0.075
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

extension Color {
    static func forSubject(_ code: String) -> Color { SubjectPalette.color(for: code) }
}
