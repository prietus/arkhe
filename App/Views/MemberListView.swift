import SwiftUI
import IRCCore

/// The channel member roster, grouped implicitly by membership prefix order.
struct MemberListView: View {
    let buffer: Buffer
    /// For ignoring / un-ignoring members from their row's menu.
    let session: IRCSession
    let onSelect: (String) -> Void

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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.nick)
                            .foregroundStyle(.primary)
                        if let realname = member.realname, !realname.isEmpty {
                            Text(realname)
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
