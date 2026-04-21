import SwiftUI

struct ContextView: View {
    let chatId: Int
    let targetRowid: Int

    @Environment(\.dismiss) private var dismiss
    @State private var payload: ContextPayload?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loading {
                    ProgressView("Loading context…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 10) {
                        Text("Couldn't load context").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if let p = payload {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(p.messages) { m in
                                    MessageBubble(message: m)
                                        .id(m.rowid)
                                }
                            }
                            .padding(20)
                        }
                        .onAppear {
                            withAnimation {
                                proxy.scrollTo(p.targetRowid, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Message context").font(.title3).fontWeight(.semibold)
                Text(payload?.chatName ?? "…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            payload = try await CLIRunner.context(chatId: chatId, rowid: targetRowid)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}
