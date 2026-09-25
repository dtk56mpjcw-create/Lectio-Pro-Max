import SwiftUI

// Apple's Liquid Glass rules, applied properly this time:
//   • Glass belongs to the NAVIGATION layer floating above content.
//   • Never put glass on content (lists, rows, cards) — content stays solid.
//   • Never stack glass on glass; glass cannot sample other glass.
//   • Group glass elements in a GlassEffectContainer so they share a
//     sampling region and can morph into one another.

enum Palette {
    // Sampled from the Copenhagen-sunset wallpaper.
    static let apricot = Color(red: 0.95, green: 0.68, blue: 0.45)
    static let ember   = Color(red: 0.90, green: 0.55, blue: 0.42)
    static let dusk    = Color(red: 0.56, green: 0.64, blue: 0.73)
    static let accent  = Color(red: 0.93, green: 0.62, blue: 0.38)
}

enum Metrics {
    static let card: CGFloat = 18
    static let inner: CGFloat = 12
    static let margin: CGFloat = 18
}

/// The content layer's backdrop. Quiet, so the glass above it has something
/// legible to refract without competing with the text.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.06, green: 0.07, blue: 0.09),
                       Color(red: 0.11, green: 0.10, blue: 0.11),
                       Color(red: 0.16, green: 0.13, blue: 0.12)]
                    : [Color(red: 0.95, green: 0.95, blue: 0.97),
                       Color(red: 0.97, green: 0.95, blue: 0.93),
                       Color(red: 0.98, green: 0.92, blue: 0.87)],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { geo in
                Circle()
                    .fill(RadialGradient(
                        colors: [Palette.apricot.opacity(scheme == .dark ? 0.20 : 0.26),
                                 Palette.apricot.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 280))
                    .frame(width: 620, height: 620)
                    .position(x: geo.size.width * 0.82, y: geo.size.height * 0.88)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Content layer (solid — never glass)

/// Content rows are opaque so text stays crisp. Apple's guidance is explicit
/// that lists and cards are content, not navigation chrome.
struct ContentCard: ViewModifier {
    var radius: CGFloat = Metrics.card
    var emphasised: Bool = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(scheme == .dark
                          ? Color.white.opacity(emphasised ? 0.10 : 0.06)
                          : Color.white.opacity(emphasised ? 0.95 : 0.78))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.06),
                                  lineWidth: 0.7)
            }
            // No shadow: a shadow per row is a real cost when dozens are on
            // screen during a swipe, and the border already separates them.
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
                .font(.system(size: 16, weight: .semibold))
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
    var body: some View {
        Circle().fill(Color.forSubject(code)).frame(width: size, height: size)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyNotice: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.primary.opacity(0.4))
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.62))
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
                .font(.system(size: 13))
            Text(text).font(.system(size: 13.5))
            Spacer(minLength: 0)
        }
        .padding(13)
        .contentCard(radius: Metrics.inner)
    }
}

/// Press feedback for content rows (glass controls handle their own).
struct PressableCard: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
