import SwiftUI
import UIKit

/// The editing state of the Elevfeedback text view.
///
/// Not a `@MainActor` class on purpose: UIKit's delegate callbacks come in
/// synchronously and calling into an actor-isolated object from there is a
/// compile-time fight for no benefit — every one of these methods already runs
/// on the main thread because UIKit only ever calls them there.
final class FeedbackEditor: ObservableObject {
    /// The live text view. Weak: the view's lifetime belongs to SwiftUI.
    weak var view: UITextView?

    /// The document, owned here rather than by the SwiftUI view.
    ///
    /// SwiftUI rebuilds the text view whenever the branch it sits in changes —
    /// which happens on every save, because the saved state feeds the same
    /// if/else chain. A rebuilt view used to be re-seeded from the sheet's
    /// original `initial`, so the editor could silently revert to the text as it
    /// was when the sheet opened while the save path still had the newer copy.
    /// Keeping the document here means a rebuild restores exactly what is on
    /// screen, and there is only ever one version of it.
    private(set) var document = NSAttributedString()

    enum Trait { case bold, italic, underline, strike }

    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var strike = false
    @Published var list: String?
    /// Bumped on every edit, so the draft save can watch one value.
    @Published var revision = 0

    var hasEdits: Bool { revision > 0 }

    /// What would be sent to Lectio right now.
    var html: String {
        let text = view?.attributedText ?? document
        return FeedbackHTML.html(from: text)
    }

    var isBlank: Bool {
        let text = view?.attributedText?.string ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Formatting

    func toggle(_ trait: Trait) {
        guard let view = view else { return }
        let selection = view.selectedRange
        let storage = view.textStorage

        if selection.length == 0 {
            var attrs = view.typingAttributes
            set(trait, in: &attrs, on: !isOn(trait, attrs))
            view.typingAttributes = attrs
            refresh()
            return
        }

        guard selection.location < storage.length else { return }
        let turnOn = !isOn(trait, storage.attributes(at: selection.location, effectiveRange: nil))

        storage.beginEditing()
        storage.enumerateAttributes(in: selection, options: []) { attrs, sub, _ in
            var updated = attrs
            self.set(trait, in: &updated, on: turnOn)
            storage.setAttributes(updated, range: sub)
        }
        storage.endEditing()

        touched()
    }

    /// Turns the caret's paragraph into a list item, or back into a paragraph.
    ///
    /// The "• " is inserted as real characters carrying `.feedbackMarker`, so the
    /// editor visibly looks like a list. The serialiser drops those characters —
    /// `<ul>` and `<ol>` draw their own markers, so sending ours would double them.
    func toggleList(_ kind: String) {
        guard let view = view else { return }
        let storage = view.textStorage

        // An empty document has no paragraph to mark, so give it one.
        if storage.length == 0 {
            storage.append(NSAttributedString(string: " ",
                                              attributes: FeedbackHTML.baseAttributes()))
        }

        let caret = min(max(view.selectedRange.location, 0), storage.length - 1)
        let paragraph = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: caret, length: 0))
        let existing = storage.attribute(.feedbackList,
                                        at: paragraph.location,
                                        effectiveRange: nil) as? String

        storage.beginEditing()

        // Strip the marker that's there now, whichever kind it was.
        var markerLength = 0
        var probe = paragraph.location
        while probe < paragraph.location + paragraph.length,
              storage.attribute(.feedbackMarker, at: probe, effectiveRange: nil) != nil {
            markerLength += 1
            probe += 1
        }
        if markerLength > 0 {
            storage.deleteCharacters(in: NSRange(location: paragraph.location, length: markerLength))
        }

        let start = min(paragraph.location, storage.length)

        if existing == kind {
            let plain = (storage.string as NSString)
                .paragraphRange(for: NSRange(location: min(start, max(storage.length - 1, 0)), length: 0))
            storage.removeAttribute(.feedbackList, range: plain)
        } else {
            var attrs = start < storage.length
                ? storage.attributes(at: start, effectiveRange: nil)
                : FeedbackHTML.baseAttributes()
            attrs[.feedbackMarker] = true
            attrs[.feedbackList] = kind
            attrs[.foregroundColor] = UIColor.secondaryLabel
            let marker = (kind == "ol") ? "1. " : "• "
            storage.insert(NSAttributedString(string: marker, attributes: attrs), at: start)

            let widened = (storage.string as NSString)
                .paragraphRange(for: NSRange(location: start, length: 0))
            storage.addAttribute(.feedbackList, value: kind, range: widened)
            view.selectedRange = NSRange(location: min(start + marker.count, storage.length), length: 0)
        }

        storage.endEditing()
        touched()
    }

    /// Drops a file anchor in at the caret.
    func insert(html fragment: String) {
        guard let view = view, !fragment.isEmpty else { return }
        let piece = FeedbackHTML.attributed(from: fragment)
        guard piece.length > 0 else { return }

        let storage = view.textStorage
        let at = min(view.selectedRange.location, storage.length)
        storage.beginEditing()
        storage.insert(piece, at: at)
        storage.endEditing()
        view.selectedRange = NSRange(location: min(at + piece.length, storage.length), length: 0)
        touched()
    }

    /// Replaces the whole document with what Lectio actually stored.
    ///
    /// Called after every save. Lectio rewrites what it is given — it turns the
    /// first block into `<h1>` and mints a fresh id for it every time it doesn't
    /// recognise one — so an editor that keeps its own copy drifts a little
    /// further from the server with each save, and anything that goes wrong
    /// compounds instead of being corrected. Re-seeding makes the document on
    /// screen the server's document again, so the next save starts from truth.
    func reseed(_ text: NSAttributedString) {
        guard let view = view else { return }
        let storage = view.textStorage
        storage.beginEditing()
        storage.setAttributedString(text)
        storage.endEditing()
        view.selectedRange = NSRange(location: text.length, length: 0)
        document = text
        revision = 0
        refresh()
    }

    // MARK: - State

    func refresh() {
        guard let view = view else { return }
        let storage = view.textStorage
        let selection = view.selectedRange

        let attrs: [NSAttributedString.Key: Any]
        if selection.length > 0, selection.location < storage.length {
            attrs = storage.attributes(at: selection.location, effectiveRange: nil)
        } else {
            attrs = view.typingAttributes
        }
        bold = isOn(.bold, attrs)
        italic = isOn(.italic, attrs)
        underline = isOn(.underline, attrs)
        strike = isOn(.strike, attrs)

        if storage.length > 0 {
            let caret = min(max(selection.location, 0), storage.length - 1)
            let paragraph = (storage.string as NSString)
                .paragraphRange(for: NSRange(location: caret, length: 0))
            list = storage.attribute(.feedbackList,
                                     at: paragraph.location,
                                     effectiveRange: nil) as? String
        } else {
            list = nil
        }
    }

    func touched() {
        capture()
        revision += 1
        refresh()
    }

    /// Records the document a freshly built text view started from, without
    /// counting it as an edit.
    func adopt(_ text: NSAttributedString) {
        document = text
    }

    /// Keeps `document` in step with the view after every change.
    private func capture() {
        if let current = view?.attributedText {
            document = current
        }
    }

    // MARK: - Trait plumbing

    private func isOn(_ trait: Trait, _ attrs: [NSAttributedString.Key: Any]) -> Bool {
        switch trait {
        case .bold:
            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            return traits.contains(.traitBold)
        case .italic:
            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            return traits.contains(.traitItalic)
        case .underline:
            return ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        case .strike:
            return ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        }
    }

    private func set(_ trait: Trait,
                     in attrs: inout [NSAttributedString.Key: Any],
                     on: Bool) {
        switch trait {
        case .bold, .italic:
            let font = (attrs[.font] as? UIFont) ?? FeedbackHTML.bodyFont
            var traits = font.fontDescriptor.symbolicTraits
            let flag: UIFontDescriptor.SymbolicTraits = (trait == .bold) ? .traitBold : .traitItalic
            if on { traits.insert(flag) } else { traits.remove(flag) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                attrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            } else {
                attrs[.font] = UIFont.systemFont(ofSize: font.pointSize)
            }
        case .underline:
            if on {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attrs.removeValue(forKey: .underlineStyle)
            }
        case .strike:
            if on {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attrs.removeValue(forKey: .strikethroughStyle)
            }
        }
    }
}

/// The text view itself. `isScrollEnabled` is off so it grows inside the sheet's
/// own scroll view rather than trapping a second scroller inside the first.
struct FeedbackTextView: UIViewRepresentable {
    let editor: FeedbackEditor
    let initial: NSAttributedString

    /// The document the editor is holding, or the freshly loaded one the first
    /// time round. Never `initial` on a rebuild — that would put the text back
    /// to how it was when the sheet opened.
    private var startingText: NSAttributedString {
        return editor.document.length > 0 ? editor.document : initial
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.attributedText = startingText
        view.typingAttributes = FeedbackHTML.baseAttributes()
        view.autocorrectionType = .yes
        view.smartQuotesType = .no        // straight quotes survive the HTML better
        view.smartDashesType = .no
        view.delegate = context.coordinator
        // Take the width it's given rather than asking for its longest line.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editor.view = view
        editor.adopt(startingText)
        DispatchQueue.main.async { editor.refresh() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        editor.view = view
    }

    /// As tall as the text is at the width on offer. Without this, a text
    /// view that doesn't scroll asks for the width of its longest paragraph
    /// on one line: fine for a sentence, but a long answer came out as lines
    /// running off both sides of the screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let editor: FeedbackEditor
        init(editor: FeedbackEditor) { self.editor = editor }

        func textViewDidChange(_ textView: UITextView) {
            // A new line makes it taller: measure again.
            textView.invalidateIntrinsicContentSize()
            editor.touched()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            editor.refresh()
        }
    }
}

/// What you typed, kept on the phone until Lectio actually has it. Losing a
/// paragraph because the app was swiped away would be worse than any bug here.
enum FeedbackDrafts {
    private static let key = "lectio.feedbackDrafts"

    private static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func draft(for lesson: String) -> String? {
        let saved = all[lesson]
        return (saved?.isEmpty ?? true) ? nil : saved
    }

    static func save(_ html: String, for lesson: String) {
        var current = all
        current[lesson] = html
        all = current
    }

    static func clear(for lesson: String) {
        var current = all
        current[lesson] = nil
        all = current
    }
}
