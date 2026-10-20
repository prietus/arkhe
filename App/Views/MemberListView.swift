import SwiftUI
import IRCCore

/// The channel member roster, grouped implicitly by membership prefix order.
struct MemberListView: View {
    let buffer: Buffer
    /// For ignoring / un-ignoring members from their row's menu.
    let session: IRCSession
    let onSelect: (String) -> Void
    @Environment(Preferences.self) private var prefs

    var body: some View {
        List(buffer.sortedMembers) { member in
            Button {
                onSelect(member.nick)
            } label: {
                HStack(spacing: 8) {
                    Text(prefixSymbol(member))
                        .foregroundStyle(prefixColor(member))
                        .font(.body.monospaced())
                        .frame(width: 12)
                    // draft/metadata-2 avatar, fetched only with media auto-loading
                    // on (like link previews, it reveals our IP to its host).
                    if prefs.autoLoadMedia, let avatar = session.avatarURL(for: member.nick) {
                        AsyncImage(url: avatar) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.nick)
                            .foregroundStyle(.primary)
                        if let subtitle = subtitle(member) {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    // away-notify: dim the whole entry and mark it with a moon.
                    .opacity(member.isAway ? 0.45 : 1)
                    if member.isAway {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Away")
                    }
                    if member.isBot {
                        Text("BOT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if session.isIgnored(nick: member.nick, user: nil, host: nil, account: member.account) {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Ignored")
                    }
                    Spacer()
                    if let account = member.account, !account.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .contextMenu { ignoreMenu(member) }
        }
        // Covers any path where the roster wasn't requested yet.
        .onAppear { session.loadMembersIfNeeded(buffer) }
    }

    /// Ignore by nick, or by account when the member is logged in (follows
    /// them across nick changes); un-ignore removes the exact-nick rule.
    @ViewBuilder private func ignoreMenu(_ member: Member) -> some View {
        if let rule = session.plainIgnore(for: member.nick) {
            Button { session.unignore(rule) } label: {
                Label("Unignore \(member.nick)", systemImage: "eye")
            }
        } else if let mask = IgnoreMask(parsing: member.nick) {
            Button(role: .destructive) { session.ignore(mask) } label: {
                Label("Ignore \(member.nick)", systemImage: "eye.slash")
            }
            if let account = member.account, !account.isEmpty,
               let byAccount = IgnoreMask(parsing: "$a:\(account)") {
                Button(role: .destructive) { session.ignore(byAccount) } label: {
                    Label("Ignore account \(account)", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
    }

    /// Display name and pronouns (draft/metadata-2), then the realname — each
    /// only when it adds something beyond the nick.
    private func subtitle(_ member: Member) -> String? {
        let profile = session.metadata(for: member.nick)
        let parts = [profile["display-name"], profile["pronouns"], member.realname]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != member.nick }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0.lowercased()).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    private func prefixSymbol(_ member: Member) -> String {
        member.prefix.map(String.init) ?? " "
    }

    private func prefixColor(_ member: Member) -> Color {
        switch member.prefix {
        case "~", "&": return .red
        case "@": return .orange
        case "%": return .yellow
        case "+": return .green
        default: return .secondary
        }
    }
}
