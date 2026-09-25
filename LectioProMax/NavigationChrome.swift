import SwiftUI

extension EnvironmentValues {
    /// True when a view that doubles as a sheet has been pushed onto a
    /// navigation stack instead. The system back button then replaces the
    /// sheet's close button, and the room left at the top for that button
    /// isn't needed.
    @Entry var pushedScreen: Bool = false
}

extension View {
    /// Shows one of the app's sheet views as a pushed screen: no close
    /// button, no sheet spacing, and a compact bar so its own large title
    /// stays the heading.
    func asPushedScreen() -> some View {
        self
            .environment(\.pushedScreen, true)
            .toolbarTitleDisplayMode(.inline)
    }

    /// The gap a sheet's title leaves for the close button — none when the
    /// view is pushed.
    func sheetTitleSpacing() -> some View {
        modifier(SheetTitleSpacing())
    }
}

private struct SheetTitleSpacing: ViewModifier {
    @Environment(\.pushedScreen) private var pushed

    func body(content: Content) -> some View {
        content
            .padding(.top, pushed ? 0 : 34)
            .padding(.trailing, pushed ? 0 : 44)
    }
}
