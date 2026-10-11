import Foundation

enum FileUploadError: LocalizedError {
    case badResponse(Int)
    case noURLInResponse
    case emptyData
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "Upload failed (HTTP \(code))."
        case .noURLInResponse:       return "The server's response didn't contain a URL."
        case .emptyData:             return "The selected file was empty."
        case .unauthorized:          return "The server's file host rejected the login (HTTP 401)."
        }
    }
}

/// The IRC server's own upload endpoint (IRCv3 `filehost` / soju), resolved
/// from ISUPPORT, plus the credentials to present: the spec asks for HTTP Basic
/// with the SASL PLAIN credentials. With CertFP or no SASL we send none.
struct FileHostTarget: Sendable {
    var url: URL
    var basicUser: String?
    var basicPassword: String?
}

/// Uploads a file to a custom HTTP endpoint as `multipart/form-data` and returns
/// the resulting URL parsed from the response (a JSON key path or the plain
/// body). Stateless — driven entirely by an `UploaderSettings.Config` snapshot.
enum FileUploader {
    static func upload(data: Data, filename: String, mimeType: String,
                       config: UploaderSettings.Config) async throws -> String {
        guard !data.isEmpty else { throw FileUploadError.emptyData }

        let boundary = "arkhe-\(UUID().uuidString)"
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(config.field)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw FileUploadError.badResponse(code) }

        let result: String?
        switch config.responseType {
        case .text:
            result = String(data: respData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .json:
            result = extract(config.jsonKey, from: respData)
        }
        guard let url = result, !url.isEmpty else { throw FileUploadError.noURLInResponse }
        return url
    }

    /// Uploads to the server's file host: the raw bytes as the POST body, and the
    /// file's URL comes back in the `Location` header of a `201 Created`.
    static func upload(data: Data, filename: String, mimeType: String,
                       fileHost: FileHostTarget) async throws -> String {
        guard !data.isEmpty else { throw FileUploadError.emptyData }

        var request = URLRequest(url: fileHost.url)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentDisposition(filename), forHTTPHeaderField: "Content-Disposition")
        if let user = fileHost.basicUser, let password = fileHost.basicPassword {
            let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        if code == 401 { throw FileUploadError.unauthorized }
        guard (200..<300).contains(code) else { throw FileUploadError.badResponse(code) }
        // Location may be relative to the upload URI.
        guard let location = http?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: fileHost.url) else {
            throw FileUploadError.noURLInResponse
        }
        return url.absoluteString
    }

    /// RFC 5987 `attr-char`: ASCII alphanumerics plus a few marks (unlike
    /// `.alphanumerics`, which also admits non-ASCII letters).
    private static let attrChars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    /// `inline; filename="…"` with an RFC 5987 `filename*` for non-ASCII names.
    private static func contentDisposition(_ filename: String) -> String {
        let ascii = String(filename.unicodeScalars.map {
            $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_"
        })
        var value = "inline; filename=\"\(ascii)\""
        if ascii != filename,
           let encoded = filename.addingPercentEncoding(withAllowedCharacters: attrChars) {
            value += "; filename*=UTF-8''\(encoded)"
        }
        return value
    }

    /// Resolves a (possibly dotted) key path against a JSON object, e.g.
    /// `data.url` → `{ "data": { "url": "…" } }`.
    private static func extract(_ keyPath: String, from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var current: Any? = root
        for key in keyPath.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        if let string = current as? String { return string }
        if let number = current as? NSNumber { return number.stringValue }
        return nil
    }
}

private extension Data {
    mutating func appendString(_ string: String) { append(Data(string.utf8)) }
}
