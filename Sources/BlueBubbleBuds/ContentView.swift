import SwiftUI

struct ContentView: View {
    @State private var chats: [ChatSummary] = []
    @State private var selection: ChatSummary.ID?
    @State private var loadingChats = true
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            if let chatId = selection, let chat = chats.first(where: { $0.id == chatId }) {
                AnalysisView(chat: chat)
                    .id(chatId) // force re-create on chat change so analysis reloads
            } else {
                placeholder
            }
        }
        .task { await loadChats() }
    }

    private var sidebar: some View {
        Group {
            if loadingChats {
                ProgressView("Loading chats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                errorPane(err)
            } else {
                List(chats, selection: $selection) { chat in
                    ChatRow(chat: chat).tag(chat.id)
                }
            }
        }
    }

    @ViewBuilder
    private func errorPane(_ err: String) -> some View {
        let isFDA = err.contains("Operation not permitted") || err.contains("authorization denied")
        VStack(alignment: .leading, spacing: 12) {
            if isFDA {
                Label("Full Disk Access required", systemImage: "lock.shield")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Blue Bubble Buds needs permission to read your iMessage database.")
                    .font(.callout)
                Text("1. Open System Settings → Privacy & Security → Full Disk Access")
                Text("2. Click + and add Blue Bubble Buds")
                Text("3. Quit and relaunch this app")
                    .padding(.bottom, 6)
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.large)
            } else {
                Text("Couldn't load chats").font(.headline)
            }
            DisclosureGroup("Technical details") {
                ScrollView {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            Button("Retry") { Task { await loadChats() } }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Pick a group chat from the sidebar").font(.title3)
            Text("Blue Bubble Buds will analyze reactions, surface the sticker champs, and flag any quiet friends.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadChats() async {
        loadingChats = true
        loadError = nil
        do {
            chats = try await CLIRunner.listChats()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loadingChats = false
    }
}

private struct ChatRow: View {
    let chat: ChatSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chat.label).font(.headline).lineLimit(1)
            Text("\(chat.memberCount) members · \(chat.messageCount.formatted()) msgs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(chat.members.prefix(4).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
