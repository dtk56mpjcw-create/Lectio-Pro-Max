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

    var body: some View {
        Button {
            guard !closing else { return }
            closing = true
            action()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary.opacity(0.72))
                .frame(width: 32, height: 32)
                .contentCard(radius: 16)
        }
        .buttonStyle(PressableCard())
        .allowsHitTesting(!closing)
        .padding(.trailing, Metrics.margin)
        .padding(.top, SheetCloseButton.topInset)
    }
}
