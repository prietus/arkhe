import SwiftUI
import UIKit

/// The conversation pane: scrollback, topic, member list (channels) and the
/// compose bar.
struct ChatView: View {
    @Environment(ClientStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(UploaderSettings.self) private var uploader
    let session: IRCSession
    let buffer: Buffer

    @State private var draft = ""
    @State private var showingMembers = false
    @State private var showingConsole = false
    @State private var showingJoin = false
    @State private var joinChannelText = ""
    /// When prepending older history, the line to keep pinned so the view
    /// doesn't jump.
    @State private var scrollAnchorID: UUID?
    /// Where the "new messages" divider is drawn — captured once on appear,
    /// before we mark the buffer read.
    @State private var unreadDividerID: UUID?
    /// The line the user is composing a reply to, if any.
    @State private var replyingTo: ChatLine?
    /// The line being reacted to via the full emoji-keyboard picker, if any.
    @State private var reactingTo: ChatLine?
    /// Debounces follow-to-bottom so a burst of lines scrolls once, not per line.
    @State private var followTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if buffer.kind != .status {
                typingBanner
                if let replyingTo { replyContextBar(replyingTo) }
            }
            // The status window accepts commands (e.g. /join #channel) too.
            ComposeBar(text: $draft,
                       prompt: buffer.kind == .status ? "Command, e.g. /join #channel" : "Message",
                       showsAttach: buffer.kind != .status,
                       nicks: buffer.kind == .channel ? buffer.sortedMembers.map(\.nick) : [],
                       ownNick: session.currentNick,
                       fileHost: session.fileHost,
                       onSend: send)
                .onChange(of: draft) { _, newValue in
                    guard buffer.kind != .status else { return }
                    let active = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    session.notifyTyping(in: buffer, hasText: active)
                }
        }
        .navigationTitle(buffer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let topic = buffer.topic, !topic.isEmpty {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(buffer.name).font(.headline)
                        Text(topic).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingJoin = true } label: {
                    Image(systemName: "plus.bubble")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingConsole = true } label: {
                    Image(systemName: "terminal")
                }
            }
            if buffer.kind == .channel {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingMembers.toggle() } label: {
                        Label("\(buffer.members.count)", systemImage: "person.2")
                    }
                }
            }
        }
        .alert("Join channel", isPresented: $showingJoin) {
            TextField("#channel", text: $joinChannelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join") { performJoin() }
            Button("Cancel", role: .cancel) { joinChannelText = "" }
        }
        .sheet(isPresented: $showingConsole) {
            ProtocolLogView(log: session.protocolLog)
        }
        .sheet(isPresented: $showingMembers) {
            NavigationStack {
                MemberListView(buffer: buffer) { nick in
                    showingMembers = false
                    let query = session.openQuery(nick)
                    store.select(query, in: session)
                }
                .navigationTitle("Members")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $reactingTo) { line in
            EmojiReactSheet { emoji in
                session.toggleReaction(emoji, to: line, in: buffer)
            }
            .presentationDetents([.height(160)])
        }
        .sheet(item: aroundContextBinding) { context in
            AroundContextSheet(context: context,
                               currentNick: session.currentNick,
                               showTimestamps: prefs.showTimestamps,
                               clockStyle: prefs.clockStyle)
                .presentationDetents([.medium, .large])
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if buffer.kind != .status && !buffer.historyExhausted {
                        historyLoader
                    }
                    ForEach(displayLines) { line in
                        let reply = replyContext(for: line)
                        if line.id == unreadDividerID {
                            unreadDivider
                        }
                        ChatLineView(
                            line: line,
                            reply: reply,
                            currentNick: session.currentNick,
                            showTimestamps: prefs.showTimestamps,
                            clockStyle: prefs.clockStyle,
                            autoLoadMedia: prefs.autoLoadMedia,
                            uploaderHost: URL(string: uploader.uploadURL)?.host,
                            onTapReaction: { emoji in session.toggleReaction(emoji, to: line, in: buffer) },
                            onTapReply: reply.map { ctx in {
                                if let target = ctx.lineID {
                                    proxy.scrollTo(target, anchor: .center)
                                } else if let parent = line.replyTo {
                                    session.showOriginal(of: parent, in: buffer)
                                }
                            } }
                        )
                        .id(line.id)
                        .padding(.horizontal, 12)
                        .contextMenu { lineMenu(line) }
                    }
                }
                .padding(.vertical, 8)
            }
            // Start pinned to the newest message and follow content that grows at
            // the bottom; without this the initial position is unreliable and the
            // view can land at the top of the scrollback.
            .defaultScrollAnchor(.bottom)
            .onChange(of: buffer.lines.count) { old, new in
                if buffer.isLoadingHistory {
                    // An older page is prepending — keep the read position pinned;
                    // never follow/markRead per line here.
                    if let anchor = scrollAnchorID { proxy.scrollTo(anchor, anchor: .top) }
                    return
                }
                guard new > old else { return }
                // Coalesce bursts into a single follow + markRead. A reconnect
                // replays missed messages as a flood of live lines; doing the work
                // per line fires the onChange many times per frame and freezes the
                // UI. Debouncing collapses the flood into one scroll.
                followTask?.cancel()
                followTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let last = displayLines.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    session.markRead(buffer)
                }
            }
            // Release the pin only once the history page has fully arrived, so the
            // anchor can't linger and hijack a later live message.
            .onChange(of: buffer.isLoadingHistory) { _, loading in
                if !loading { scrollAnchorID = nil }
            }
            // A reply's original found by paging back (servers without msgid
            // references): let the new page lay out, then centre on it.
            .onChange(of: session.jumpRequest) { _, request in
                guard let request, request.bufferID == buffer.id else { return }
                session.consumeJump()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation { proxy.scrollTo(request.lineID, anchor: .center) }
                }
            }
            .task(id: buffer.id) {
                unreadDividerID = buffer.firstUnreadID
                // Let the lazy list lay out, then settle on the newest line.
                try? await Task.sleep(for: .milliseconds(60))
                if let last = displayLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                session.markRead(buffer)
            }
            .onDisappear { unreadDividerID = nil; scrollAnchorID = nil; followTask?.cancel() }
        }
    }

    /// Top sentinel: becomes visible only when the user scrolls up, pulling an
    /// older page of scrollback.
    private var historyLoader: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 10)
        .onAppear {
            guard !buffer.isLoadingHistory, !buffer.historyExhausted else { return }
            scrollAnchorID = displayLines.first?.id
            session.loadMoreHistory(for: buffer)
        }
    }

    private var unreadDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
            Text("New messages")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red.opacity(0.9))
                .fixedSize()
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendText(text, to: buffer, replyingTo: replyingTo)
        draft = ""
        replyingTo = nil
    }

    private func performJoin() {
        var channel = joinChannelText.trimmingCharacters(in: .whitespaces)
        joinChannelText = ""
        guard !channel.isEmpty else { return }
        if !"#&".contains(channel.first!) { channel = "#" + channel }
        session.join(channel)
    }

    // MARK: - Event filtering & collapsing

    /// The lines actually shown, after applying the presence-visibility filter
    /// and (optionally) collapsing runs of consecutive presence events.
    private var displayLines: [ChatLine] {
        let filtered: [ChatLine]
        switch prefs.presenceVisibility {
        case .show:
            filtered = buffer.lines
        case .hide:
            filtered = buffer.lines.filter { $0.presence == nil }
        case .smart:
            let speech = speechTimes()
            filtered = buffer.lines.filter { line in
                guard line.presence != nil, let nick = line.presenceNick else { return true }
                let times = speech[nick.lowercased()] ?? []
                return times.contains { abs($0.timeIntervalSince(line.timestamp)) <= Preferences.activeWindow }
            }
        }
        return prefs.collapseEvents ? Self.collapsePresence(filtered) : filtered
    }

    /// Timestamps of every message/action per speaker, for the smart filter.
    private func speechTimes() -> [String: [Date]] {
        var map: [String: [Date]] = [:]
        for line in buffer.lines where line.kind == .message || line.kind == .action {
            if let sender = line.sender { map[sender.lowercased(), default: []].append(line.timestamp) }
        }
        return map
    }

    /// Merges adjacent presence lines into a single summary line.
    private static func collapsePresence(_ lines: [ChatLine]) -> [ChatLine] {
        var out: [ChatLine] = []
        var run: [ChatLine] = []
        func flush() {
            if run.count == 1 { out.append(run[0]) }
            else if run.count > 1 { out.append(summarize(run)) }
            run.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if line.presence != nil { run.append(line) }
            else { flush(); out.append(line) }
        }
        flush()
        return out
    }

    private static func summarize(_ run: [ChatLine]) -> ChatLine {
        var joined: [String] = [], left: [String] = [], renamed: [String] = []
        for line in run {
            let nick = line.presenceNick ?? "?"
            switch line.presence {
            case .join:        joined.append(nick)
            case .part, .quit: left.append(nick)
            case .nick:        renamed.append(nick)
            case .none:        break
            }
        }
        var parts: [String] = []
        if !joined.isEmpty { parts.append("\(names(joined)) joined") }
        if !left.isEmpty   { parts.append("\(names(left)) left") }
        if !renamed.isEmpty {
            parts.append(renamed.count == 1 ? "1 nick change" : "\(renamed.count) nick changes")
        }
        // The summary keeps the first line's id so SwiftUI identity (and scroll
        // anchoring) stays stable; `presence == nil` marks it as terminal.
        return ChatLine(id: run.first!.id, timestamp: run.last!.timestamp,
                        sender: nil, text: parts.joined(separator: " · "), kind: .event)
    }

    private static func names(_ list: [String]) -> String {
        var seen = Set<String>(); var unique: [String] = []
        for name in list where seen.insert(name.lowercased()).inserted { unique.append(name) }
        switch unique.count {
        case 0:  return ""
        case 1:  return unique[0]
        case 2:  return "\(unique[0]) and \(unique[1])"
        case 3:  return "\(unique[0]), \(unique[1]) and \(unique[2])"
        default: return "\(unique[0]), \(unique[1]) and \(unique.count - 2) others"
        }
    }

    // MARK: - Reactions / replies / typing UI

    /// Long-press menu on a message: react or reply.
    @ViewBuilder private func lineMenu(_ line: ChatLine) -> some View {
        if line.kind == .message || line.kind == .action {
            if session.networkAllowsReactions {
                // Flat emoji buttons: each is its own full-width menu row, so every
                // one is a reliable tap target. The nested `Menu` submenu and a
                // `ControlGroup` palette both proved fiddly/broken to tap here.
                ForEach(["👍", "❤️", "😂", "🎉", "🤔", "👀", "🔥", "✅"], id: \.self) { emoji in
                    Button { session.toggleReaction(emoji, to: line, in: buffer) } label: {
                        Text("React \(emoji)")
                    }
                }
                // Any other emoji, via a sheet that opens the emoji keyboard.
                Button { reactingTo = line } label: {
                    Label("React…", systemImage: "face.smiling")
                }
            } else {
                Button {} label: {
                    Label("Reactions not supported on this network", systemImage: "face.dashed")
                }
                .disabled(true)
            }
            Button {
                replyingTo = line
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                UIPasteboard.general.string = line.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if line.isSelf, line.msgid != nil, !line.redacted, session.networkAllowsRedaction {
                Button(role: .destructive) {
                    session.redact(line, in: buffer)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Resolves the parent of a reply within this buffer, for the quoted block.
    /// An original older than the loaded scrollback still yields a context (no
    /// `lineID`), so the ↳ shows and a tap fetches it with CHATHISTORY AROUND.
    private func replyContext(for line: ChatLine) -> ChatLineView.ReplyContext? {
        guard let parentID = line.replyTo else { return nil }
        guard let parent = buffer.lines.first(where: { $0.msgid == parentID }) else {
            return .init(sender: "?", text: "", lineID: nil)
        }
        return .init(sender: parent.sender ?? "?",
                     text: String(parent.text.prefix(120)),
                     lineID: parent.id)
    }

    /// The AROUND context for this buffer, as the sheet's item.
    private var aroundContextBinding: Binding<AroundContext?> {
        Binding(
            get: {
                guard let context = session.aroundContext, !context.dismissed,
                      context.target == buffer.name else { return nil }
                return context
            },
            set: { if $0 == nil { session.dismissAroundContext() } }
        )
    }

    private func replyContextBar(_ line: ChatLine) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(line.sender ?? "?")")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption).lineLimit(1)
            }
            Spacer()
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.quaternary)
    }

    @ViewBuilder private var typingBanner: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let typers = buffer.currentlyTyping(asOf: context.date)
            if !typers.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 14)
                    Text(typingText(typers)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 2)
            }
        }
    }

    private func typingText(_ nicks: [String]) -> String {
        switch nicks.count {
        case 1:  return "\(nicks[0]) is typing…"
        case 2:  return "\(nicks[0]) and \(nicks[1]) are typing…"
        default: return "Several people are typing…"
        }
    }
}

/// Small sheet for reacting with any emoji: a single field that opens straight
/// on the system emoji keyboard; the first character typed is the reaction.
private struct EmojiReactSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("React with any emoji")
                .font(.headline)
            EmojiKeyboardField(text: $text)
                .frame(width: 84, height: 48)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: text) { _, newValue in
            guard let emoji = newValue.trimmingCharacters(in: .whitespacesAndNewlines).first
            else { return }
            onPick(String(emoji))
            dismiss()
        }
    }
}

/// A text field that opens directly on the emoji keyboard (when installed) by
/// overriding its input mode — there is no public "emoji keyboard" API, but
/// UIKit honours a field whose `textInputMode` resolves to the emoji mode.
private struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject {
        var text: Binding<String>
        var didFocus = false
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    }

    final class Field: UITextField {
        // A stable identifier lets iOS remember the chosen input mode per field.
        override var textInputContextIdentifier: String? { "im.arkhe.emojiPicker" }
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
                ?? super.textInputMode
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextField {
        let field = Field()
        field.placeholder = "😀"
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 30)
        field.borderStyle = .roundedRect
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed),
                        for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        field.text = text
        // Pop the keyboard once, when the sheet first lays out.
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
    }
}

/// The messages around a reply's original that predates the loaded scrollback
/// (CHATHISTORY AROUND), with the original highlighted and centred.
private struct AroundContextSheet: View {
    let context: AroundContext
    let currentNick: String?
    let showTimestamps: Bool
    let clockStyle: Preferences.ClockStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if context.isLoading {
                    ProgressView()
                } else if context.failed {
                    ContentUnavailableView(
                        "Original message unavailable",
                        systemImage: "text.bubble",
                        description: Text("The server couldn't return it. It may be too old, deleted, or this server doesn't support fetching it."))
                } else {
                    lineList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Original message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(context.lines) { line in
                        ChatLineView(line: line, currentNick: currentNick,
                                     showTimestamps: showTimestamps, clockStyle: clockStyle,
                                     autoLoadMedia: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .background(line.msgid == context.msgid ? Color.accentColor.opacity(0.15) : .clear)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                if let target = context.lines.first(where: { $0.msgid == context.msgid }) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
        }
    }
}
