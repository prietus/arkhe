import Foundation

enum FileUploadError: LocalizedError {
    case badResponse(Int)
    case noURLInResponse
    case emptyData

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "Upload failed (HTTP \(code))."
        case .noURLInResponse:       return "The server's response didn't contain a URL."
        case .emptyData:             return "The selected file was empty."
        }
    }
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
