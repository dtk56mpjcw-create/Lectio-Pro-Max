import SwiftUI
import UIKit

// MARK: - Text that follows the reader's text size

/// The app's text is set in exact sizes — 17 for a lesson's name, 13.5 for
/// its details — tuned to sit together. `scaledFont` keeps those sizes at
/// the default text size and grows or shrinks them with the reader's
/// setting (Settings › Accessibility › Display & Text Size), at the same
/// rate as the system's body text. Layout that has to grow with it — the
/// height of a module — uses `TypeScale.factor` too.
enum TypeScale {
    /// How much bigger than the default text is at this size: 1 at Large
    /// (the default), about 1.3 at XXXL, 2.3 at the largest accessibility
    /// size the app allows.
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        table[size] ?? 1
    }

    private static let table: [DynamicTypeSize: CGFloat] = {
        var out: [DynamicTypeSize: CGFloat] = [:]
        let metrics = UIFontMetrics(forTextStyle: .body)
        let base = metrics.scaledValue(for: 100,
                                       compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        for size in DynamicTypeSize.allCases {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            out[size] = metrics.scaledValue(for: 100, compatibleWith: traits) / max(base, 1)
        }
        return out
    }()
}

private struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.system(size: size * TypeScale.factor(dynamicTypeSize), weight: weight, design: design))
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` that follows Dynamic Type.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
