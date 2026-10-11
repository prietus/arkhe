import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The message input row. Supports multi-line growth, a send button and — when
/// the server has a file host or a custom uploader is configured — an attach button that uploads a photo or
/// file and inserts the returned URL into the draft.
struct ComposeBar: View {
    @Binding var text: String
    var prompt: String = "Message"
    /// Whether to show the attach (upload) button (hidden in the status window).
    var showsAttach: Bool = false
    /// Channel members, for nick auto-completion (empty in non-channel buffers).
    var nicks: [String] = []
    /// Our own nick, excluded from completion suggestions.
    var ownNick: String? = nil
    /// The server's own file host, when it advertises one.
    var fileHost: FileHostTarget? = nil
    let onSend: () -> Void

    @Environment(UploaderSettings.self) private var uploader
    @FocusState private var focused: Bool

    @State private var showSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var uploading = false
    @State private var errorMessage: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if focused, !nickSuggestions.isEmpty { suggestionBar }
            inputRow
        }
        .background(.bar)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
        .onDrop(of: showsAttach ? [.item] : [], isTargeted: $dropTargeted, perform: handleDrop)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { uploadFile(at: url) }
        }
        .onChange(of: photoItem) { _, item in if let item { uploadPhoto(item) } }
        .confirmationDialog("Attach", isPresented: $showSourceDialog, titleVisibility: .visible) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Files") { showFileImporter = true }
        }
        .alert("Upload failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showsAttach { attachButton }

            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .focused($focused)
                .onSubmit(send)
                .submitLabel(.send)
                // Hardware-keyboard tab cycles nick completion (iPad).
                .onKeyPress(.tab) {
                    if completeNick() { return .handled }
                    return .ignored
                }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Nick completion

    /// The whitespace-delimited token at the end of the draft (what we complete).
    private var currentToken: String {
        guard let range = text.range(of: #"\S+$"#, options: .regularExpression) else { return "" }
        return String(text[range])
    }

    /// Nicks matching the current token (case-insensitive prefix), self excluded.
    private var nickSuggestions: [String] {
        let token = currentToken
        guard token.count >= 2, !token.hasPrefix("/") else { return [] }
        let lower = token.lowercased()
        return nicks.filter {
            $0.lowercased() != ownNick?.lowercased()
                && $0.lowercased().hasPrefix(lower)
                && $0.lowercased() != lower
        }.prefix(20).map { $0 }
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(nickSuggestions, id: \.self) { nick in
                    Button { insert(nick) } label: {
                        Text(nick)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 36)
    }

    /// Completes the current token to the first suggestion; returns whether it
    /// did anything (so the Tab key can fall through when there's no match).
    @discardableResult
    private func completeNick() -> Bool {
        guard let nick = nickSuggestions.first else { return false }
        insert(nick)
        return true
    }

    /// Replaces the trailing token with `nick`, adding `: ` when it starts the
    /// line (a mention) or a trailing space otherwise.
    private func insert(_ nick: String) {
        if let range = text.range(of: #"\S+$"#, options: .regularExpression) {
            let atStart = range.lowerBound == text.startIndex
            text.replaceSubrange(range, with: nick + (atStart ? ": " : " "))
        } else {
            text += nick + ": "
        }
        focused = true
    }

    private var attachButton: some View {
        Button {
            if uploadTarget == nil {
                errorMessage = Self.noUploaderMessage
            } else {
                showSourceDialog = true
            }
        } label: {
            if uploading {
                ProgressView().frame(width: 26, height: 26)
            } else {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
        }
        .disabled(uploading)
    }

    private func send() {
        onSend()
        focused = true
    }

    // MARK: - Upload

    private func uploadPhoto(_ item: PhotosPickerItem) {
        Task {
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                errorMessage = "Couldn't read the selected photo."
                return
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let mime = type?.preferredMIMEType ?? "image/jpeg"
            await upload(data: data, filename: "image.\(ext)", mime: mime)
        }
    }

    /// Handles a file/image dragged onto the compose bar (iPad drag-and-drop).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard uploadTarget != nil else {
            errorMessage = Self.noUploaderMessage
            return false
        }
        guard let provider = providers.first else { return false }
        // Prefer a concrete file type so we get a real filename and extension.
        let typeID = provider.registeredTypeIdentifiers
            .first { UTType($0)?.conforms(to: .data) == true }
            ?? provider.registeredTypeIdentifiers.first
        guard let typeID else { return false }

        provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
            // The temp file is removed once this returns, so read it now.
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let filename = url.lastPathComponent
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            Task { @MainActor in await upload(data: data, filename: filename, mime: mime) }
        }
        return true
    }

    private func uploadFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read the selected file."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        Task { await upload(data: data, filename: url.lastPathComponent, mime: mime) }
    }

    private enum UploadTarget {
        case server(FileHostTarget)
        case custom(UploaderSettings.Config)
    }

    private static let noUploaderMessage =
        "This server has no file host. Set up a custom uploader in Settings → Upload."

    /// The server's file host when it has one (and the user prefers it, or has no
    /// custom uploader); otherwise the custom uploader.
    private var uploadTarget: UploadTarget? {
        let custom = uploader.config
        if let fileHost, uploader.preferServerHost || custom == nil { return .server(fileHost) }
        return custom.map { .custom($0) }
    }

    private func upload(data: Data, filename: String, mime: String) async {
        guard let target = uploadTarget else {
            errorMessage = Self.noUploaderMessage
            return
        }
        uploading = true
        defer { uploading = false }
        do {
            let link: String
            switch target {
            case let .server(host):
                link = try await FileUploader.upload(data: data, filename: filename,
                                                     mimeType: mime, fileHost: host)
            case let .custom(config):
                link = try await FileUploader.upload(data: data, filename: filename,
                                                     mimeType: mime, config: config)
            }
            if !text.isEmpty && !text.hasSuffix(" ") { text += " " }
            text += link
            focused = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
