import SwiftUI
import UIKit

/// The raw protocol console: every line in/out, with a filter to zero in on a
/// command (e.g. `TAGMSG`, `react`) when diagnosing IRCv3 behaviour.
struct ProtocolLogView: View {
    let log: ProtocolLog
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filtered: [ProtocolLog.Entry] {
        guard !filter.isEmpty else { return log.entries }
        return log.entries.filter { $0.line.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: log.entries.count) {
                    if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "Filter: TAGMSG, react, reply…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = filtered
                                .map { ($0.outgoing ? ">> " : "<< ") + $0.line }
                                .joined(separator: "\n")
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { log.clear() } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func row(_ entry: ProtocolLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.outgoing ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(entry.outgoing ? .blue : .green)
                .frame(width: 10)
            Text(entry.line)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
