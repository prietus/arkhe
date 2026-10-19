import SwiftUI
import IRCCore

/// A server's ignore list: add a nick, hostmask or account, swipe to remove.
/// Edits go through the server's session so open chats update at once.
struct IgnoreListView: View {
    let server: ServerConfig
    @Environment(ClientStore.self) private var store

    @State private var session: IRCSession?
    @State private var newRule = ""
    @State private var invalid = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("nick, nick!user@host or $a:account", text: $newRule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if invalid {
                    Text("That isn't a valid nick, mask or account.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Use * and ? as wildcards, e.g. *!*@*.example.com. An account ($a:name) follows someone across nick changes.")
            }

            Section {
                if let session, !session.ignores.isEmpty {
                    ForEach(session.ignores, id: \.self) { mask in
                        Text(mask.pattern)
                            .font(.body.monospaced())
                    }
                    .onDelete { offsets in
                        for mask in offsets.map({ session.ignores[$0] }) { session.unignore(mask) }
                    }
                } else {
                    Text("Nobody is ignored on this server.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Ignored")
            } footer: {
                Text("Messages from ignored people are hidden and never notify you. With the app closed, a push from them shows only a silent “New message”.")
            }
        }
        .navigationTitle("Ignored users")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session = store.session(for: server) }
    }

    private func add() {
        guard let session else { return }
        guard let mask = IgnoreMask(parsing: newRule) else {
            invalid = true
            return
        }
        session.ignore(mask)
        newRule = ""
        invalid = false
    }
}
