import SwiftUI
import UIKit

/// A piece of a lesson's content as the teacher laid it out (see
/// LessonContentReader): paragraphs with their own line breaks, links you
/// can tap (they open in Safari), bold, italic, crossed out and underlined,
/// list items, pictures, and rows for videos and pages embedded from
/// elsewhere.
struct LessonBlocksView: View {
    let blocks: [LessonContentBlock]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let runs):
                    paragraph(runs)
                case .listItem(let marker, let runs):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker)
                            .scaledFont(size: 16)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        paragraph(runs)
                    }
                case .image(let source, let link):
                    LessonPicture(source: source, link: link)
                case .embed(let link, let title):
                    embedRow(link: link, title: title)
                }
            }
        }
    }

    /// Selectable, the system's way: on iOS 27 a press and hold selects a
    /// word, with handles to widen it; on iOS 26 it offers Copy for the
    /// whole paragraph, which is all SwiftUI does there. Links still open on
    /// a tap.
    private func paragraph(_ runs: [LessonRun]) -> some View {
        Text(Self.attributed(runs))
            .scaledFont(size: 16)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A video, or a page such as Google Slides, embedded in Lectio's page:
    /// a row, like a file's, that opens it where it lives (the YouTube app,
    /// or Safari). A player can't run inside the card.
    private func embedRow(link: String, title: String) -> some View {
        Button {
            if let url = URL(string: link) { openURL(url) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: LessonEmbeds.isVideo(link) ? "play.rectangle.fill" : "globe")
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .scaledFont(size: 15.5, weight: .semibold)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 12.5, weight: .bold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(radius: Metrics.inner)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens it outside the app")
    }

    /// The runs as one string: links tappable (in the accent colour, as the
    /// system draws them), bold, italic, crossed out and underlined as the
    /// teacher set them.
    static func attributed(_ runs: [LessonRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let link = run.link, let url = URL(string: link) { piece.link = url }
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            // Typed, so it's SwiftUI's underline and not UIKit's.
            if run.underline { piece.underlineStyle = Text.LineStyle.single }
            out += piece
        }
        return out
    }
}

/// A picture ready to show, and its file for Quick Look.
struct LoadedPicture {
    let image: UIImage
    let file: URL

    /// Where the files go, all together, so signing out can clear them.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LessonPictures", isDirectory: true)
    }
}

/// A picture in a lesson's content, such as the workbook page a teacher
/// adds for anyone without the book. Lectio's own pictures need the
/// sign-in, so they're fetched with the session's cookies; one pasted into
/// the editor comes as data. Never wider than the card, never blown up past
/// its own size. A tap opens it in Quick Look, to zoom in or save it; a
/// picture that's a link (a video's thumbnail, say) opens the link instead,
/// with a small arrow on it to say so.
struct LessonPicture: View {
    let source: String
    var link: String? = nil

    @Environment(LectioSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var picture: LoadedPicture?
    @State private var failed = false
    @State private var preview: PreviewDocument?

    init(source: String, link: String? = nil) {
        self.source = source
        self.link = link
        _picture = State(initialValue: LessonCache.shared.picture(source))
    }

    var body: some View {
        Group {
            if let picture {
                Button {
                    if let link, let url = URL(string: link) {
                        openURL(url)
                    } else {
                        preview = PreviewDocument(url: picture.file)
                    }
                } label: {
                    Image(uiImage: picture.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: picture.image.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if link != nil {
                                Image(systemName: "arrow.up.right")
                                    .scaledFont(size: 12, weight: .bold)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Circle().fill(.black.opacity(0.55)))
                                    .padding(6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(link == nil ? "Picture" : "Picture, link")
                .accessibilityHint(link == nil ? "Opens it larger" : "Opens it outside the app")
            } else if !failed {
                // No message if it can't be had, by Dan's choice (CLAUDE.md):
                // the space just closes.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 160)
                    .overlay { ProgressView() }
                    .accessibilityLabel("Loading a picture")
            }
        }
        .task(id: source) { await load() }
        .sheet(item: $preview) { document in
            DocumentPreview(url: document.url).ignoresSafeArea()
        }
    }

    private func load() async {
        guard picture == nil else { return }
        if let cached = LessonCache.shared.picture(source) {
            picture = cached
            return
        }
        let cookies = await session.requestCookies()
        guard let loaded = await Self.fetch(source, cookies: cookies) else {
            failed = true
            return
        }
        LessonCache.shared.store(picture: loaded, for: source)
        picture = loaded
    }

    /// The picture, decoded off the main thread, and saved as a file for
    /// Quick Look.
    @concurrent private static func fetch(_ source: String, cookies: [HTTPCookie]) async -> LoadedPicture? {
        guard let data = await bytes(source, cookies: cookies),
              let decoded = UIImage(data: data) else { return nil }
        // At most 1600 px across: a card is never wider than that on any
        // iPhone, and a phone photo at full size is about 48 MB decoded,
        // enough for a few to get the app stopped. Quick Look still opens
        // the file itself, full size, to zoom in.
        let limit: CGFloat = 1600
        let size = decoded.size
        let image: UIImage
        if max(size.width, size.height) > limit {
            let scale = limit / max(size.width, size.height)
            let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            image = await decoded.byPreparingThumbnail(ofSize: target) ?? decoded
        } else {
            image = await decoded.byPreparingForDisplay() ?? decoded
        }

        let folder = LoadedPicture.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Quick Look goes by the file's extension.
        let (written, ext): (Data?, String) = {
            let head = [UInt8](data.prefix(12))
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "png") }
            if head.starts(with: [0xFF, 0xD8]) { return (data, "jpg") }
            if head.starts(with: [0x47, 0x49, 0x46]) { return (data, "gif") }
            return (decoded.pngData(), "png")
        }()
        let file = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        guard let written, (try? written.write(to: file, options: .atomic)) != nil else { return nil }
        return LoadedPicture(image: image, file: file)
    }

    private nonisolated static func bytes(_ source: String, cookies: [HTTPCookie]) async -> Data? {
        // "data:image/png;base64,iVBOR…", pasted straight into the editor.
        if source.lowercased().hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ",") else { return nil }
            let header = source[..<comma].lowercased()
            let payload = String(source[source.index(after: comma)...])
            guard header.contains(";base64") else { return nil }
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        guard let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        if url.host?.lowercased().hasSuffix("lectio.dk") == true {
            // With the sign-in; a signed-out answer throws, and there's no picture.
            guard let (data, http) = try? await LectioHTTP.send(request, via: LectioForms.session, seed: cookies),
                  (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            return data
        }
        // Somewhere else on the web: no Lectio cookies go there.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
        return data
    }
}
