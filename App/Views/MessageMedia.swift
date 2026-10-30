import SwiftUI
@preconcurrency import LinkPresentation

/// URL detection and classification for message bodies. Links are always made
/// tappable; image vs. generic URLs are split so the view can render inline
/// thumbnails or a rich preview card.
enum MessageLinks {
    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"]

    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// All http(s) URLs found in `text` (a cheap `.` check skips most messages).
    static func detect(in text: String) -> [URL] {
        guard text.contains("."), let detector else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: range).compactMap(\.url)
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func imageURLs(in text: String) -> [URL] {
        detect(in: text).filter(isImage)
    }

    /// The first non-image URL, for a single link-preview card.
    static func previewURL(in text: String) -> URL? {
        detect(in: text).first { !isImage($0) }
    }

    /// `text` with detected links made tappable (accent + underline) over a
    /// `baseColor` body.
    static func linkified(_ text: String, baseColor: Color) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        if let detector {
            let range = NSRange(location: 0, length: (text as NSString).length)
            detector.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let url = match.url else { return }
                mutable.addAttribute(.link, value: url, range: match.range)
            }
        }
        var attr = AttributedString(mutable)
        attr.foregroundColor = baseColor
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = .accentColor
            attr[run.range].underlineStyle = .single
        }
        return attr
    }
}

/// The outcome of probing a non-image URL: render it as an image, or fall back
/// to a link-preview card.
enum ResolvedMedia: Sendable {
    case image(URL)
    case link
}

/// Decides whether a URL without an image extension actually points to an image
/// — directly (content-type `image/*`) or as a paste page that embeds one.
enum MediaResolver {
    static func resolve(_ url: URL, uploaderHost: String?) async -> ResolvedMedia {
        if MessageLinks.isImage(url) { return .image(url) }
        guard let info = await contentType(of: url) else { return .link }
        if info.type.hasPrefix("image/") { return .image(info.finalURL) }

        // Only deep-unfurl HTML from the configured paste/upload host — scraping
        // every website link for an <img> would surface logos, not content.
        guard info.type.hasPrefix("text/html"),
              let host = url.host, host == uploaderHost,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let candidate = embeddedImageURL(in: data, baseURL: response.url ?? url),
              let candidateInfo = await contentType(of: candidate),
              candidateInfo.type.hasPrefix("image/")
        else { return .link }
        return .image(candidate)
    }

    /// HEAD-probes a URL for its content type and final (redirected) URL.
    private static func contentType(of url: URL) async -> (type: String, finalURL: URL)? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return (type, http.url ?? url)
    }

    /// First `og:image` / `twitter:image`, else the first `<img src>`, resolved
    /// against the page URL.
    private static func embeddedImageURL(in data: Data, baseURL: URL) -> URL? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image|twitter:image)(?::src)?["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+(?:property|name)\s*=\s*["'](?:og:image|twitter:image)["']"#,
            #"<img[^>]+src\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern, in: html),
               let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

/// Renders a non-extension URL adaptively: a spinner while probing, then either
/// an inline image (direct or unfurled from a paste page) or a preview card.
struct AdaptiveMediaView: View {
    let url: URL
    let uploaderHost: String?
    @State private var resolved: ResolvedMedia?

    var body: some View {
        Group {
            switch resolved {
            case let .image(imageURL):
                InlineImageView(url: imageURL)
            case .link:
                LinkPreviewView(url: url)
            case nil:
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    ProgressView()
                }
                .frame(width: 160, height: 60)
            }
        }
        .task(id: url) { resolved = await MediaResolver.resolve(url, uploaderHost: uploaderHost) }
    }
}

/// An inline image thumbnail; tap to view full-screen.
struct InlineImageView: View {
    let url: URL
    @Environment(Preferences.self) private var prefs
    @State private var showFull = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut)) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    ProgressView()
                }
                .frame(width: 160, height: 100)
            case let .success(image):
                image.resizable().scaledToFit()
                    .frame(maxWidth: prefs.mediaSize.maxSize.width, maxHeight: prefs.mediaSize.maxSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { showFull = true }
            case .failure:
                EmptyView() // the URL stays tappable in the text itself
            @unknown default:
                EmptyView()
            }
        }
        .fullScreenCover(isPresented: $showFull) { ImageViewer(url: url) }
    }
}

/// Full-screen image viewer with pinch-to-zoom.
struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = max(1, $0.magnification) }
                            .onEnded { _ in withAnimation { scale = max(1, scale) } }
                    )
            } placeholder: {
                ProgressView().tint(.white)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
        }
    }
}

/// A compact link-preview card (OpenGraph metadata via `LinkPresentation`),
/// rendered ourselves so it stays a fixed, predictable size and blends with the
/// app theme — `LPLinkView` sizes itself unpredictably and renders on white.
struct LinkPreviewView: View {
    let url: URL
    @State private var title: String?
    @State private var thumbnail: UIImage?
    @State private var loaded = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? (url.host ?? url.absoluteString))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .task(id: url) { await load() }
    }

    @ViewBuilder private var thumb: some View {
        if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.tertiary)
                Image(systemName: "link").foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
        }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let provider = LPMetadataProvider()
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        title = metadata.title
        if let imageProvider = metadata.imageProvider ?? metadata.iconProvider {
            thumbnail = await Self.loadImage(from: imageProvider)
        }
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}
