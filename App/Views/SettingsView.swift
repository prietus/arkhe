import SwiftUI

/// Display preferences: presence noise, event collapsing and timestamps.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(UploaderSettings.self) private var uploader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var uploader = uploader
        NavigationStack {
            Form {
                Section {
                    Picker("Joins, parts & quits", selection: $prefs.presenceVisibility) {
                        ForEach(Preferences.PresenceVisibility.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Toggle("Collapse consecutive events", isOn: $prefs.collapseEvents)
                } header: {
                    Text("Channel events")
                } footer: {
                    Text(presenceFooter)
                }

                Section("Timestamps") {
                    Toggle("Show timestamps", isOn: $prefs.showTimestamps)
                    if prefs.showTimestamps {
                        Picker("Clock", selection: $prefs.clockStyle) {
                            ForEach(Preferences.ClockStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Load images & link previews", isOn: $prefs.autoLoadMedia)
                } header: {
                    Text("Media")
                } footer: {
                    Text("Automatically fetches inline image thumbnails and link previews. This reveals your IP address to the sites hosting them. Links stay tappable either way.")
                }

                Section {
                    Toggle("Custom uploader", isOn: $uploader.enabled)
                    if uploader.enabled {
                        TextField("Upload URL", text: $uploader.uploadURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Bearer token (optional)", text: $uploader.bearerToken)
                        TextField("Multipart field", text: $uploader.multipartField)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Response", selection: $uploader.responseType) {
                            ForEach(UploaderSettings.ResponseType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        if uploader.responseType == .json {
                            TextField("JSON key", text: $uploader.jsonKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("Upload")
                } footer: {
                    Text("The attach button (📎) uploads a photo or file here and inserts the returned URL into your message. For inline image previews, use the response key that returns the direct/raw file URL. The token is stored in the Keychain.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var presenceFooter: String {
        switch prefs.presenceVisibility {
        case .show:  return "Every time someone joins, leaves or changes nick is shown."
        case .smart: return "Only shown for people who have spoken recently — quiet lurkers coming and going are hidden."
        case .hide:  return "Joins, parts, quits and nick changes are never shown."
        }
    }
}
