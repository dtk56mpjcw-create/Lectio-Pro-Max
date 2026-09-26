import SwiftUI
import UIKit

/// Lectio's digital student card, full screen: the photo and details on the
/// card, and the QR code under it. The QR is Lectio's own and changes every
/// 36 seconds, so it's fetched again on that beat for as long as it's open;
/// the screen goes to full brightness so it scans first time.
struct StudentCardScreen: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var card: StudentCard?
    @State private var photo: UIImage?
    @State private var qr: UIImage?
    @State private var qrAt: Date?
    @State private var failed = false
    @State private var savedBrightness: CGFloat?

    private var className: String { session.snapshot.profile.className }

    var body: some View {
        // A navigation bar of its own, so the close button sits in it rather
        // than floating over the card.
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let card {
                        cardView(card)
                        qrView(card)
                    } else if failed {
                        EmptyNotice(icon: "person.text.rectangle", text: "Couldn't load your student card")
                        Button("Try again") { Task { await load() } }
                            .scaledFont(size: 16, weight: .semibold)
                            .frame(minHeight: 44)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background { AppBackground() }
            .navigationTitle("Student card")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
            }
        }
        .task { await load() }
        // A fresh QR for as long as the card is open.
        .task(id: card?.qrURL) {
            guard let card, card.qrURL != nil else { return }
            while !Task.isCancelled {
                await refreshQR(card)
                try? await Task.sleep(for: .seconds(card.qrInterval))
            }
        }
        .onAppear { brighten() }
        .onDisappear { restoreBrightness() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { brighten() } else { restoreBrightness() }
        }
    }

    // MARK: The card

    private func cardView(_ card: StudentCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("STUDENT CARD")
                    .scaledFont(size: 12.5, weight: .heavy)
                    .tracking(1.2)
                Spacer()
                Text(card.school)
                    .scaledFont(size: 13, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Palette.accent.gradient)

            HStack(alignment: .top, spacing: 15) {
                photoView
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.name)
                        .scaledFont(size: 21, weight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                    if !className.isEmpty {
                        fact("Class", className)
                    }
                    if !card.birthday.isEmpty {
                        fact("Born", card.age.isEmpty ? card.birthday : card.birthday + " · " + card.age + " years")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clip first, so the coloured band takes the card's corners.
        .clipShape(RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
        .contentCard(radius: Metrics.card)
    }

    private var photoView: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                    .overlay { Image(systemName: "person.fill").scaledFont(size: 30).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 96, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Photo")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .scaledFont(size: 11, weight: .heavy)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .scaledFont(size: 15.5, weight: .medium)
        }
    }

    // MARK: The QR code

    private func qrView(_ card: StudentCard) -> some View {
        VStack(spacing: 12) {
            ZStack {
                // Always black on white, whatever the theme: that's what scans.
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .transition(.opacity)
                } else if card.qrURL != nil {
                    ProgressView().tint(.black)
                } else {
                    Text("No QR code on this card")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.black.opacity(0.5))
                }
            }
            .frame(width: 240, height: 240)
            .animation(.easeInOut(duration: 0.2), value: qrAt)
            .accessibilityLabel("QR code")

            // Ticking, like Lectio's own stamp, so it's plain this isn't a
            // screenshot.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let live = qrAt.map { context.date.timeIntervalSince($0) < card.qrInterval * 2 + 10 } ?? false
                HStack(spacing: 6) {
                    Circle().fill(live ? Palette.positive : Palette.warning).frame(width: 7, height: 7)
                    Text((live ? "Live from Lectio · " : "Not updated · ")
                         + context.date.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                }
                .scaledFont(size: 13.5, weight: .medium)
                .foregroundStyle(.secondary)
            }
            Text("The code changes every \(Int(card.qrInterval)) seconds.")
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .contentCard(radius: Metrics.card)
    }

    // MARK: Work

    private func load() async {
        failed = false
        let cookies = await session.requestCookies()
        guard let loaded = try? await LectioMeService.loadStudentCard(cookies: cookies),
              !loaded.name.isEmpty else {
            failed = true
            return
        }
        card = loaded
        if let link = loaded.photoURL {
            photo = await LectioMeService.image(link, cookies: cookies)
        }
    }

    private func refreshQR(_ card: StudentCard) async {
        let cookies = await session.requestCookies()
        if let image = await LectioMeService.qrImage(for: card, cookies: cookies) {
            qr = image
            qrAt = Date()
        }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    private func brighten() {
        guard let screen, savedBrightness == nil else { return }
        savedBrightness = screen.brightness
        screen.brightness = 1
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        // Not `screen`: on the way to the background the scene is no longer
        // foreground-active.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.brightness = saved
        savedBrightness = nil
    }
}
