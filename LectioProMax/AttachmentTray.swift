import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

typealias OutgoingAttachment = LectioMessagesService.OutgoingAttachment

/// Photos and files to send with a message: a paperclip button that offers
/// the photo library or Files, and the chosen ones as small chips you can
/// take off again. Nothing is uploaded until the message is sent.
struct AttachmentTray: View {
    @Binding var attachments: [OutgoingAttachment]
    var disabled = false

    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var reading = false
    @State private var problem: String?
    /// Small versions of the photos, made once rather than decoding the
    /// full picture on every redraw.
    @State private var thumbnails: [UUID: UIImage] = [:]

    /// Lectio has its own limit; this keeps a phone from trying to send
    /// something it would refuse anyway.
    private static let maxBytes = 50 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            chip(attachment)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 10) {
                Menu {
                    Button {
                        showingPhotos = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .scaledFont(size: 14, weight: .semibold)
                        Text(attachments.isEmpty ? "Attach" : "Attach more")
                            .scaledFont(size: 15, weight: .semibold)
                    }
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(disabled || reading)

                if reading {
                    ProgressView().controlSize(.small)
                }
                if let problem {
                    Text(problem)
                        .scaledFont(size: 13.5)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItems,
                      maxSelectionCount: 6, matching: .images, photoLibrary: .shared())
        .onChange(of: photoItems) { _, picked in
            guard !picked.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(picked) }
        }
        .fileImporter(isPresented: $showingFiles,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        .animation(.snappy, value: attachments)
    }

    private func chip(_ attachment: OutgoingAttachment) -> some View {
        HStack(spacing: 6) {
            if let image = thumbnails[attachment.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            Text(attachment.filename)
                .scaledFont(size: 13.5, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 16)
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .contentCard(radius: 10)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Reading what was picked

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        reading = true
        problem = nil
        defer { reading = false }

        for (index, item) in items.enumerated() {
            guard let raw = try? await item.loadTransferable(type: Data.self), !raw.isEmpty else {
                problem = "Couldn't read a photo."
                continue
            }
            // Teachers' laptops deal with HEIC badly: send a JPEG.
            let type = item.supportedContentTypes.first
            var data = raw
            var ext = type?.preferredFilenameExtension ?? "jpg"
            var mime = type?.preferredMIMEType ?? "image/jpeg"
            if ["heic", "heif"].contains(ext.lowercased()) || !mime.hasPrefix("image/") {
                if let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    data = jpeg
                    ext = "jpg"
                    mime = "image/jpeg"
                }
            }
            let name = "Photo-\(stamp())\(items.count > 1 ? "-\(index + 1)" : "").\(ext)"
            add(OutgoingAttachment(data: data, filename: name, mimeType: mime))
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        problem = nil
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { problem = error.localizedDescription }
            return
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                problem = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            add(OutgoingAttachment(data: data, filename: url.lastPathComponent, mimeType: mime))
        }
    }

    private func add(_ attachment: OutgoingAttachment) {
        guard attachment.data.count <= Self.maxBytes else {
            problem = "\(attachment.filename) is over 50 MB."
            return
        }
        if attachment.mimeType.hasPrefix("image/"),
           let thumbnail = UIImage(data: attachment.data)?.preparingThumbnail(of: CGSize(width: 78, height: 78)) {
            thumbnails[attachment.id] = thumbnail
        }
        attachments.append(attachment)
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
