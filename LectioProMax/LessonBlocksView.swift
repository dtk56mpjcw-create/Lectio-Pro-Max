import SwiftUI
import UIKit

/// A piece of a lesson's content as the teacher laid it out (see
/// LessonContentReader): paragraphs with their own line breaks, links you
/// can tap (they open in Safari), bold and italic, list items, and pictures.
struct LessonBlocksView: View {
    let blocks: [LessonBlock]

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
                case .image(let source):
                    LessonPicture(source: source)
                }
            }
        }
    }

    private func paragraph(_ runs: [LessonRun]) -> some View {
        Text(Self.attributed(runs))
            .scaledFont(size: 16)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The runs as one string: links tappable (in the accent colour, as the
    /// system draws them), bold and italic as the teacher set them.
    static func attributed(_ runs: [LessonRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let link = run.link, let url = URL(string: link) { piece.link = url }
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            out += piece
        }
        return out
    }
}

/// A picture ready to show, and its file for Quick Look.
struct LoadedPicture {
    let image: UIImage
    let file: URL
}

/// A picture in a lesson's content, such as the workbook page a teacher
/// adds for anyone without the book. Lectio's own pictures need the
/// sign-in, so they're fetched with the session's cookies; one pasted into
/// the editor comes as data. Never wider than the card, never blown up past
/// its own size. A tap opens it in Quick Look, to zoom in or save it.
struct LessonPicture: View {
    let source: String

    @Environment(LectioSession.self) private var session
    @State private var picture: LoadedPicture?
    @State private var failed = false
    @State private var preview: PreviewDocument?

    init(source: String) {
        self.source = source
        _picture = State(initialValue: LessonCache.shared.picture(source))
    }

    var body: some View {
        Group {
            if let picture {
                Button {
                    preview = PreviewDocument(url: picture.file)
                } label: {
                    Image(uiImage: picture.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: picture.image.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Picture")
                .accessibilityHint("Opens it larger")
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
        let image = await decoded.byPreparingForDisplay() ?? decoded

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LessonPictures", isDirectory: true)
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
