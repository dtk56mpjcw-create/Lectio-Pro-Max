import SwiftUI

/// A school on Lectio: the number that sits in every one of its Lectio
/// addresses (/lectio/21/…), and its name.
struct LectioSchool: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Lectio's own public list of schools — the page its login starts from.
enum LectioSchools {
    static let listURL = "https://www.lectio.dk/lectio/login_list.aspx"

    static func load() async throws -> [LectioSchool] {
        guard let url = URL(string: listURL) else { throw LectioError.badURL }
        var request = URLRequest(url: url)
        request.setValue(LectioConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("da,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LectioError.badResponse(http.statusCode)
        }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(html)
    }

    /// Each school is `<a href="/lectio/<number>/default.aspx">Name</a>`.
    static func parse(_ html: String) -> [LectioSchool] {
        let root = HTMLDocument.parse(html)
        var seen = Set<String>()
        var schools: [LectioSchool] = []
        for anchor in root.all("a") {
            guard let href = anchor.attr("href"),
                  let g = Rx.match("^/lectio/(\\d+)/default\\.aspx$", href) else { continue }
            let name = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(g[1]).inserted else { continue }
            schools.append(LectioSchool(id: g[1], name: name))
        }
        return schools.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The first step of signing in: which school. Searchable, like Lectio's own
/// list, which the app reads so a new school turns up without an update.
struct SchoolPicker: View {
    var onPick: (LectioSchool) -> Void

    @State private var schools: [LectioSchool] = []
    @State private var failed = false
    @State private var query = ""

    private var filtered: [LectioSchool] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return schools }
        return schools.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("Couldn't reach Lectio", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if schools.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { school in
                    Button {
                        onPick(school)
                    } label: {
                        HStack {
                            Text(school.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if LectioConfig.hasChosenSchool && school.id == LectioConfig.schoolID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search schools")
        .navigationTitle("Your school")
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            schools = try await LectioSchools.load()
            failed = schools.isEmpty
        } catch {
            failed = true
        }
    }
}
