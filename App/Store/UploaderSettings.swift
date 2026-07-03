import Foundation
import Observation

/// Configuration for a custom file uploader (pastebin / HTTP REST). The attach
/// button POSTs files here and inserts the returned URL into the message, which
/// then renders inline. The bearer token is a secret and lives in the Keychain;
/// everything else is in `UserDefaults`.
@MainActor
@Observable
final class UploaderSettings {
    /// How the upload endpoint returns the resulting URL.
    enum ResponseType: String, CaseIterable, Identifiable, Sendable {
        case json, text
        var id: String { rawValue }
        var label: String { self == .json ? "JSON" : "Plain text" }
    }

    /// An immutable, `Sendable` snapshot handed to the uploader so the network
    /// work never touches main-actor state off the main thread.
    struct Config: Sendable {
        var url: URL
        var token: String
        var field: String
        var responseType: ResponseType
        var jsonKey: String
    }

    var enabled: Bool            { didSet { d.set(enabled, forKey: K.enabled) } }
    var uploadURL: String        { didSet { d.set(uploadURL, forKey: K.url) } }
    var multipartField: String   { didSet { d.set(multipartField, forKey: K.field) } }
    var responseType: ResponseType { didSet { d.set(responseType.rawValue, forKey: K.response) } }
    var jsonKey: String          { didSet { d.set(jsonKey, forKey: K.jsonKey) } }
    /// Secret — Keychain only, never UserDefaults.
    var bearerToken: String {
        didSet { Keychain.set(bearerToken.isEmpty ? nil : bearerToken, for: K.token) }
    }

    private let d = UserDefaults.standard

    private enum K {
        static let enabled  = "upload.enabled"
        static let url      = "upload.url"
        static let field    = "upload.field"
        static let response = "upload.response"
        static let jsonKey  = "upload.jsonKey"
        static let token    = "uploader.bearerToken"   // Keychain account
    }

    init() {
        enabled = d.bool(forKey: K.enabled)
        uploadURL = d.string(forKey: K.url) ?? ""
        multipartField = d.string(forKey: K.field) ?? "file"
        responseType = ResponseType(rawValue: d.string(forKey: K.response) ?? "") ?? .json
        jsonKey = d.string(forKey: K.jsonKey) ?? "url"
        bearerToken = Keychain.get(K.token) ?? ""
    }

    /// A ready-to-use snapshot, or `nil` when the uploader is off / misconfigured.
    var config: Config? {
        guard enabled,
              let url = URL(string: uploadURL.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return Config(url: url, token: bearerToken,
                      field: multipartField.isEmpty ? "file" : multipartField,
                      responseType: responseType, jsonKey: jsonKey)
    }
}
