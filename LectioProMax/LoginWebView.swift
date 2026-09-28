import SwiftUI
import WebKit
import UIKit

/// The only WebView in the app. Lectio's login goes through UNI-Login / MitID /
/// the school's Microsoft tenant, which can't be replicated with raw requests —
/// so the user authenticates here once, and every screen afterwards is native.
struct LoginWebView: UIViewRepresentable {

    var onFinished: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // .default() is the persistent store, so the session survives app launches.
        configuration.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Leave the native iOS user-agent here so MitID / the school's Microsoft
        // login render their normal mobile flows.

        if let url = URL(string: LectioConfig.forsideURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    func makeCoordinator() -> Coordinator {
        return Coordinator(onFinished: onFinished)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onFinished: () -> Void
        private var hasFinished = false
        /// Automatic retries after one of Lectio's error pages, so a page
        /// that keeps failing is left for the Reload button rather than
        /// loaded over and over.
        private var retries = 0
        private static let maxRetries = 2

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
        }

        /// Hand off non-web schemes (MitID app, etc.) to the system.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about", scheme != "file" {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasFinished, let url = webView.url else { return }
            let address = url.absoluteString.lowercased()

            // Lectio intermittently fails the UNI-Login callback with
            // "Teknisk fejl under login med MitID eller UniLogin". Retry it
            // ourselves instead of making the user dismiss a dialog and
            // start over by hand.
            webView.evaluateJavaScript("document.body ? document.body.innerText : \"\"") { [weak self] result, _ in
                guard let self = self, !self.hasFinished else { return }
                let text = (result as? String ?? "")

                if text.contains("Teknisk fejl under login"), self.retries < Self.maxRetries {
                    self.retries += 1
                    if let retry = URL(string: LectioConfig.forsideURL) {
                        webView.load(URLRequest(url: retry))
                    }
                    return
                }

                // "Fejl: Der opstod en ukendt fejl" on the way in. Seen when
                // the login page was reached with a sign-in Lectio had given
                // up on — an old key or session, or one being renewed
                // somewhere else at the same moment. Start again without
                // any Lectio cookies: the login then just asks, as it would
                // in a fresh browser. (Other sites' cookies — MitID's —
                // stay, so it still remembers you there.)
                if Self.isLectioError(text), !self.isContentPage(address), self.retries < Self.maxRetries {
                    self.retries += 1
                    Self.forgetLectioCookies {
                        if let retry = URL(string: LectioConfig.forsideURL) {
                            webView.load(URLRequest(url: retry))
                        }
                    }
                    return
                }

                // Only a real content page counts as signed in. Intermediate
                // callback URLs are still part of the handshake — dismissing
                // there is what broke the flow.
                guard address.contains("lectio.dk"),
                      !LectioService.isLoginWall(url),
                      self.isContentPage(address) else { return }

                self.hasFinished = true
                self.onFinished()
            }
        }

        /// Lectio's own error page or dialog.
        static func isLectioError(_ text: String) -> Bool {
            text.contains("Der opstod en ukendt fejl") || text.contains("Der opstod en fejl")
        }

        /// Every lectio.dk cookie out of WebKit's store, then `done`.
        private static func forgetLectioCookies(then done: @escaping () -> Void) {
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { all in
                let lectio = all.filter { $0.domain.lowercased().contains("lectio.dk") }
                let group = DispatchGroup()
                for cookie in lectio {
                    group.enter()
                    store.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main, execute: done)
            }
        }

        /// A landed-on, logged-in Lectio page (not a redirect step).
        private func isContentPage(_ address: String) -> Bool {
            return address.contains("forside.aspx")
                || address.contains("skemany.aspx")
                || address.contains("default.aspx")
                || address.contains("opgaverelev.aspx")
        }
    }
}
