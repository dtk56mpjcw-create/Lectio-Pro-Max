import SwiftUI

/// Finds who a message is from in Lectio's people directory, so the row can
/// show their photo.
///
/// The inbox gives only a name — "Julie Skov Nikolajsen (JN)" for a teacher,
/// "Ivan Surov (1j)" for a student — with no id. The directory (the same one
/// New message searches) has "Julie Skov Nikolajsen (JN)" and
/// "Ivan Surov (1j 12)" with ids, and the id is what a photo is fetched by.
/// So: the same name, and the inbox's bracket at the start of the
/// directory's. Two people with one name and nothing to tell them apart get
/// no photo rather than the wrong one.
struct SenderDirectory {
    private var byName: [String: [Recipient]] = [:]

    init(_ people: [Recipient] = []) {
        for person in people where person.kind == .teacher || person.kind == .student {
            byName[Self.split(person.name).name, default: []].append(person)
        }
    }

    var isEmpty: Bool { byName.isEmpty }

    func id(for sender: String) -> String? {
        let wanted = Self.split(sender)
        guard !wanted.name.isEmpty, let candidates = byName[wanted.name] else { return nil }
        if candidates.count == 1 { return candidates[0].id }
        let matching = candidates.filter { Self.split($0.name).bracket.hasPrefix(wanted.bracket) }
        return matching.count == 1 ? matching[0].id : nil
    }

    /// "Ivan Surov (1j 12)" -> ("ivan surov", "1j 12")
    static func split(_ raw: String) -> (name: String, bracket: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") else {
            return (trimmed.lowercased(), "")
        }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces).lowercased()
        let bracket = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces).lowercased()
        return (name, bracket)
    }
}

/// A sender's photo from Lectio, or their initials on a colour of their own
/// until (or unless) there is one.
struct SenderAvatar: View {
    let name: String
    let personID: String?
    var size: CGFloat = 40

    @EnvironmentObject private var session: LectioSession
    @ObservedObject private var photos = PersonPhotos.shared

    private var image: UIImage? {
        guard let personID else { return nil }
        return photos.image(for: personID)
    }

    /// First and last name's first letters: "Julie Skov Nikolajsen (JN)" -> "JN".
    private var initials: String {
        let words = SenderDirectory.split(name).name
            .split(separator: " ")
            .filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first }
            .map { String($0).uppercased() }
        return letters.joined()
    }

    /// The same person always gets the same colour. Yellow is left out: white
    /// letters don't read on it.
    private var colour: Color {
        let palette: [Color] = [.red, .orange, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
        var hash: UInt64 = 5381
        for byte in SenderDirectory.split(name).name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Circle().fill(colour.gradient)
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(.easeOut(duration: 0.2), value: image != nil)
        // Only rows that are on screen ask Lectio for a face.
        .task(id: personID) {
            guard let personID else { return }
            let cookies = await session.requestCookies()
            await photos.load(personID, cookies: cookies)
        }
        .accessibilityHidden(true)
    }
}

/// Threads you've cleared out of the Deleted list. Lectio can't delete for
/// good — it empties that folder itself after three months — so this only
/// hides them in the app.
enum ClearedDeleted {
    private static let key = "messages.clearedDeleted"

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func add(_ new: [String]) {
        var all = ids
        all.formUnion(new)
        UserDefaults.standard.set(Array(all), forKey: key)
    }

    static func remove(_ id: String) {
        var all = ids
        all.remove(id)
        UserDefaults.standard.set(Array(all), forKey: key)
    }
}
