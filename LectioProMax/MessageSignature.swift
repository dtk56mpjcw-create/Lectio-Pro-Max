import SwiftUI

/// A line added under the messages you send, like Lectio+'s "Sendt fra
/// Lectio+". Lectio has no signatures of its own: Lectio+ simply puts the
/// text at the end of the message before sending it, and so does this, so
/// whoever reads it sees it as the last line of the message.
enum MessageSignature {
    static let enabledKey = "signature.enabled"
    static let textKey = "signature.text"
    static let suggested = "Sendt fra Lectio Pro Max"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var text: String {
        UserDefaults.standard.string(forKey: textKey) ?? suggested
    }

    /// The signature that will be added, or nil when it's off or empty.
    static var active: String? {
        guard isEnabled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The message as it's sent: the text, an empty line, the signature.
    /// Just the signature when there's no text (a photo on its own) —
    /// not two empty lines above it.
    static func apply(to body: String, include: Bool = true) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard include, let signature = active else { return trimmed }
        return trimmed.isEmpty ? signature : trimmed + "\n\n" + signature
    }
}

// MARK: - Under the composers

/// Shows the signature under a message being written, so nothing is added
/// that you can't see. The button leaves it off this one message.
struct SignatureFooter: View {
    @Binding var include: Bool
    @AppStorage(MessageSignature.enabledKey) private var enabled = true
    @AppStorage(MessageSignature.textKey) private var text = MessageSignature.suggested

    private var signature: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if enabled && !signature.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "signature")
                    .scaledFont(size: 13, weight: .semibold)
                Text(signature)
                    .scaledFont(size: 14, weight: .medium)
                    .strikethrough(!include)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { include.toggle() }
                } label: {
                    Image(systemName: include ? "xmark.circle.fill" : "plus.circle.fill")
                        .scaledFont(size: 17)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -12)
                .accessibilityLabel(include ? "Leave signature off this message" : "Add signature")
            }
            .foregroundStyle(.secondary)
            .opacity(include ? 1 : 0.6)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - More → Signature

struct SignatureScreen: View {
    @AppStorage(MessageSignature.enabledKey) private var enabled = true
    @AppStorage(MessageSignature.textKey) private var text = MessageSignature.suggested

    private var signature: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signature")
                        .scaledFont(size: 26, weight: .bold)
                    FindableText("A line added under every message and reply you send from the app. It's part of the message, so it's what people see in Lectio too.")
                        .scaledFont(size: 15)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    Toggle(isOn: $enabled.animation(.snappy)) {
                        HStack(spacing: 13) {
                            Image(systemName: "signature")
                                .scaledFont(size: 15.5, weight: .semibold)
                                .frame(width: 22)
                            Text("Add a signature")
                                .scaledFont(size: 16.5, weight: .medium)
                        }
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 11)

                    if enabled {
                        Divider().padding(.leading, 17)
                        TextField("Signature", text: $text, axis: .vertical)
                            .scaledFont(size: 16.5)
                            .lineLimit(1...4)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 15)
                    }
                }
                .contentCard()

                if enabled && text != MessageSignature.suggested {
                    Button("Use “\(MessageSignature.suggested)”") {
                        withAnimation(.snappy) { text = MessageSignature.suggested }
                    }
                    .scaledFont(size: 15, weight: .semibold)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
                }

                if enabled && !signature.isEmpty {
                    preview
                }
            }
            .findScroller()
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { AppBackground() }
        .sensoryFeedback(.selection, trigger: enabled)
        // Its words can be found with the search field (see PageFind).
        .findsOnPage()
    }

    /// A message the way it arrives.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREVIEW")
                .scaledFont(size: 13, weight: .heavy)
                .tracking(0.7)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Hej, jeg har sendt afleveringen nu.")
                Text(" ")
                Text(signature).foregroundStyle(.secondary)
            }
            .scaledFont(size: 16)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner + 3)
        }
    }
}
