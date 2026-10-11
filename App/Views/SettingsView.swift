import SwiftUI

/// Display preferences: presence noise, event collapsing and timestamps.
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(UploaderSettings.self) private var uploader
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyword = ""

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var uploader = uploader
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable notifications", isOn: $prefs.notificationsEnabled)
                    if prefs.notificationsEnabled {
                        Toggle("Mentions (highlights)", isOn: $prefs.notifyOnMention)
                        Toggle("Direct messages", isOn: $prefs.notifyOnDirectMessage)
                        Toggle("Show message preview", isOn: $prefs.notificationPreviews)
                        Toggle("Play sound", isOn: $prefs.notificationSound)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notificationsFooter)
                }
                .onChange(of: prefs.notificationsEnabled) { _, enabled in
                    if enabled { Task { await notifications.requestAuthorization() } }
                }

                if prefs.notificationsEnabled {
                    Section {
                        Toggle("Push when app is closed", isOn: $prefs.remotePushEnabled)
                        if prefs.remotePushEnabled {
                            TextField("Relay URL", text: $prefs.pushRelayURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                    } header: {
                        Text("Push (app closed)")
                    } footer: {
                        Text("Delivers mentions and direct messages while Arkhe is fully closed, via your bouncer's Web Push. Requires a soju bouncer with web push. Messages are end-to-end encrypted — the relay only forwards them to Apple and can't read them. Self-hosters can point this at their own relay.")
                    }
                    .onChange(of: prefs.remotePushEnabled) { _, enabled in
                        if enabled {
                            Task { await notifications.requestAuthorization() }
                            notifications.registerForRemotePush()
                        }
                    }

                    Section {
                        ForEach(prefs.highlightKeywords, id: \.self) { word in
                            Text(word)
                        }
                        .onDelete { prefs.removeHighlightKeywords(at: $0) }
                        HStack {
                            TextField("Add a word", text: $newKeyword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit(addKeyword)
                            Button("Add", action: addKeyword)
                                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        Text("Highlight keywords")
                    } footer: {
                        Text("Also alert you when a message contains any of these words, not just your nick. Case-insensitive.")
                    }
                }

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
                    Toggle("Use server's file host", isOn: $uploader.preferServerHost)
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
                    Text("The attach button (📎) uploads a photo or file and inserts the returned URL into your message. When the server or bouncer offers its own file host (e.g. soju), it's used with your SASL login; otherwise the custom uploader is. For inline image previews, use the response key that returns the direct/raw file URL. The token is stored in the Keychain.")
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

    private func addKeyword() {
        prefs.addHighlightKeyword(newKeyword)
        newKeyword = ""
    }

    private var notificationsFooter: String {
        if notifications.authorization == .denied {
            return "Notifications are turned off for Arkhe in iOS Settings. Enable them there to be alerted about mentions and direct messages."
        }
        return "Get a local alert when someone mentions your nick or sends you a direct message while Arkhe is open or just backgrounded. For alerts while it's fully closed, turn on Push below."
    }

    private var presenceFooter: String {
        switch prefs.presenceVisibility {
        case .show:  return "Every time someone joins, leaves or changes nick is shown."
        case .smart: return "Only shown for people who have spoken recently — quiet lurkers coming and going are hidden."
        case .hide:  return "Joins, parts, quits and nick changes are never shown."
        }
    }
}
