import SwiftUI

/// Renders one `ChatLine`. Messages show a colourised nick + text; events and
/// notices get a muted, distinct style.
struct ChatLineView: View {
    /// The parent of a reply. `lineID` is nil when the original isn't in the
    /// loaded scrollback (it's fetched on tap instead).
    struct ReplyContext: Equatable {
        var sender: String
        var text: String
        var lineID: UUID?
    }

    let line: ChatLine
    /// The message this one replies to (`+draft/reply`), if resolved.
    var reply: ReplyContext? = nil
    /// Our own nick, to highlight reactions we've added.
    var currentNick: String? = nil
    /// Whether to prepend the timestamp to each message.
    var showTimestamps: Bool = true
    /// 12/24-hour formatting for the timestamp.
    var clockStyle: Preferences.ClockStyle = .system
    /// Auto-fetch inline image thumbnails and link-preview cards.
    var autoLoadMedia: Bool = true
    /// Host of the configured pastebin uploader, so its paste pages unfurl to
    /// the embedded image instead of a generic card.
    var uploaderHost: String? = nil
    /// Tapping an existing reaction chip toggles the same emoji.
    var onTapReaction: ((String) -> Void)? = nil
    /// Tapping the quoted reply jumps to the original message.
    var onTapReply: (() -> Void)? = nil

    var body: some View {
        switch line.kind {
        case .event:
            eventLine
        case .motd:
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Text(line.text)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action, .notice, .message:
            messageLine
        }
    }

    private var messageLine: some View {
        // A reply is shown indented with a downward connector (↳) — the original
        // is right above, so we don't re-quote its text. Tap the connector to
        // jump to it.
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if reply != nil {
                Button { onTapReply?() } label: {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(onTapReply == nil)
            }
            // The timestamp lives in its own fixed-width column so that wrapped
            // lines of a long message hang under the nick, not under the time.
            if showTimestamps {
                Text(timeString)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: timeColumnWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                // Nick and text flow inline on one wrapping line, IRC-style.
                // NB: no `.textSelection(.enabled)` here — its long-press competes
                // with the row's `.contextMenu`, so a press selected the whole
                // message instead of opening the menu. Copy lives in the menu.
                lineText
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if autoLoadMedia { mediaAttachments }
                if !line.reactions.isEmpty && !line.redacted { reactionChips }
            }
        }
        .padding(.leading, reply != nil ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    /// The wrapping content column: `nick  text` (the timestamp is rendered
    /// separately as a leading column so wrapped lines hang under the nick).
    private var lineText: Text {
        let nickName = Text((line.sender ?? "") + "  ")
            .foregroundStyle(line.isSelf ? Color.accentColor : nickColor)
            .fontWeight(.semibold)
        let bodyColor: Color = line.isHistorical ? .secondary : .primary

        if line.redacted {
            // Show who removed it only when it wasn't the author (moderation).
            let who = line.redactedBy.flatMap { $0 == line.sender ? nil : $0 }
                .map { " by \($0)" } ?? ""
            return nickName
                + Text("(message deleted\(who))").italic().foregroundStyle(.secondary)
        }

        switch line.kind {
        case .action:
            return Text("\u{2022} ").foregroundStyle(.secondary)
                + nickName.italic()
                + Text(MessageLinks.linkified(line.text, baseColor: bodyColor)).italic()
        case .notice:
            return nickName
                + Text("(notice) ").foregroundStyle(.secondary).font(.caption2)
                + Text(MessageLinks.linkified(line.text, baseColor: bodyColor)).italic()
        default:
            return nickName + Text(MessageLinks.linkified(line.text, baseColor: bodyColor))
        }
    }

    /// Inline image thumbnails, or a single link-preview card for the first
    /// non-image URL. Skipped for redacted lines and non-conversational kinds.
    @ViewBuilder private var mediaAttachments: some View {
        if !line.redacted, line.kind == .message || line.kind == .action || line.kind == .notice {
            let images = MessageLinks.imageURLs(in: line.text)
            let candidate = images.isEmpty ? MessageLinks.previewURL(in: line.text) : nil
            if !images.isEmpty || candidate != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(images, id: \.self) { InlineImageView(url: $0) }
                    if let candidate {
                        AdaptiveMediaView(url: candidate, uploaderHost: uploaderHost)
                    }
                }
            }
        }
    }

    /// Fixed width for the timestamp column, sized to the active clock format so
    /// nicks line up and wrapped text consistently hangs under the nick.
    private var timeColumnWidth: CGFloat {
        switch clockStyle {
        case .twentyFourHour: return 36
        case .twelveHour, .system: return 58
        }
    }

    private var reactionChips: some View {
        let sorted = line.reactions.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        return HStack(spacing: 4) {
            ForEach(sorted, id: \.key) { emoji, nicks in
                let mine = currentNick.map(nicks.contains) ?? false
                Button { onTapReaction?(emoji) } label: {
                    HStack(spacing: 3) {
                        Text(emoji).font(.caption)
                        Text("\(nicks.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(mine ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 1)
    }

    private var eventLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption2)
            Text(line.text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeString: String {
        switch clockStyle {
        case .system:
            return line.timestamp.formatted(date: .omitted, time: .shortened)
        case .twelveHour:
            return line.timestamp.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
        case .twentyFourHour:
            return line.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
    }

    /// Deterministic per-nick colour so the same person always looks the same.
    private var nickColor: Color {
        guard let sender = line.sender else { return .primary }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal,
                                .indigo, .mint, .cyan, .brown]
        let hash = sender.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
