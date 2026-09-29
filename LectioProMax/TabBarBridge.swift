import SwiftUI
import UIKit

/// The UIKit tab bar controller under SwiftUI's TabView, for the two things
/// the search needs that SwiftUI doesn't offer (see SearchTab):
/// - a still picture of the tab on screen, to show behind the search field;
/// - one tap on the search button opening the field ready to type.
@MainActor
enum TabBarBridge {
    /// The tab bar controller in the app's window, if SwiftUI made one.
    static func controller() -> UITabBarController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where window.isKeyWindow {
            if let found = find(in: window.rootViewController) { return found }
        }
        return nil
    }

    private static func find(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    /// A picture of the tab on screen as it is right now, without the tab
    /// bar (that's the controller's own; the picture is of what's in the
    /// tab). Taken the moment search is pressed, before anything changes.
    /// A snapshot view, not a drawn image: it's instant however much is on
    /// the page.
    static func pictureOfSelectedTab() -> UIView? {
        guard let view = controller()?.selectedViewController?.view else {
            SearchLog.note("no tab bar controller found: no picture behind the field")
            return nil
        }
        return view.snapshotView(afterScreenUpdates: false)
    }

    /// iOS 26's own setting for a search tab that opens its field ready to
    /// type (`UISearchTab.automaticallyActivatesSearch`). Without it the
    /// first tap only opened the field and a second one started typing.
    /// Set through the key, and only if this iOS has it, so an iOS without
    /// it just keeps two taps instead of crashing.
    static func searchTabActivatesField() {
        guard let tabs = controller()?.tabs else { return }
        for tab in tabs where tab is UISearchTab {
            guard tab.responds(to: NSSelectorFromString("setAutomaticallyActivatesSearch:")) else {
                SearchLog.note("this iOS has no automaticallyActivatesSearch")
                continue
            }
            tab.setValue(true, forKey: "automaticallyActivatesSearch")
        }
    }
}

/// The picture of the screen search was pressed on, exactly where it was,
/// under the search field (see TabBarBridge.pictureOfSelectedTab). Not
/// touchable: it's a picture; typing is what changes it.
struct StillPicture: UIViewRepresentable {
    let picture: UIView?

    func makeUIView(context: Context) -> PictureBox {
        let box = PictureBox()
        box.backgroundColor = .systemGroupedBackground
        box.isUserInteractionEnabled = false
        return box
    }

    func updateUIView(_ box: PictureBox, context: Context) {
        box.picture = picture
    }
}

/// Holds the picture at its own size in the top left corner, where the
/// screen it was taken of starts.
final class PictureBox: UIView {
    var picture: UIView? {
        didSet {
            guard picture !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let picture { addSubview(picture) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let picture { picture.frame.origin = .zero }
    }
}
