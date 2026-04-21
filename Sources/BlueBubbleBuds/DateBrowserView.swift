import SwiftUI

struct DateBrowserView: View {
    let chat: ChatSummary

    @Environment(\.dismiss) private var dismiss
    @State private var pickedDate: Date = Date()
    @State private var messages: [ContextMessage] = []
    @State private var anchorRowid: Int?
    @State private var resolvedDate: String?
    @State private var scrollAnchor: Int?
    @State private var loadingInitial = false
    @State private var initialError: String?
    @State private var hasLoadedOnce = false
    @State private var loadingTop = false
    @State private var loadingBottom = false
    @State private var topExhausted = false
    @State private var bottomExhausted = false
    @State private var topFetchError: String?
    @State private var bottomFetchError: String?
    @State private var loadToken: UUID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loadingInitial {
                    ProgressView("Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = initialError {
                    errorView(err)
                } else if hasLoadedOnce && messages.isEmpty {
                    emptyView
                } else if !messages.isEmpty {
                    messageList
                } else {
                    promptView
                }
            }
        }
        .frame(minWidth: 640, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jump to date").font(.title3).fontWeight(.semibold)
                Text(chat.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            DatePicker(
                "",
                selection: $pickedDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .onChange(of: pickedDate) { _, _ in
                Task { await loadInitial() }
            }
            if let resolved = resolvedDate,
               let pickedISO = DateBrowserView.iso(from: pickedDate),
               resolved != pickedISO {
                Text("Nearest: \(resolved)")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let err = topFetchError {
                    edgeRetry(label: "Couldn't load older messages.", err: err) {
                        topFetchError = nil
                        Task { await fetchOlder() }
                    }
                } else if loadingTop {
                    ProgressView().padding(.vertical, 6)
                }

                ForEach(Array(messages.enumerated()), id: \.element.rowid) { idx, m in
                    MessageBubble(message: m)
                        .onAppear {
                            // Near-edge trigger: within 10 rows of either end.
                            if idx < 10 { Task { await fetchOlder() } }
                            if idx >= messages.count - 10 { Task { await fetchNewer() } }
                        }
                }

                if let err = bottomFetchError {
                    edgeRetry(label: "Couldn't load newer messages.", err: err) {
                        bottomFetchError = nil
                        Task { await fetchNewer() }
                    }
                } else if loadingBottom {
                    ProgressView().padding(.vertical, 6)
                }
            }
            .scrollTargetLayout()
            .padding(20)
        }
        .scrollPosition(id: $scrollAnchor, anchor: .top)
    }

    @ViewBuilder
    private func edgeRetry(label: String, err: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(label).font(.caption)
            Button("Retry", action: retry)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(err)
    }

    private var promptView: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Pick a date to jump to").font(.title3)
            Text("Use the picker above — we'll anchor to the nearest message.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left").font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No messages in this chat.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't load messages").font(.headline)
            Text(err).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Retry") { Task { await loadInitial() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func loadInitial() async {
        // Reset all state fresh — per spec: picked-date change wipes
        // messages, anchor, resolved date, and both edge exhaustion/error
        // flags.
        let token = UUID()
        loadToken = token
        loadingInitial = true
        initialError = nil
        messages = []
        anchorRowid = nil
        resolvedDate = nil
        scrollAnchor = nil
        topExhausted = false
        bottomExhausted = false
        topFetchError = nil
        bottomFetchError = nil

        guard let iso = DateBrowserView.iso(from: pickedDate) else {
            guard loadToken == token else { return }
            initialError = "Couldn't format date"
            loadingInitial = false
            return
        }

        do {
            let payload = try await CLIRunner.browseByDate(
                chatId: chat.chatId, date: iso, before: 25, after: 25
            )
            guard loadToken == token else { return }
            messages = payload.messages
            anchorRowid = payload.anchorRowid
            resolvedDate = payload.resolvedDate
            scrollAnchor = payload.anchorRowid
        } catch {
            guard loadToken == token else { return }
            initialError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        guard loadToken == token else { return }
        loadingInitial = false
        hasLoadedOnce = true
    }

    private func fetchOlder() async {
        guard !loadingTop, !topExhausted, topFetchError == nil,
              let savedTop = messages.first?.rowid else { return }
        let token = loadToken
        loadingTop = true
        do {
            let payload = try await CLIRunner.browsePage(
                chatId: chat.chatId,
                edgeRowid: savedTop,
                direction: .before,
                limit: 50
            )
            let batch = payload.messages
            if batch.count < 50 { topExhausted = true }
            if !batch.isEmpty, loadToken == token {
                // Keep scrollAnchor on savedTop — .scrollPosition(id:)
                // pins that row in place while new rows grow above.
                messages = batch + messages
                scrollAnchor = savedTop
            }
        } catch {
            if loadToken == token {
                topFetchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        loadingTop = false
    }

    private func fetchNewer() async {
        guard !loadingBottom, !bottomExhausted, bottomFetchError == nil,
              let savedBottom = messages.last?.rowid else { return }
        let token = loadToken
        loadingBottom = true
        do {
            let payload = try await CLIRunner.browsePage(
                chatId: chat.chatId,
                edgeRowid: savedBottom,
                direction: .after,
                limit: 50
            )
            let batch = payload.messages
            if batch.count < 50 { bottomExhausted = true }
            if !batch.isEmpty, loadToken == token {
                messages = messages + batch
            }
        } catch {
            if loadToken == token {
                bottomFetchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        loadingBottom = false
    }

    static func iso(from date: Date) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
