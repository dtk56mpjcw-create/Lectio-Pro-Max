import SwiftUI

struct NewMessageSheet: View {
    @EnvironmentObject private var session: LectioSession
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chosen: [Recipient] = []
    @State private var subject = ""
    @State private var body_ = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var sent = false
    @State private var loadingDirectory = false

    private var matches: [Recipient] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let chosenIDs = Set(chosen.map { $0.id })
        return session.recipients
            .filter { !chosenIDs.contains($0.id) && $0.name.localizedCaseInsensitiveContains(trimmed) }
            .prefix(25)
            .map { $0 }
    }

    private var canSend: Bool {
        return !chosen.isEmpty
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("New message")
                        .font(.system(size: 26, weight: .bold))
                        .padding(.top, 34)
                        .padding(.trailing, 44)

                    recipientSection
                    field("Subject", text: $subject, lines: 1...2)
                    field("Message", text: $body_, lines: 6...14)

                    if sent {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Sent").font(.system(size: 15.5, weight: .semibold))
                        }
                    }

                    sendButton
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)

            SheetCloseButton { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        // Always a sheet — even when it opens from a pushed page, whose
        // "pushed" flag would otherwise carry in and hide the close button.
        .environment(\.pushedScreen, false)
        .task {
            loadingDirectory = session.recipients.isEmpty
            await session.loadRecipients()
            loadingDirectory = false
        }
    }

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("To")
                .font(.system(size: 13, weight: .heavy))
                .tracking(0.7)
                .foregroundStyle(.secondary)

            if !chosen.isEmpty {
                VStack(spacing: 7) {
                    ForEach(chosen) { person in
                        HStack(spacing: 8) {
                            Image(systemName: person.kind.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                            Text(person.name)
                                .font(.system(size: 15, weight: .medium))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Button {
                                chosen.removeAll { $0.id == person.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard(radius: Metrics.inner)
                    }
                }
            }

            TextField(loadingDirectory ? "Loading people…" : "Search teachers, students, classes",
                      text: $query)
                .font(.system(size: 16))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(loadingDirectory)

            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { person in
                        Button {
                            chosen.append(person)
                            query = ""
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: person.kind.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(person.name)
                                    .font(.system(size: 15))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(person.kind.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(radius: Metrics.inner)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, lines: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(.system(size: 13, weight: .heavy))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            TextField(label, text: text, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(lines)
                .padding(13)
                .contentCard(radius: Metrics.inner)
                .disabled(sending)
        }
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            HStack(spacing: 9) {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold))
                }
                Text(sending ? "Sending…" : "Send message")
                    .font(.system(size: 16.5, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.accent)
            .padding(15)
            .frame(maxWidth: .infinity)
            .contentCard(radius: Metrics.inner + 2)
        }
        .buttonStyle(PressableCard())
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.45)
    }

    private func send() async {
        guard canSend else { return }
        sending = true
        sendError = nil
        sent = false

        let cookies = await session.requestCookies()
        do {
            let ok = try await LectioMessagesService.createThread(
                to: chosen,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body_,
                cookies: cookies)
            if ok {
                sent = true
                subject = ""
                body_ = ""
                chosen = []
                await session.loadInbox(force: true)
            } else {
                sendError = "Lectio didn't confirm the message was sent — check in Lectio before resending."
            }
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }
}
