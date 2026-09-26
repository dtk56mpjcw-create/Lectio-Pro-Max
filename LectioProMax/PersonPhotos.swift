import SwiftUI
import UIKit

/// Faces for the people lists.
///
/// Lectio has no "give me this person's photo" URL. Images are addressed by a
/// picture id that appears nowhere in the directories — the only place it's
/// published is the context card, the little popup the website shows when you
/// hover a name:
///
///     /contextcard/contextcard.aspx?searchtype=id&lectiocontextcard=S80637536702
///
/// which comes back with `<img src="GetImage.aspx?pictureid=…">`, or with
/// `/lectio/img/defaultfoto_small.jpg` for anyone who hasn't got one.
///
/// So a face costs two requests, and the school has 1311 students. They're only
/// fetched for rows you actually scroll to, kept in memory for the session and
/// on disk between them, and a person with no photo is remembered so we don't
/// ask again. The thumbnails are about a kilobyte each.
@MainActor
final class PersonPhotos: ObservableObject {
    static let shared = PersonPhotos()

    @Published private(set) var images: [String: UIImage] = [:]

    /// People Lectio has TOLD us it has no photo for. Only an explicit
    /// `defaultfoto` counts: a request that merely failed is retried later.
    /// Treating a failure as "no photo" is what left half the list on initials —
    /// scrolling cancels the in-flight requests for rows leaving the screen, and
    /// every one of those cancellations was being recorded as a missing face.
    private var withoutPhoto: Set<String> = []
    private var inFlight: Set<String> = []

    /// Faces are two requests each, and a flick through 1311 students would
    /// otherwise start hundreds at once and time most of them out.
    private var active = 0
    private let maxActive = 4

    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Renamed with the switch to full-size images: the old folder holds
        // 36x48 thumbnails, and reusing them would keep the blur forever.
        let url = base.appendingPathComponent("LectioPhotos-full", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for id: String) -> UIImage? { images[id] }

    /// For signing out: other people's faces go with the account.
    func clear() {
        images.removeAll()
        withoutPhoto.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    func load(_ id: String, cookies: [HTTPCookie]) async {
        guard images[id] == nil, !withoutPhoto.contains(id), !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let file = folder.appendingPathComponent(id + ".jpg")
        if let data = try? Data(contentsOf: file), let cached = UIImage(data: data) {
            images[id] = cached
            return
        }

        while active >= maxActive {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
        }
        active += 1
        defer { active -= 1 }

        guard let source = await Self.pictureSource(for: id, cookies: cookies) else {
            return          // ask again next time this row comes round
        }
        // Lectio's placeholder is a grey silhouette — our own initials read
        // better, and this is the one answer worth remembering.
        guard !source.lowercased().contains("defaultfoto") else {
            withoutPhoto.insert(id)
            return
        }
        guard let data = await Self.fetch(source, cookies: cookies),
              let image = UIImage(data: data) else { return }

        try? data.write(to: file, options: .atomic)
        images[id] = image
    }

    // MARK: - Lectio

    private nonisolated static func pictureSource(for id: String,
                                                  cookies: [HTTPCookie]) async -> String? {
        var components = URLComponents(string: LectioConfig.base + "/contextcard/contextcard.aspx")
        components?.queryItems = [
            URLQueryItem(name: "searchtype", value: "id"),
            URLQueryItem(name: "lectiocontextcard", value: id),
            URLQueryItem(name: "prevurl", value: ""),
            URLQueryItem(name: "ignoreUnsupportedIdTypes", value: "0"),
        ]
        guard let url = components?.url,
              let data = await fetch(url.absoluteString, cookies: cookies),
              let html = String(data: data, encoding: .utf8) else { return nil }

        guard let image = HTMLDocument.parse(html).all("img").first,
              var src = image.attr("src"), !src.isEmpty else { return nil }

        // The context card points at a 36x48 thumbnail, which is a third of the
        // pixels a 30pt circle needs on a 3x screen — that's why the faces looked
        // smeared. `fullsize=1` is the same picture at 180x240 for about 5 KB,
        // which is sharp in the list and big enough to open.
        if src.contains("GetImage.aspx"), !src.contains("fullsize=") {
            src += (src.contains("?") ? "&" : "?") + "fullsize=1"
        }
        return src.hasPrefix("http") ? src : "https://www.lectio.dk" + src
    }

    private nonisolated static func fetch(_ link: String, cookies: [HTTPCookie]) async -> Data? {
        guard let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(LectioService.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25

        guard let (data, response) = try? await LectioForms.session.data(for: request) else { return nil }
        let http = response as? HTTPURLResponse
        if LectioService.isLoginWall(http?.url) { return nil }
        guard (200..<300).contains(http?.statusCode ?? 0), !data.isEmpty else { return nil }
        return data
    }
}

/// A person's face, or their initials while there isn't one.
struct PersonAvatar: View {
    let target: ScheduleTarget
    var size: CGFloat = 30

    @EnvironmentObject private var session: LectioSession
    @ObservedObject private var photos = PersonPhotos.shared

    private var initials: String {
        let words = target.shortName
            .split(whereSeparator: { $0 == " " })
            .filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first }
            .map(String.init)
        return letters.joined().uppercased()
    }

    @State private var opened = false

    private var image: UIImage? {
        guard let id = target.contextCardID else { return nil }
        return photos.image(for: id)
    }

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color(.tertiarySystemFill))
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Only the rows you actually scroll to ask Lectio for a face.
        .task(id: target.contextCardID) {
            guard let id = target.contextCardID else { return }
            let cookies = await session.requestCookies()
            await photos.load(id, cookies: cookies)
        }
        // Simultaneous, not a plain long press: the avatar sits inside the row's
        // button, and a gesture attached the ordinary way can lose to it.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                guard image != nil else { return }
                opened = true
            }
        )
        .sheet(isPresented: $opened) {
            if let image = image {
                PhotoViewer(image: image, name: target.shortName)
            }
        }
    }
}

/// A face, opened.
///
/// Shown at 200pt rather than full width on purpose: Lectio's largest copy of a
/// photo is 180x240, so filling a phone screen with it would just be a bigger
/// blur. This is about as large as it stays honest.
struct PhotoViewer: View {
    let image: UIImage
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            VStack(spacing: 16) {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(name)
                    .font(.system(size: 19, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.margin)
                Spacer()
            }
            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }
}
