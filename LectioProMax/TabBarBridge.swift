import SwiftUI
import UIKit

/// The UIKit tab bar controller under SwiftUI's TabView, for what the
/// search needs that SwiftUI doesn't offer (see SearchTab):
/// - the tab search was pressed on, itself, to keep on screen behind the
///   field (LiveTab);
/// - one tap on the search button opening the field ready to type.
@MainActor
enum TabBarBridge {
    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// The tab bar controller in the app's window, if SwiftUI made one:
    /// among the view controllers, or else the one the tab bar belongs to.
    static func controller() -> UITabBarController? {
        guard let window = keyWindow() else { return nil }
        if let found = find(in: window.rootViewController) { return found }
        for bar in tabBars(in: window) {
            var responder: UIResponder? = bar
            while let current = responder {
                if let tabs = current as? UITabBarController { return tabs }
                responder = current.next
            }
        }
        return nil
    }

    private static func find(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        return find(in: controller.presentedViewController)
    }

    private static func tabBars(in view: UIView) -> [UITabBar] {
        if let bar = view as? UITabBar { return [bar] }
        return view.subviews.flatMap { tabBars(in: $0) }
    }

    /// The view controller showing `tab`, in the order RootView lists the
    /// tabs.
    static func viewController(for tab: AppTab) -> UIViewController? {
        let order: [AppTab] = [.schedule, .homework, .messages, .me, .search]
        guard let tabs = controller(), let index = order.firstIndex(of: tab) else {
            SearchLog.note("no tab bar controller: nothing to keep behind the field")
            return nil
        }
        if index < tabs.tabs.count, let found = tabs.tabs[index].viewController { return found }
        if let all = tabs.viewControllers, index < all.count { return all[index] }
        SearchLog.note("no view controller for \(tab)")
        return nil
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

/// The tab search was pressed on, itself, behind the search field: its own
/// view, moved into the search tab for as long as search is on, working as
/// it does in the tab. Dan wanted what actually happens in the app behind
/// the field, not a picture (29 Sep).
///
/// iOS takes a tab's view off the screen as another tab comes on. Before
/// this, the search tab drew a second copy of the tab (slow to open, and
/// not quite where you were), then a still picture. Here the tab's real
/// view is lent to the search tab: nothing is built again, and it's exactly
/// where you left it, scrolled as far, with the same page open.
///
/// The tab bar controller takes the view back by itself when its tab is
/// chosen again. As iOS had told the tab it went off screen, it's told it's
/// on screen again while it's here (and off again when it goes), so what
/// starts as a screen appears (loading, the search's own bookkeeping) goes
/// on working.
struct LiveTab: UIViewRepresentable {
    let controller: UIViewController?
    /// Only while the search tab is on screen; the rest of the time the view
    /// is the tab's.
    let active: Bool

    func makeUIView(context: Context) -> LiveTabBox {
        LiveTabBox()
    }

    func updateUIView(_ box: LiveTabBox, context: Context) {
        box.wanted = active ? controller : nil
    }

    static func dismantleUIView(_ box: LiveTabBox, coordinator: ()) {
        box.wanted = nil
    }
}

final class LiveTabBox: UIView {
    /// The tab's view controller to show here.
    weak var wanted: UIViewController? {
        didSet { settle() }
    }

    /// The one whose view is here now.
    private weak var shown: UIViewController?
    /// Tries left at taking the view, if iOS hadn't taken it off the screen
    /// yet when the search tab came on.
    private var retries = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground
    }

    required init?(coder: NSCoder) {
        fatalError("not from a storyboard")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        settle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let view = shown?.view, view.superview === self { view.frame = bounds }
    }

    private func settle() {
        // Give back the one here if it's no longer wanted, unless the tab bar
        // controller has taken it back already (then it's been told itself).
        if let current = shown, current !== wanted || window == nil {
            if current.view.superview === self {
                current.beginAppearanceTransition(false, animated: false)
                current.view.removeFromSuperview()
                current.endAppearanceTransition()
                SearchLog.note("gave the tab's view back")
            }
            shown = nil
        }
        // Take the wanted one, only while this box is on screen, and only
        // once iOS has taken it off the screen: the search tab drawing in the
        // background mustn't take it from its own tab.
        guard window != nil, let controller = wanted, shown == nil else { return }
        // Never the search tab's own view, or anything holding this box.
        guard !isDescendant(of: controller.view) else {
            SearchLog.note("asked to take a view this box is in: not taken")
            return
        }
        guard controller.view.window == nil else {
            if retries < 5 {
                retries += 1
                DispatchQueue.main.async { [weak self] in self?.settle() }
            } else {
                SearchLog.note("the tab's view stayed on screen in its tab: not taken")
            }
            return
        }
        retries = 0
        let view: UIView = controller.view
        controller.beginAppearanceTransition(true, animated: false)
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        controller.endAppearanceTransition()
        shown = controller
        SearchLog.note("the tab itself is behind the field")
    }
}
