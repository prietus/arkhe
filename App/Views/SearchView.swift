import SwiftUI

/// Searches messages in this conversation or in all of them: on the bouncer
/// when it offers `soju.im/search` (its whole history), otherwise in the
/// history loaded on this device. Picking a result jumps to it.
struct SearchView: View {
    let session: IRCSession
    /// The conversation the search was opened from (`nil` for the status window).
    let buffer: Buffer?
    let onOpen: (SearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search messages", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit(run)
                            .autocorrectionDisabled()
                        if session.searchState?.isSearching == true { ProgressView() }
                    }
                    if buffer != nil {
                        Picker("Where", selection: $everywhere) {
                            Text(buffer?.name ?? "This conversation").tag(false)
                            Text("All conversations").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: everywhere) { _, _ in if !query.isEmpty { run() } }
                    }
                } footer: {
                    Text(sourceNote)
                }
                results
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                everywhere = buffer == nil
                session.clearSearch()
                focused = true
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let state = session.searchState, state.query == query.trimmingCharacters(in: .whitespacesAndNewlines) {
            if state.hits.isEmpty, !state.isSearching {
                Section {
                    ContentUnavailableView.search(text: state.query)
                }
            } else {
                Section {
                    ForEach(state.hits) { hit in
                        Button {
                            onOpen(hit)
                            dismiss()
                        } label: {
                            row(hit, query: state.query, showConversation: everywhere || buffer == nil)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(state.isSearching ? "Searching…" : "\(state.hits.count) result\(state.hits.count == 1 ? "" : "s")")
                } footer: {
                    if let failure = state.failure { Text(failure) }
                }
            }
        }
    }

    private func row(_ hit: SearchHit, query: String, showConversation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if showConversation {
                    Text(hit.target).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                Text(hit.line.sender ?? "").font(.caption.weight(.semibold))
                Spacer()
                Text(hit.line.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(highlighted(hit.line.text, query))
                .font(.subheadline)
                .lineLimit(3)
        }
        .contentShape(Rectangle())
    }

    /// The text with every occurrence of the query emphasised.
    private func highlighted(_ text: String, _ query: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchStart = text.startIndex
        while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].font = .subheadline.bold()
                attributed[lower..<upper].foregroundColor = .accentColor
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    private var sourceNote: String {
        switch session.searchState?.source {
        case .server: return "Searched your bouncer's full history."
        case .device: return "This server can't search, so this searched the history on this device."
        case nil:
            return session.enabledCaps.contains("soju.im/search") && session.status == .connected
                ? "Searches your bouncer's full history."
                : "Searches the history on this device; a soju bouncer can search everything."
        }
    }

    private func run() {
        session.search(query, in: everywhere ? nil : buffer)
    }
}
