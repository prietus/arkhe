import SwiftUI

/// The channel member roster, grouped implicitly by membership prefix order.
struct MemberListView: View {
    let buffer: Buffer
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
                    if member.isBot {
                        Text("BOT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    if let account = member.account, !account.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
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
