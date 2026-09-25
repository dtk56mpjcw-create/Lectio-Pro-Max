import SwiftUI

/// Pull-to-refresh built by hand, because `.refreshable` on these plain
/// ScrollViews showed its spinner without reliably running its action.
///
/// A zero-height sentinel sits at the top of the scroll content and measures how
/// far the content has been dragged past its own top. Past a threshold it arms,
/// and it fires on release — the same feel as the system control, but it can't
/// be swallowed by another gesture and it always calls what it says it calls.
struct RefreshHeader: View {
    let space: String
    let action: () async -> Void

    @State private var busy = false
    @State private var armed = false

    private let threshold: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            let pull = geometry.frame(in: .named(space)).minY

            Color.clear
                .onChange(of: pull) { _, value in
                    guard !busy else { return }
                    if value > threshold {
                        armed = true
                    } else if armed && value < threshold * 0.45 {
                        // Fired on release, not on crossing, so flicking past
                        // the top doesn't trigger it.
                        armed = false
                        busy = true
                        Task {
                            await action()
                            busy = false
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .offset(y: 12)
                    } else if pull > 12 {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(min(Double(pull / threshold), 1))
                            .offset(y: 12)
                    }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: busy)
        }
        .frame(height: 0)
    }
}
