import SwiftUI
import PhotosUI
import UIKit

/// Your profile on this server (draft/metadata-2): display name, pronouns,
/// avatar, homepage and status. Metadata lives per network, so each server has
/// its own. Saved on the device and published on every connect where the
/// server supports it.
struct ProfileView: View {
    let server: ServerConfig
    @Environment(ClientStore.self) private var store
    @Environment(UploaderSettings.self) private var uploader
    @Environment(\.dismiss) private var dismiss

    @State private var session: IRCSession?
    @State private var fields: [String: String] = [:]
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                field("display-name", "Display name", placeholder: "How you'd like to be called")
                field("pronouns", "Pronouns", placeholder: "e.g. she/her, they/them")
                field("status", "Status", placeholder: "What you're up to")
                field("homepage", "Homepage", placeholder: "https://…", keyboard: .URL)
            } footer: {
                Text(supportNote)
            }

            Section {
                HStack(spacing: 12) {
                    avatarPreview
                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(uploading ? "Uploading…" : "Choose photo…", systemImage: "photo")
                        }
                        .disabled(uploading)
                        if !(fields["avatar"] ?? "").isEmpty {
                            Button("Remove", role: .destructive) { fields["avatar"] = "" }
                        }
                    }
                }
                field("avatar", "Avatar URL", placeholder: "https://…", keyboard: .URL)
            } header: {
                Text("Avatar")
            } footer: {
                Text("The photo is uploaded with the same file host or uploader as attachments, and its link is published as your avatar.")
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    session?.setProfile(fields)
                    dismiss()
                }
                .disabled(session == nil || uploading)
            }
        }
        .onAppear {
            let session = store.session(for: server)
            self.session = session
            fields = session.profile
        }
        .onChange(of: photoItem) { _, item in if let item { upload(item) } }
        .alert("Couldn't upload the photo", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func field(_ key: String, _ label: String, placeholder: String,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(label, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }),
                  prompt: Text(placeholder))
            .textInputAutocapitalization(keyboard == .URL ? .never : .sentences)
            .autocorrectionDisabled(keyboard == .URL)
            .keyboardType(keyboard)
    }

    @ViewBuilder private var avatarPreview: some View {
        let url = URL(string: fields["avatar"] ?? "").flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    /// Whether this server will actually show the profile to others.
    private var supportNote: String {
        guard let session, session.status == .connected else {
            return "Saved on this device and published when you connect, on servers that support profiles (like Ergo)."
        }
        if session.supportsProfile {
            return "Published on this network: others see it in their member list. Each network has its own profile."
        }
        return "This server doesn't support profiles (soju bouncers and Libera.Chat don't). It's kept on this device in case that changes."
    }

    /// Downscales the photo, uploads it and fills in the avatar URL.
    private func upload(_ item: PhotosPickerItem) {
        Task {
            defer { photoItem = nil }
            guard let session,
                  let destination = FileUploader.destination(fileHost: session.fileHost, uploader: uploader) else {
                errorMessage = "This server has no file host. Set up a custom uploader in Settings → Upload, or paste an image URL."
                return
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = Self.avatarJPEG(from: data) else {
                errorMessage = "Couldn't read the selected photo."
                return
            }
            uploading = true
            defer { uploading = false }
            do {
                fields["avatar"] = try await FileUploader.upload(data: jpeg, filename: "avatar.jpg",
                                                                 mimeType: "image/jpeg", to: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A square-ish JPEG no larger than 512 px: avatars show tiny, and full
    /// photos would be slow for everyone who loads them.
    static func avatarJPEG(from data: Data, maxSide: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
