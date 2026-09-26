import SwiftUI

/// The close button every sheet in the app uses.
///
/// Two things it has to get right, both learned the hard way.
///
/// **Where it sits.** Each tab's header puts its own controls in the top-right —
/// search, add, week overview — and a sheet's top-right is only a few points
/// below them, so the X landed directly on top of the week overview button. iOS
/// gives the first tap outside a presented sheet to dismissing that sheet, so a
/// tap aimed at the button under the X did nothing visible and the button read as
/// broken. The fix isn't clever hit-testing, it's not putting two buttons in the
/// same place: this one sits low enough to clear them.
///
/// **When it stops listening.** Once tapped it takes no further touches, so a
/// second press arriving during the dismissal animation falls through to whatever
/// is underneath instead of being swallowed by a button on its way out.
struct SheetCloseButton: View {
    var action: () -> Void

    /// Far enough down to clear the tab headers' own buttons underneath.
    static let topInset: CGFloat = 52
    /// What a sheet's content needs at the top so it starts below the button.
    static let contentInset: CGFloat = 92

    @State private var closing = false
    /// Pushed onto a stack, the system back button does this job.
    @Environment(\.pushedScreen) private var pushed

    /// The circle you see is 32 points, but the target your finger has to hit
    /// is 44 — Apple's minimum. At 32 a tap landing just off the circle did
    /// nothing, which read as the button not working every time.
    private static let visible: CGFloat = 32
    private static let target: CGFloat = 44
    private static let slack = (target - visible) / 2

    var body: some View {
        if !pushed { button }
    }

    private var button: some View {
        Button {
            guard !closing else { return }
            closing = true
            action()
            // If the sheet didn't go (something refused the dismissal), the
            // button must not stay dead: listen again after a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { closing = false }
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(.secondary)
                .frame(width: Self.visible, height: Self.visible)
                .contentCard(radius: Self.visible / 2)
                .frame(width: Self.target, height: Self.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableCard())
        .allowsHitTesting(!closing)
        .accessibilityLabel("Close")
        // Same place on screen as before; the extra target spreads around it.
        .padding(.trailing, Metrics.margin - Self.slack)
        .padding(.top, SheetCloseButton.topInset - Self.slack)
    }
}
