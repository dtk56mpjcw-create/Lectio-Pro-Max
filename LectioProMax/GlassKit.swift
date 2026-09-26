import SwiftUI

// Apple's Liquid Glass rules, applied properly this time:
//   • Glass belongs to the NAVIGATION layer floating above content.
//   • Never put glass on content (lists, rows, cards) — content stays solid.
//   • Never stack glass on glass; glass cannot sample other glass.
//   • Group glass elements in a GlassEffectContainer so they share a
//     sampling region and can morph into one another.

/// Colours come from the system, not from us.
///
/// This used to be a hand-picked "Copenhagen sunset": a peach gradient, an
/// orange glow in the corner, an apricot accent and beige subjects. Every one of
/// those was a fixed value, so none of them adapted to Dark Mode or Increase
/// Contrast, and together they are exactly the warm-gradient look that reads as
/// generated rather than native. Apple's own apps use the system's semantic
/// colours, which the OS retunes per release, per appearance and per
/// accessibility setting — so that is all this app uses now.
enum Palette {
    /// The app's one accent. Follows the AccentColor asset, which is set to the
    /// system blue: change it there and every button, tab and tick follows.
    static var accent: Color { .accentColor }
    /// Destructive and failure states — Sign out, Delete. Apple uses system red.
    static var ember: Color { .red }

    // Status colours for TEXT. The system orange, green and red are made for
    // fills and icons: as small text on a white card they measure about
    // 2.2:1, 2.2:1 and 3.6:1 — hard to read outdoors. In light mode these are
    // the same hues taken darker (about 4.8:1, 5.0:1 and 5.5:1); in dark mode
    // the system colours already read well and are used as they are.

    /// "Changed", "Due in 2 hours", "2 to explain".
    static let warning = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemOrange
            : UIColor(red: 0.70, green: 0.35, blue: 0.0, alpha: 1)
    })

    /// "Handed in", "Saved".
    static let positive = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGreen
            : UIColor(red: 0.12, green: 0.50, blue: 0.22, alpha: 1)
    })

    /// "Cancelled", "2 days late".
    static let negative = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemRed
            : UIColor(red: 0.80, green: 0.13, blue: 0.13, alpha: 1)
    })
}

enum Metrics {
    static let card: CGFloat = 18
    static let inner: CGFloat = 12
    static let margin: CGFloat = 18
}

/// The screen behind the content: Apple's grouped background, the same light
/// grey (black in Dark Mode) that Settings, Health and Calendar's lists sit on.
/// No gradient, no glow.
struct AppBackground: View {
    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
}

// MARK: - Content layer (solid — never glass)

/// Content rows are opaque so text stays crisp. Apple's guidance is explicit
/// that lists and cards are content, not navigation chrome.
///
/// A card is Apple's grouped cell colour on the grouped background: white on
/// light grey, dark grey on black. No translucency and no hairline border —
/// the contrast between the two system colours is the separation, exactly as
/// in Settings.
struct ContentCard: ViewModifier {
    var radius: CGFloat = Metrics.card
    var emphasised: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
    }
}

extension View {
    func contentCard(radius: CGFloat = Metrics.card, emphasised: Bool = false) -> some View {
        modifier(ContentCard(radius: radius, emphasised: emphasised))
    }
}

// MARK: - Navigation layer (real Liquid Glass)

/// A floating control: genuine Liquid Glass, interactive so it illuminates and
/// flexes under the finger the way Apple's own controls do.
struct GlassCircleButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

// MARK: - Shared small pieces

struct SubjectDot: View {
    let code: String
    var size: CGFloat = 8
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // Same ink-mixed colour as the lesson stripe, so a yellow dot is
        // actually visible on a white card.
        Circle().fill(Color.subjectStripe(code, in: scheme)).frame(width: size, height: size)
    }
}


struct EmptyNotice: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 30, weight: .light)
                .foregroundStyle(.tertiary)
            Text(text)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.ember)
                .scaledFont(size: 13)
            Text(text).scaledFont(size: 13.5)
            Spacer(minLength: 0)
        }
        .padding(13)
        .contentCard(radius: Metrics.inner)
    }
}

/// Press feedback for content rows (glass controls handle their own).
struct PressableCard: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableCardBody(configuration: configuration)
    }
}

/// With Reduce Motion on, a press dims instead of shrinking — Apple's advice
/// is to swap movement for a fade rather than drop the feedback.
private struct PressableCardBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
