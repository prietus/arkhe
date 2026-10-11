import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Add / edit a server or bouncer. Handles SASL configuration and importing a
/// PKCS#12 client certificate for CertFP (SASL EXTERNAL), showing the resulting
/// SHA-256 fingerprint to register with the network.
struct ServerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ClientStore.self) private var store

    /// `nil` when creating a new server.
    let server: ServerConfig?

    @State private var name = ""
    @State private var host = ""
    @State private var port = 6697
    @State private var useTLS = true
    @State private var allowInvalidCertificates = false
    @State private var nickname = ""
    @State private var username = ""
    @State private var realName = ""
    @State private var saslMode: SASLMode = .none
    @State private var saslAccount = ""
    @State private var saslPassword = ""
    @State private var serverPassword = ""
    @State private var isBouncer = false
    @State private var autoConnect = false
    @State private var autoJoin = ""

    @State private var certificateData: Data?
    @State private var certificatePassphrase = ""
    @State private var importingCertificate = false
    @State private var certificateError: String?

    var body: some View {
        Form {
            if server == nil {
                Section {
                    ForEach(NetworkPreset.all) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundStyle(.primary)
                                Text(preset.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Popular networks")
                } footer: {
                    Text("Fills in the form with a guest nick — tweak anything before saving.")
                }
            }

            Section("Server") {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $port, in: 1...65535) {
                    Text(verbatim: "Port: \(port)")
                }
                Toggle("TLS", isOn: $useTLS)
                Toggle("Accept invalid certificates", isOn: $allowInvalidCertificates)
                Toggle("This is a bouncer (soju)", isOn: $isBouncer)
            }

            Section("Identity") {
                TextField("Nick", text: $nickname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username (optional)", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Real name (optional)", text: $realName)
                if isBouncer {
                    Text("For soju, use `user/network` in the username or SASL account to bind a network.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("SASL authentication") {
                Picker("Mechanism", selection: $saslMode) {
                    ForEach(SASLMode.allCases) { Text($0.label).tag($0) }
                }
                if saslMode == .plain {
                    TextField("Account", text: $saslAccount)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $saslPassword)
                }
                if saslMode == .external {
                    certificateSection
                }
            }

            Section("Connection") {
                SecureField("Server password (optional)", text: $serverPassword)
                TextField("Auto-join channels (#a, #b)", text: $autoJoin)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Connect on launch", isOn: $autoConnect)
            }

            if server != nil {
                Section {
                    Button(role: .destructive) { delete() } label: {
                        Label("Delete server", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(server == nil ? "New server" : "Edit server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(host.isEmpty || nickname.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear(perform: load)
        .fileImporter(isPresented: $importingCertificate,
                      allowedContentTypes: [.pkcs12, .x509Certificate, .data],
                      allowsMultipleSelection: false) { result in
            handleCertificateImport(result)
        }
    }

    @ViewBuilder private var certificateSection: some View {
        if certificateData != nil {
            LabeledContent("Certificate", value: "Imported")
            SecureField("Certificate passphrase", text: $certificatePassphrase)
            if let fingerprint = computedFingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 fingerprint (CertFP)").font(.caption).foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Register it on the network: /msg NickServ CERT ADD")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let certificateError {
                Text(certificateError).font(.caption).foregroundStyle(.red)
            }
            Button("Remove certificate", role: .destructive) {
                certificateData = nil
                certificatePassphrase = ""
            }
        } else {
            Button {
                importingCertificate = true
            } label: {
                Label("Import certificate (.p12)", systemImage: "doc.badge.plus")
            }
            Text("CertFP authenticates with your TLS client certificate, no password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var computedFingerprint: String? {
        guard let certificateData else { return nil }
        return try? TLSIdentity(pkcs12: certificateData, passphrase: certificatePassphrase).sha256Fingerprint
    }

    /// Prefills the form from a preset. Nicks get a random suffix because IRC
    /// nicks are unique per network — a fixed one would collide as soon as two
    /// users connected at once.
    private func apply(_ preset: NetworkPreset) {
        name = preset.name
        host = preset.host
        port = 6697
        useTLS = true
        isBouncer = false
        saslMode = .none
        nickname = String(format: "arkhe-%04d", Int.random(in: 0...9999))
        autoJoin = preset.autoJoin
    }

    // MARK: - Load / save

    private func load() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = server.port
        useTLS = server.useTLS
        allowInvalidCertificates = server.allowInvalidCertificates
        nickname = server.nickname
        username = server.username
        realName = server.realName
        saslMode = server.saslMode
        saslAccount = server.saslAccount
        saslPassword = server.saslPassword ?? ""
        serverPassword = server.serverPassword ?? ""
        isBouncer = server.isBouncer
        autoConnect = server.autoConnect
        autoJoin = server.autoJoinChannels.joined(separator: ", ")
        certificateData = server.certificateData
        certificatePassphrase = server.certificatePassphrase ?? ""
    }

    private func save() {
        let target = server ?? ServerConfig()
        target.name = name.isEmpty ? host : name
        target.host = host
        target.port = port
        target.useTLS = useTLS
        target.allowInvalidCertificates = allowInvalidCertificates
        target.nickname = nickname
        target.username = username.isEmpty ? nickname : username
        target.realName = realName.isEmpty ? nickname : realName
        target.saslMode = saslMode
        target.saslAccount = saslAccount.isEmpty ? nickname : saslAccount
        target.isBouncer = isBouncer
        target.autoConnect = autoConnect
        target.autoJoinChannels = autoJoin
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        target.certificateData = certificateData

        if server == nil { modelContext.insert(target) }

        // Secrets to Keychain.
        target.saslPassword = saslPassword.isEmpty ? nil : saslPassword
        target.serverPassword = serverPassword.isEmpty ? nil : serverPassword
        target.certificatePassphrase = certificatePassphrase.isEmpty ? nil : certificatePassphrase

        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        guard let server else { return }
        store.removeSession(server.id)
        modelContext.delete(server)
        try? modelContext.save()
        dismiss()
    }

    private func handleCertificateImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                certificateData = try Data(contentsOf: url)
                certificateError = nil
            } catch {
                certificateError = error.localizedDescription
            }
        case let .failure(error):
            certificateError = error.localizedDescription
        }
    }
}

/// One-tap starting points for the new-server form. Both connect over TLS on
/// 6697 with no account: Libera as the big general-purpose network, and the
/// public Ergo testnet as the IRCv3 showcase (reactions, replies, redaction).
private struct NetworkPreset: Identifiable {
    let name: String
    let host: String
    let autoJoin: String
    let blurb: String
    var id: String { host }

    static let all: [NetworkPreset] = [
        NetworkPreset(name: "Libera.Chat",
                      host: "irc.libera.chat",
                      autoJoin: "#libera",
                      blurb: "The largest open-source network — no account needed"),
        NetworkPreset(name: "Ergo testnet",
                      host: "testnet.ergo.chat",
                      autoJoin: "#chat",
                      blurb: "Public IRCv3 playground — reactions, replies, history"),
    ]
}
